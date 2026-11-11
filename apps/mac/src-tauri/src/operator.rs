//! Operator's local dictation API with caller sessions (native contract in
//! `~/apps/operator/mac/app/Core/Sources/OperatorCore/Control`). Each comment box owns one session
//! per recording. Operator never pastes for a session: stop and wait answer with the transcript.

use crate::annotations::{error_message, status_text};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum Reply {
    /// Start or cancel succeeded (202, or 200 unchanged).
    Ok,
    /// Stop or wait: the final transcript, possibly empty.
    Text(String),
    /// 409. Start: Operator is busy or the session was used. Stop or wait: the session was cancelled.
    Conflict,
    /// 404 on stop, wait or cancel: Operator does not know the session.
    Unknown,
    /// 400 or 404 on start: Operator predates caller sessions.
    Unsupported,
    /// 504 on stop or wait: no transcript within about 119 s.
    TimedOut,
    NotRunning,
    /// 401: missing or wrong Local API token.
    Unauthorized,
    Failed(String),
}

impl Reply {
    pub fn name(&self) -> &'static str {
        match self {
            Reply::Ok => "ok",
            Reply::Text(_) => "text",
            Reply::Conflict => "conflict",
            Reply::Unknown => "unknown",
            Reply::Unsupported => "unsupported",
            Reply::TimedOut => "timedOut",
            Reply::NotRunning => "notRunning",
            Reply::Unauthorized => "unauthorized",
            Reply::Failed(_) => "failed",
        }
    }

    pub fn json(&self) -> Value {
        match self {
            Reply::Text(text) => json!({"result": "text", "text": text}),
            Reply::Failed(message) => json!({"result": "failed", "message": message}),
            other => json!({"result": other.name()}),
        }
    }

    /// Why a background stop lost the dictation, for the notice. Never contains a transcript.
    pub fn reason(&self) -> String {
        match self {
            Reply::Conflict => "Operator cancelled it".into(),
            Reply::Unknown => "Operator lost it".into(),
            Reply::TimedOut => "Operator did not finish in time".into(),
            Reply::NotRunning => "Operator is not running".into(),
            Reply::Unauthorized => "Operator rejected Annotator's token".into(),
            Reply::Unsupported => "Operator does not support caller sessions".into(),
            Reply::Failed(message) => message.trim_end_matches('.').to_string(),
            Reply::Ok | Reply::Text(_) => "Operator sent no transcript".into(),
        }
    }
}

/// 1–200 of `A-Za-z0-9_-`, as Operator accepts.
pub fn valid_session(session: &str) -> bool {
    (1..=200).contains(&session.len()) && session.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

/// Where Operator keeps its Local API token. Its identity is `com.nckrtl.operator`.
pub fn token_file(bundle_id: &str, home: &Path) -> PathBuf {
    home.join(format!("Library/Application Support/{bundle_id}/control.json"))
}

pub fn read_token(file: &Path) -> Result<String, String> {
    let data = std::fs::read(file).map_err(|_| {
        format!("No Operator Local API token at {}. Turn on Local API in Operator → Settings.", file.display())
    })?;
    serde_json::from_slice::<Value>(&data).ok()
        .and_then(|v| v["token"].as_str().map(String::from))
        .filter(|t| !t.is_empty())
        .ok_or_else(|| format!("Could not read the Operator Local API token in {}.", file.display()))
}

#[derive(Clone)]
pub struct OperatorClient {
    pub base: url::Url,
    pub token: String,
    http: reqwest::Client,
}

impl OperatorClient {
    pub fn new(base: url::Url, token: String) -> OperatorClient {
        OperatorClient { base, token, http: crate::http::short() }
    }

    /// `start`, `stop`, `wait` or `cancel` for one session. Start 4 s, cancel 3 s, stop and wait 125 s.
    pub async fn call(&self, action: &str, session: &str) -> Reply {
        let limit = match action {
            "start" => 4,
            "cancel" => 3,
            "stop" | "wait" => 125,
            _ => return Reply::Failed(format!("Unknown Operator action: {action}")),
        };
        if !valid_session(session) {
            return Reply::Failed("Not a dictation session id.".into());
        }
        let mut url = self.base.clone();
        if let Ok(mut segments) = url.path_segments_mut() {
            segments.pop_if_empty().extend(["dictate", action]);
        }
        let request = self.http.post(url).header("X-Operator-Token", &self.token)
            .json(&json!({"session": session})).timeout(Duration::from_secs(limit));
        let response = match request.send().await {
            Ok(response) => response,
            Err(error) if error.is_timeout() => return Reply::Failed("Operator did not answer in time.".into()),
            Err(_) => return Reply::NotRunning,
        };
        let status = response.status().as_u16();
        let Ok(data) = response.bytes().await else { return Reply::Failed("Operator dropped the response.".into()) };
        let starting = action == "start";
        match status {
            200 | 202 if matches!(action, "stop" | "wait") => Reply::Text(text(&data)),
            200 | 202 => Reply::Ok,
            400 | 404 if starting => Reply::Unsupported,
            401 => Reply::Unauthorized,
            404 => Reply::Unknown,
            409 => Reply::Conflict,
            504 => Reply::TimedOut,
            _ => Reply::Failed(format!("{status} {}", error_message(&data).unwrap_or_else(|| status_text(status)))),
        }
    }
}

/// The `text` of a stop or wait answer; anything else is an empty transcript.
fn text(data: &[u8]) -> String {
    serde_json::from_slice::<Value>(data).ok().and_then(|v| v["text"].as_str().map(str::to_owned)).unwrap_or_default()
}

/// What a background finish posts, and why the dictation was lost, if it was.
#[derive(Debug, Clone, PartialEq)]
pub struct Finish {
    pub comment: Option<String>,
    pub lost: Option<String>,
}

/// Joins the typed text and the transcript with one space. A failed stop keeps the typed text.
pub fn finish(typed: &str, reply: &Reply) -> Finish {
    let typed = typed.trim();
    let some = |text: String| Some(text).filter(|t| !t.is_empty());
    match reply {
        Reply::Text(transcript) => {
            let transcript = transcript.trim();
            let joined = if typed.is_empty() || transcript.is_empty() { format!("{typed}{transcript}") } else { format!("{typed} {transcript}") };
            Finish { comment: some(joined), lost: None }
        }
        failed => Finish { comment: some(typed.into()), lost: Some(failed.reason()) },
    }
}

/// Stops a session that left its comment box and joins its transcript to the typed text. The core
/// runs it as a background task, so the next comment can start its own session at once.
pub async fn finish_session(client: Result<OperatorClient, String>, session: &str, typed: &str) -> Finish {
    let reply = match client {
        Ok(client) => client.call("stop", session).await,
        Err(error) => Reply::Failed(error),
    };
    crate::log(&format!("Operator stop (background): {}", reply.name()));
    finish(typed, &reply)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{closed_url, serve, temp_dir, Reply as Http};

    fn client(base: url::Url) -> OperatorClient {
        OperatorClient::new(base, "t".into())
    }

    #[tokio::test]
    async fn paths_bodies_and_token() {
        let server = serve(vec![Http::new(202, ""), Http::new(200, r#"{"text":"a"}"#), Http::new(200, r#"{"text":"a"}"#), Http::new(202, "")]);
        let operator = client(server.url(""));
        assert_eq!(operator.call("start", "id-1").await, Reply::Ok);
        assert_eq!(operator.call("wait", "id-1").await, Reply::Text("a".into()));
        assert_eq!(operator.call("stop", "id-1").await, Reply::Text("a".into()));
        assert_eq!(operator.call("cancel", "id-1").await, Reply::Ok);
        assert_eq!(server.paths(), ["/dictate/start", "/dictate/wait", "/dictate/stop", "/dictate/cancel"]);
        for index in 0..4 {
            let request = server.request(index);
            assert_eq!(request.method, "POST");
            assert_eq!(request.header("x-operator-token"), Some("t"));
            assert_eq!(serde_json::from_slice::<Value>(&request.body).unwrap(), json!({"session": "id-1"}));
        }
    }

    #[tokio::test]
    async fn rejects_bad_sessions_and_actions_without_a_request() {
        let server = serve(vec![Http::new(202, "")]);
        let operator = client(server.url(""));
        for session in ["", "a b", "a/b", &"x".repeat(201)] {
            assert!(matches!(operator.call("start", session).await, Reply::Failed(_)));
        }
        assert!(matches!(operator.call("status", "a").await, Reply::Failed(_)));
        assert!(server.paths().is_empty());
        assert!(valid_session(&"x".repeat(200)) && valid_session("6f1c-AB_1-2"));
    }

    #[tokio::test]
    async fn status_codes() {
        let one = |action: &'static str, status| async move { client(serve(vec![Http::new(status, "")]).url("")).call(action, "s").await };
        assert_eq!(one("start", 200).await, Reply::Ok);
        assert_eq!(one("start", 409).await, Reply::Conflict);
        assert_eq!(one("start", 400).await, Reply::Unsupported);
        assert_eq!(one("start", 404).await, Reply::Unsupported);
        assert_eq!(one("cancel", 404).await, Reply::Unknown);
        for action in ["stop", "wait"] {
            assert_eq!(one(action, 409).await, Reply::Conflict);
            assert_eq!(one(action, 404).await, Reply::Unknown);
            assert_eq!(one(action, 504).await, Reply::TimedOut);
            assert!(matches!(one(action, 500).await, Reply::Failed(_)));
            assert!(matches!(one(action, 400).await, Reply::Failed(_)));
        }
        assert_eq!(one("stop", 401).await, Reply::Unauthorized);
        assert_eq!(client(closed_url("")).call("start", "s").await, Reply::NotRunning);
        let server = serve(vec![Http::new(500, r#"{"error":"Could not start recording"}"#)]);
        assert_eq!(client(server.url("")).call("start", "s").await, Reply::Failed("500 Could not start recording".into()));
    }

    #[tokio::test]
    async fn text_parsing() {
        for (body, text) in [(r#"{"status":"complete","text":"Fix it"}"#, "Fix it"), (r#"{"text":""}"#, ""),
            (r#"{"text":3}"#, ""), ("{}", ""), ("not json", "")] {
            let server = serve(vec![Http::new(200, body)]);
            assert_eq!(client(server.url("")).call("stop", "s").await, Reply::Text(text.into()));
        }
        assert_eq!(Reply::Text("a".into()).json(), json!({"result": "text", "text": "a"}));
        assert_eq!(Reply::Conflict.json(), json!({"result": "conflict"}));
    }

    #[tokio::test]
    async fn silent_api_times_out_and_dropped_body_fails() {
        let server = serve(vec![Http::new(202, "").delayed(4300)]);
        let began = std::time::Instant::now();
        assert!(matches!(client(server.url("")).call("start", "s").await, Reply::Failed(_)));
        assert!(began.elapsed() < Duration::from_secs(5));

        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = url::Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0; 4096]; let _ = stream.read(&mut request);
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 200\r\n\r\n{");
        });
        assert!(matches!(client(base).call("stop", "s").await, Reply::Failed(_)));
    }

    #[test]
    fn reads_the_token() {
        let home = temp_dir("operator");
        let file = token_file("com.nckrtl.operator", &home);
        assert_eq!(read_token(&file).unwrap_err(),
            format!("No Operator Local API token at {}. Turn on Local API in Operator → Settings.", file.display()));
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, r#"{"enabled":true,"token":"abc"}"#).unwrap();
        assert_eq!(read_token(&file).unwrap(), "abc");
    }

    #[test]
    fn background_finish_joins_typed_text_and_transcript() {
        let text = |t: &str| Reply::Text(t.into());
        let post = |c: &str| Finish { comment: Some(c.into()), lost: None };
        assert_eq!(finish(" Typed ", &text("")), post("Typed"));
        assert_eq!(finish("", &text(" Spoken ")), post("Spoken"));
        assert_eq!(finish("Typed", &text("spoken")), post("Typed spoken"));
        assert_eq!(finish(" ", &text(" ")), Finish { comment: None, lost: None });
    }

    #[test]
    fn failed_background_stop_keeps_typed_text_and_says_why() {
        assert_eq!(finish("Typed", &Reply::Conflict), Finish { comment: Some("Typed".into()), lost: Some("Operator cancelled it".into()) });
        assert_eq!(finish("", &Reply::NotRunning), Finish { comment: None, lost: Some("Operator is not running".into()) });
        assert_eq!(finish("", &Reply::Failed("500 Model failed.".into())).lost.as_deref(), Some("500 Model failed"));
        for reply in [Reply::Unknown, Reply::TimedOut, Reply::Unauthorized] {
            assert!(finish("x", &reply).lost.is_some());
        }
    }

    /// A move hands the old session off and starts the next one at once: the new start is answered
    /// while the old stop still waits for its transcript.
    #[tokio::test]
    async fn a_move_does_not_wait_for_the_earlier_session() {
        let server = serve(vec![Http::new(200, r#"{"text":"first"}"#).delayed(400), Http::new(202, "")]);
        let operator = client(server.url(""));
        let began = std::time::Instant::now();
        let earlier = operator.clone();
        let first = tokio::spawn(async move { finish_session(Ok(earlier), "a-1", "Typed").await });
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(operator.call("start", "b-1").await, Reply::Ok);
        assert!(began.elapsed() < Duration::from_millis(300) && !first.is_finished());
        assert_eq!(first.await.unwrap(), Finish { comment: Some("Typed first".into()), lost: None });
        assert_eq!(server.paths(), ["/dictate/stop", "/dictate/start"]);
    }

    #[tokio::test]
    async fn background_finish_without_a_token_keeps_typed_text() {
        assert_eq!(finish_session(Err("No token".into()), "a-1", "Typed").await,
            Finish { comment: Some("Typed".into()), lost: Some("No token".into()) });
    }
}
