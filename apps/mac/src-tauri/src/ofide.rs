//! Ofide's local dictation API (OfideClient.swift). See `~/apps/ofide/README.md`.
//! `start` and `cancel` run one after another, so a late cancel never stops a new recording.

use crate::annotations::{error_message, status_text};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum OfideResult {
    Ok,
    /// 409: no active dictation, or focus changed.
    NoDictation,
    /// 422: Ofide heard only silence.
    Silence,
    Failed(String),
    NotRunning,
    /// 401: missing or wrong Local API token.
    Unauthorized,
}

impl OfideResult {
    pub fn name(&self) -> &'static str {
        match self {
            OfideResult::Ok => "ok",
            OfideResult::NoDictation => "noDictation",
            OfideResult::Silence => "silence",
            OfideResult::Failed(_) => "failed",
            OfideResult::NotRunning => "notRunning",
            OfideResult::Unauthorized => "unauthorized",
        }
    }
}

/// Where Ofide keeps its Local API token. `bundle_id` is `com.nckrtl.ofide` or `com.nckrtl.ofide.dev`.
pub fn token_file(bundle_id: &str, home: &Path) -> PathBuf {
    home.join(format!("Library/Application Support/{bundle_id}/control.json"))
}

pub fn read_token(file: &Path) -> Result<String, String> {
    let data = std::fs::read(file).map_err(|_| {
        format!("No Ofide Local API token at {}. Turn on Local API in Ofide → Settings.", file.display())
    })?;
    serde_json::from_slice::<Value>(&data).ok()
        .and_then(|v| v["token"].as_str().map(String::from))
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("Could not read the Ofide Local API token in {}.", file.display()))
}

#[derive(Clone)]
pub struct OfideClient {
    pub base: url::Url,
    pub token: String,
    http: reqwest::Client,
}

/// One answer: the result, and Ofide's state when it answered `/status` with 200.
#[derive(Debug, Clone, PartialEq)]
pub struct Answer {
    pub result: OfideResult,
    pub status: Option<String>,
    pub cancelled_at: Option<f64>,
}

impl Answer {
    pub fn json(&self) -> Value {
        let message = match &self.result {
            OfideResult::Failed(detail) => Some(detail.clone()),
            _ => None,
        };
        json!({"result": self.result.name(), "message": message,
            "status": self.status, "cancelledAt": self.cancelled_at})
    }
}

impl OfideClient {
    /// `/dictate-stop` waits for transcription and paste, up to 120 seconds.
    pub fn new(base: url::Url, token: String) -> OfideClient {
        let http = reqwest::Client::builder().timeout(Duration::from_secs(125)).build().expect("HTTP client");
        OfideClient { base, token, http }
    }

    fn url(&self, path: &str) -> url::Url {
        let mut url = self.base.clone();
        if let Ok(mut segments) = url.path_segments_mut() {
            segments.pop_if_empty().extend(path.split('/'));
        }
        url
    }

    async fn send(&self, request: reqwest::RequestBuilder) -> (OfideResult, Option<Vec<u8>>) {
        let response = match request.header("X-Ofide-Token", &self.token).send().await {
            Ok(response) => response,
            Err(_) => return (OfideResult::NotRunning, None),
        };
        let status = response.status().as_u16();
        let data = response.bytes().await.map(|b| b.to_vec()).unwrap_or_default();
        let result = match status {
            200 | 202 => OfideResult::Ok,
            409 => OfideResult::NoDictation,
            422 => OfideResult::Silence,
            401 => OfideResult::Unauthorized,
            _ => {
                let detail = error_message(&data).unwrap_or_else(|| status_text(status));
                OfideResult::Failed(format!("{status} {detail}"))
            }
        };
        (result, Some(data).filter(|_| status == 200))
    }

    /// Ok when Ofide answers and accepts the token, with its state: `loading`, `arming`,
    /// `recording`, `transcribing`, `ready`, or an error.
    pub async fn status(&self) -> Answer {
        let (result, data) = self.send(self.http.get(self.url("status")).timeout(Duration::from_secs(2))).await;
        let state = data.and_then(|d| serde_json::from_slice::<Value>(&d).ok());
        Answer {
            result,
            status: state.as_ref().and_then(|s| s["status"].as_str().map(String::from)),
            cancelled_at: state.as_ref().and_then(|s| s["cancelledAt"].as_f64()),
        }
    }

    /// Starts recording. Ofide pastes into the focused field however the recording ends.
    pub async fn start(&self) -> OfideResult {
        self.send(self.http.post(self.url("dictate/start"))).await.0
    }

    /// Stops, transcribes and pastes into the focused field. Returns after the paste.
    pub async fn stop(&self) -> OfideResult {
        self.send(self.http.post(self.url("dictate-stop"))).await.0
    }

    /// Cancels without requesting transcription or paste.
    pub async fn cancel(&self) -> OfideResult {
        self.send(self.http.post(self.url("dictate/cancel")).timeout(Duration::from_secs(3))).await.0
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Kind {
    Start,
    Cancel,
}

/// Runs start and cancel one at a time. A cancel waits for a start in flight, is skipped when that
/// start found no dictation, and is sent once: a second cancel without a start between is a no-op.
/// A stop waits for the commands before it but does not hold the queue, so a cancel can follow it.
pub struct OfideQueue {
    last: tokio::sync::Mutex<Option<(Kind, OfideResult)>>,
}

impl Default for OfideQueue {
    fn default() -> Self {
        OfideQueue { last: tokio::sync::Mutex::new(None) }
    }
}

impl OfideQueue {
    pub async fn run(&self, client: &OfideClient, action: &str) -> Result<Answer, String> {
        let answer = |result| Answer { result, status: None, cancelled_at: None };
        match action {
            "status" => Ok(client.status().await),
            "start" => {
                let mut last = self.last.lock().await;
                let result = client.start().await;
                *last = Some((Kind::Start, result.clone()));
                Ok(answer(result))
            }
            "cancel" => {
                let mut last = self.last.lock().await;
                match &*last {
                    Some((_, OfideResult::NoDictation)) => return Ok(answer(OfideResult::Ok)),
                    Some((Kind::Cancel, previous)) => return Ok(answer(previous.clone())),
                    _ => {}
                }
                let result = client.cancel().await;
                *last = Some((Kind::Cancel, result.clone()));
                Ok(answer(result))
            }
            "stop" => {
                drop(self.last.lock().await);
                Ok(answer(client.stop().await))
            }
            _ => Err(format!("Unknown Ofide action: {action}")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{closed_url, serve, temp_dir, Reply};
    use std::sync::Arc;

    fn client(base: url::Url) -> OfideClient {
        OfideClient::new(base, "t".into())
    }

    #[tokio::test]
    async fn status_codes() {
        let one = |status| async move { client(serve(vec![Reply::new(status, "")]).url("")).stop().await };
        assert_eq!(one(200).await, OfideResult::Ok);
        assert_eq!(one(409).await, OfideResult::NoDictation);
        assert_eq!(one(422).await, OfideResult::Silence);
        assert_eq!(one(504).await, OfideResult::Failed("504 gateway timed out".into()));
        assert_eq!(client(closed_url("")).start().await, OfideResult::NotRunning);
        let server = serve(vec![Reply::new(401, "")]);
        assert_eq!(client(server.url("")).status().await.result, OfideResult::Unauthorized);
    }

    #[tokio::test]
    async fn paths_and_token() {
        let server = serve(vec![Reply::new(202, "")]);
        let ofide = client(server.url(""));
        ofide.start().await;
        ofide.stop().await;
        ofide.cancel().await;
        assert_eq!(server.paths(), ["/dictate/start", "/dictate-stop", "/dictate/cancel"]);
        for index in 0..3 {
            let request = server.request(index);
            assert_eq!(request.method, "POST");
            assert_eq!(request.header("x-ofide-token"), Some("t"));
        }
    }

    #[tokio::test]
    async fn state_and_cancellation() {
        let server = serve(vec![Reply::new(200, r#"{"status":"ready","cancelledAt":1791400000000}"#)]);
        let answer = client(server.url("")).status().await;
        assert_eq!(answer.result, OfideResult::Ok);
        assert_eq!(answer.status.as_deref(), Some("ready"));
        assert_eq!(answer.cancelled_at, Some(1791400000000.0));
        assert_eq!(server.request(0).header("x-ofide-token"), Some("t"));
        assert_eq!(client(closed_url("")).status().await.status, None);
    }

    #[test]
    fn reads_the_token() {
        let home = temp_dir("ofide");
        let file = token_file("com.nckrtl.ofide", &home);
        assert_eq!(read_token(&file).unwrap_err(),
            format!("No Ofide Local API token at {}. Turn on Local API in Ofide → Settings.", file.display()));
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, r#"{"enabled":true,"token":"abc"}"#).unwrap();
        assert_eq!(read_token(&file).unwrap(), "abc");
    }

    /// The comment panel closes while a start is in flight: the cancel goes out after the start,
    /// and only once however often the panel asks.
    #[tokio::test]
    async fn cancel_waits_for_the_start_and_goes_out_once() {
        let server = serve(vec![Reply::new(202, "").delayed(300), Reply::new(202, "")]);
        let ofide = client(server.url(""));
        let queue = Arc::new(OfideQueue::default());
        let (q, c) = (queue.clone(), ofide.clone());
        let start = tokio::spawn(async move { q.run(&c, "start").await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        let cancel = queue.run(&ofide, "cancel").await.unwrap();
        assert_eq!(cancel.result, OfideResult::Ok);
        assert_eq!(start.await.unwrap().unwrap().result, OfideResult::Ok);
        assert_eq!(queue.run(&ofide, "cancel").await.unwrap().result, OfideResult::Ok);
        assert_eq!(server.paths(), ["/dictate/start", "/dictate/cancel"]);
    }

    #[tokio::test]
    async fn no_cancel_after_a_start_without_dictation() {
        let server = serve(vec![Reply::new(409, "")]);
        let ofide = client(server.url(""));
        let queue = OfideQueue::default();
        assert_eq!(queue.run(&ofide, "start").await.unwrap().result, OfideResult::NoDictation);
        assert_eq!(queue.run(&ofide, "cancel").await.unwrap().result, OfideResult::Ok);
        assert_eq!(server.paths(), ["/dictate/start"]);
    }
}
