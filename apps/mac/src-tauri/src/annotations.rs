//! The annotation server client (AnnotationClient.swift). Records stay `serde_json::Value`: the
//! helper builds them, Annotator fills in `comment` and `native.project`, and the server and agents
//! may add fields this app does not know.

use serde_json::Value;

/// The outcome of posting one annotation.
#[derive(Debug, Clone, PartialEq)]
pub enum PostResult {
    /// 201: the server stored a new record.
    Created(Option<i64>),
    /// 200: the server already had this id. A retry landed.
    Existing(Option<i64>),
    /// 410: the record was deleted on the server. Do not resend.
    Deleted,
    /// 413: over the server's size limit. Do not resend.
    TooLarge,
    /// Another 4xx. Do not resend.
    Rejected(u16, String),
    /// 5xx. Try again later.
    ServerError(u16, String),
    /// No answer. Try again later.
    Unreachable(String),
}

impl PostResult {
    pub fn is_stored(&self) -> bool {
        matches!(self, PostResult::Created(_) | PostResult::Existing(_))
    }

    /// Whether a later retry can succeed.
    pub fn is_retryable(&self) -> bool {
        matches!(self, PostResult::ServerError(..) | PostResult::Unreachable(_))
    }

    pub fn message(&self) -> String {
        let number = |n: &Option<i64>| n.map(|n| format!(" as #{n}")).unwrap_or_default();
        match self {
            PostResult::Created(n) => format!("Sent{}.", number(n)),
            PostResult::Existing(n) => format!("Already on the server{}.", number(n)),
            PostResult::Deleted => "The server says this annotation was deleted. It was not sent again.".into(),
            PostResult::TooLarge => "The server rejected the annotation: it is over 10 MiB.".into(),
            PostResult::Rejected(status, message) => format!("The server rejected the annotation ({status}): {message}"),
            PostResult::ServerError(status, message) => format!("Server error ({status}): {message}. Saved locally; it will retry."),
            PostResult::Unreachable(message) => format!("Server unreachable: {message}. Saved locally; it will retry."),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum QueueError {
    Unreachable(String),
    NotAnnotationServer,
    BadStatus(u16),
}

impl std::fmt::Display for QueueError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            QueueError::Unreachable(message) => write!(f, "Server unreachable: {message}"),
            QueueError::NotAnnotationServer => write!(f, "This URL is not an @nckrtl/annotator server."),
            QueueError::BadStatus(status) => write!(f, "The server answered {status}."),
        }
    }
}

/// Accessors for a queue record as the server returns it.
pub trait Item {
    fn id(&self) -> &str;
    fn status(&self) -> &str;
    fn number(&self) -> Option<i64>;
    fn is_open(&self) -> bool {
        matches!(self.status(), "todo" | "in_progress")
    }
}

impl Item for Value {
    fn id(&self) -> &str {
        self["id"].as_str().unwrap_or_default()
    }
    fn status(&self) -> &str {
        self["status"].as_str().unwrap_or_default()
    }
    fn number(&self) -> Option<i64> {
        self["number"].as_i64()
    }
}

/// The queue counts and lists. Todo and in-progress items oldest first, so the next one an agent
/// claims is at the top; everything else newest first.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct QueueSummary {
    pub todo: usize,
    pub in_progress: usize,
    pub done: usize,
    pub open: Vec<Value>,
    pub finished: Vec<Value>,
}

impl QueueSummary {
    pub fn new(items: &[Value]) -> QueueSummary {
        let mut summary = QueueSummary::default();
        for item in items {
            match item.status() {
                "todo" => summary.todo += 1,
                "in_progress" => summary.in_progress += 1,
                _ => summary.done += 1,
            }
        }
        let mut by_number: Vec<Value> = items.to_vec();
        by_number.sort_by_key(|item| item.number().unwrap_or(0));
        let (open, mut finished): (Vec<Value>, Vec<Value>) = by_number.into_iter().partition(|item| item.is_open());
        finished.reverse();
        summary.open = open;
        summary.finished = finished;
        summary
    }

    pub fn item(&self, id: &str) -> Option<&Value> {
        self.open.iter().chain(self.finished.iter()).find(|item| item.id() == id)
    }
}

/// A short message for a failed request, like URLError's localized description.
pub fn describe(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        "The request timed out.".into()
    } else if error.is_connect() {
        "Could not connect to the server.".into()
    } else {
        let mut text = error.to_string();
        let mut source = std::error::Error::source(error);
        while let Some(inner) = source {
            text = format!("{text}: {inner}");
            source = inner.source();
        }
        text
    }
}

/// The text for a status code, like HTTPURLResponse.localizedString(forStatusCode:).
pub fn status_text(status: u16) -> String {
    match status {
        504 => "gateway timed out".into(),
        410 => "no longer exists".into(),
        413 => "request too large".into(),
        _ => reqwest::StatusCode::from_u16(status).ok().and_then(|s| s.canonical_reason())
            .map(str::to_lowercase).unwrap_or_else(|| format!("status {status}")),
    }
}

/// The `error` message of a JSON error body, if any.
pub fn error_message(body: &[u8]) -> Option<String> {
    serde_json::from_slice::<Value>(body).ok()?.get("error")?.as_str().map(String::from)
}

/// Talks to an `@nckrtl/annotator` server at `base`, such as `http://127.0.0.1:29703/annotations`.
#[derive(Clone)]
pub struct AnnotationClient {
    pub base: url::Url,
    http: reqwest::Client,
}

impl AnnotationClient {
    pub fn new(base: url::Url) -> AnnotationClient {
        AnnotationClient { base, http: crate::http::short() }
    }

    fn appending(&self, segment: &str) -> url::Url {
        let mut url = self.base.clone();
        if let Ok(mut segments) = url.path_segments_mut() {
            segments.pop_if_empty().push(segment);
        }
        url
    }

    pub fn events_url(&self) -> url::Url {
        self.appending("events")
    }

    /// Posts an encoded record, as the retry store keeps it.
    pub async fn post(&self, body: Vec<u8>) -> PostResult {
        let request = self.http.post(self.base.clone()).header("Content-Type", "application/json").body(body);
        let response = match request.send().await {
            Ok(response) => response,
            Err(error) => return PostResult::Unreachable(describe(&error)),
        };
        let status = response.status().as_u16();
        let data = response.bytes().await.unwrap_or_default();
        let message = error_message(&data).unwrap_or_else(|| status_text(status));
        let number = || serde_json::from_slice::<Value>(&data).ok().and_then(|v| v["data"]["number"].as_i64());
        match status {
            201 => PostResult::Created(number()),
            200 => PostResult::Existing(number()),
            410 => PostResult::Deleted,
            413 => PostResult::TooLarge,
            400..=499 => PostResult::Rejected(status, message),
            500..=599 => PostResult::ServerError(status, message),
            _ => PostResult::Unreachable(format!("Unexpected status {status}")),
        }
    }

    /// Deletes one record. True when the server removed it or never had it. Ids that are not the
    /// server's grammar are refused here, so `../` cannot leave `/annotations`.
    pub async fn delete(&self, id: &str) -> bool {
        if !is_valid_id(id) {
            return false;
        }
        match self.http.delete(self.appending(id)).send().await {
            Ok(response) => matches!(response.status().as_u16(), 200 | 404),
            Err(_) => false,
        }
    }

    /// The full records, and the summary of them.
    pub async fn queue(&self) -> Result<(QueueSummary, Vec<Value>), QueueError> {
        let response = self.http.get(self.base.clone()).send().await
            .map_err(|error| QueueError::Unreachable(describe(&error)))?;
        let status = response.status().as_u16();
        if status != 200 {
            return Err(QueueError::BadStatus(status));
        }
        let data = response.bytes().await.map_err(|error| QueueError::Unreachable(describe(&error)))?;
        // Screenshots dominate the payload. The menu never draws them, so the live queue does not keep them.
        let slim = nullify_strings(&["screenshot"], &data);
        let items = parse_queue(&slim).ok_or(QueueError::NotAnnotationServer)?;
        Ok((QueueSummary::new(&items), items))
    }

    /// The screenshot for one record. The live queue does not keep these.
    pub async fn screenshot(&self, id: &str) -> Option<String> {
        if !is_valid_id(id) {
            return None;
        }
        let response = self.http.get(self.base.clone()).send().await.ok()?;
        if response.status().as_u16() != 200 {
            return None;
        }
        let body: Value = serde_json::from_slice(&response.bytes().await.ok()?).ok()?;
        if body["meta"]["service"].as_str() != Some("@nckrtl/annotator") {
            return None;
        }
        body["data"].as_array()?.iter().find(|item| item["id"].as_str() == Some(id))?["screenshot"]
            .as_str().map(String::from)
    }
}

/// A record without its screenshot, to keep in memory.
pub fn without_screenshot(item: &Value) -> Value {
    let mut item = item.clone();
    if let Some(object) = item.as_object_mut() {
        object.remove("screenshot");
    }
    item
}

/// Server ids: `^[A-Za-z0-9][A-Za-z0-9_-]{0,199}$`.
pub fn is_valid_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    (1..=200).contains(&bytes.len())
        && bytes[0].is_ascii_alphanumeric()
        && bytes.iter().all(|b| b.is_ascii_alphanumeric() || *b == b'_' || *b == b'-')
}

/// Replaces the string values of `keys` with JSON `null`, without decoding those strings
/// (JSONRedactor.swift). A matching key whose value is not a string is left as it is.
pub fn nullify_strings(keys: &[&str], data: &[u8]) -> Vec<u8> {
    const QUOTE: u8 = b'"';
    let space = |b: u8| matches!(b, b' ' | b'\t' | b'\n' | b'\r');
    // The raw bytes inside a JSON string that starts at `open`, and the index just after its closing quote.
    let string = |open: usize| -> Option<(&[u8], usize)> {
        let mut index = open + 1;
        let mut escaped = false;
        while index < data.len() {
            let byte = data[index];
            index += 1;
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == QUOTE {
                return Some((&data[open + 1..index - 1], index));
            }
        }
        None
    };
    let mut output = Vec::with_capacity(data.len().min(256 * 1024));
    let (mut index, mut mark) = (0, 0);
    while index < data.len() {
        if data[index] != QUOTE {
            index += 1;
            continue;
        }
        let Some((literal, next)) = string(index) else {
            index += 1;
            continue;
        };
        let mut look = next;
        while look < data.len() && space(data[look]) { look += 1; }
        if look >= data.len() || data[look] != b':' || !keys.iter().any(|key| key.as_bytes() == literal) {
            index = next;
            continue;
        }
        let mut value = look + 1;
        while value < data.len() && space(data[value]) { value += 1; }
        let Some((_, after)) = (value < data.len() && data[value] == QUOTE).then(|| string(value)).flatten() else {
            index = next;
            continue;
        };
        output.extend_from_slice(&data[mark..index]);
        output.push(QUOTE);
        output.extend_from_slice(literal);
        output.extend_from_slice(b"\":null");
        index = after;
        mark = after;
    }
    output.extend_from_slice(&data[mark..]);
    output
}

/// The records of a `GET <base>` body, or None when the body is not from an annotation server.
/// Every record needs a string `id`, `status` and `comment`.
pub fn parse_queue(data: &[u8]) -> Option<Vec<Value>> {
    let body: Value = serde_json::from_slice(data).ok()?;
    if body["meta"]["service"].as_str() != Some("@nckrtl/annotator") {
        return None;
    }
    let items = body["data"].as_array()?.clone();
    let valid = items.iter().all(|item| ["id", "status", "comment"].iter().all(|key| item[key].is_string()));
    valid.then_some(items)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{serve, Reply};

    async fn post(reply: Reply) -> PostResult {
        let server = serve(vec![reply]);
        AnnotationClient::new(server.url("/annotations")).post(br#"{"id":"a","comment":"x"}"#.to_vec()).await
    }

    #[tokio::test]
    async fn created() {
        let result = post(Reply::new(201, r#"{"data":{"number":7}}"#)).await;
        assert_eq!(result, PostResult::Created(Some(7)));
        assert!(result.is_stored() && !result.is_retryable());
        assert_eq!(result.message(), "Sent as #7.");
    }

    #[tokio::test]
    async fn existing_on_retry() {
        let result = post(Reply::new(200, r#"{"data":{"number":7}}"#)).await;
        assert_eq!(result, PostResult::Existing(Some(7)));
        assert!(result.is_stored());
    }

    #[tokio::test]
    async fn deleted_is_not_resent() {
        let result = post(Reply::new(410, r#"{"error":"Annotation was removed"}"#)).await;
        assert_eq!(result, PostResult::Deleted);
        assert!(!result.is_stored() && !result.is_retryable());
    }

    #[tokio::test]
    async fn too_large_is_not_resent() {
        let result = post(Reply::new(413, r#"{"error":"Annotation exceeds 10 MiB"}"#)).await;
        assert_eq!(result, PostResult::TooLarge);
        assert!(!result.is_retryable());
    }

    #[tokio::test]
    async fn server_error_is_retried() {
        let result = post(Reply::new(500, r#"{"error":"Could not process annotation"}"#)).await;
        assert_eq!(result, PostResult::ServerError(500, "Could not process annotation".into()));
        assert!(result.is_retryable());
    }

    #[tokio::test]
    async fn other_client_error_is_rejected() {
        let result = post(Reply::new(422, r#"{"error":"id and comment are required"}"#)).await;
        assert_eq!(result, PostResult::Rejected(422, "id and comment are required".into()));
        assert!(!result.is_retryable());
    }

    #[tokio::test]
    async fn connection_failure_is_retried() {
        let result = AnnotationClient::new(crate::testutil::closed_url("/annotations")).post(b"{}".to_vec()).await;
        assert!(matches!(result, PostResult::Unreachable(_)), "{result:?}");
        assert!(result.is_retryable());
    }

    #[tokio::test]
    async fn post_sends_json() {
        let server = serve(vec![Reply::new(201, "")]);
        AnnotationClient::new(server.url("/annotations")).post(b"{}".to_vec()).await;
        let request = server.request(0);
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/annotations");
        assert_eq!(request.header("content-type"), Some("application/json"));
    }

    #[tokio::test]
    async fn delete_one() {
        let server = serve(vec![Reply::new(200, ""), Reply::new(404, ""), Reply::new(500, "")]);
        let client = AnnotationClient::new(server.url("/annotations"));
        assert!(client.delete("abc-1").await);
        let request = server.request(0);
        assert_eq!(request.method, "DELETE");
        assert_eq!(request.path, "/annotations/abc-1");
        assert!(client.delete("gone").await);
        assert!(!client.delete("x").await);
        assert!(!AnnotationClient::new(crate::testutil::closed_url("/annotations")).delete("x").await);
    }

    #[tokio::test]
    async fn queue_summary() {
        let body = r#"{"data":[
          {"id":"a","number":1,"status":"done","comment":"one"},
          {"id":"b","number":3,"status":"todo","comment":"three"},
          {"id":"c","number":2,"status":"in_progress","comment":"two"}
        ],"meta":{"service":"@nckrtl/annotator","lastNumber":3}}"#;
        let server = serve(vec![Reply::new(200, body)]);
        let (summary, items) = AnnotationClient::new(server.url("/annotations")).queue().await.unwrap();
        assert_eq!(items.len(), 3);
        assert_eq!((summary.todo, summary.in_progress, summary.done), (1, 1, 1));
        assert_eq!(summary.open.iter().map(|i| i.number()).collect::<Vec<_>>(), vec![Some(2), Some(3)]);
        assert_eq!(summary.finished.iter().map(|i| i.number()).collect::<Vec<_>>(), vec![Some(1)]);
        assert_eq!(summary.item("c").unwrap().status(), "in_progress");
    }

    #[tokio::test]
    async fn queue_reads_full_records() {
        let body = r#"{"data":[{"id":"a","number":4,"status":"todo","question":true,"summary":"Which button?","comment":"x",
          "element":"AXButton \"Save\"","boundingBox":{"x":1,"y":2,"width":3,"height":4},
          "native":{"app":{"name":"Mail","bundleId":"com.apple.mail","pid":1},"mode":"element","window":{"title":"Inbox","id":7}}},
          {"id":"b","status":"done","comment":"from the web annotator"}],
         "meta":{"service":"@nckrtl/annotator"}}"#;
        let server = serve(vec![Reply::new(200, body)]);
        let (summary, _) = AnnotationClient::new(server.url("/annotations")).queue().await.unwrap();
        let item = summary.item("a").unwrap();
        assert_eq!(item["question"], true);
        assert_eq!(item["native"]["app"]["name"], "Mail");
        assert_eq!(item["boundingBox"]["width"], 3);
        assert!(summary.item("b").unwrap().get("native").is_none());
    }

    #[tokio::test]
    async fn queue_rejects_other_servers() {
        let server = serve(vec![Reply::new(200, r#"{"data":[]}"#), Reply::new(503, "")]);
        let client = AnnotationClient::new(server.url("/annotations"));
        assert_eq!(client.queue().await.unwrap_err(), QueueError::NotAnnotationServer);
        assert_eq!(client.queue().await.unwrap_err(), QueueError::BadStatus(503));
    }

    #[tokio::test]
    async fn delete_rejects_path_ids() {
        let server = serve(vec![Reply::new(200, "")]);
        let client = AnnotationClient::new(server.url("/annotations"));
        assert!(!client.delete("../secret").await);
        assert!(!client.delete("foo/bar").await);
        assert!(server.paths().is_empty());
    }

    #[tokio::test]
    async fn queue_drops_screenshots() {
        let body = r#"{"data":[{"id":"a","number":1,"status":"todo","comment":"x","screenshot":"data:image/jpeg;base64,AAAA"}],
         "meta":{"service":"@nckrtl/annotator"}}"#;
        let server = serve(vec![Reply::new(200, body)]);
        let client = AnnotationClient::new(server.url("/annotations"));
        let (summary, items) = client.queue().await.unwrap();
        assert!(summary.item("a").unwrap()["screenshot"].is_null());
        assert!(items[0]["screenshot"].is_null());
        assert_eq!(client.screenshot("a").await.as_deref(), Some("data:image/jpeg;base64,AAAA"));
        assert_eq!(client.screenshot("b").await, None);
        assert_eq!(client.screenshot("../secret").await, None);
    }

    #[test]
    fn ids_match_the_server_grammar() {
        assert!(is_valid_id("abc-1"));
        assert!(is_valid_id("a"));
        assert!(is_valid_id(&"a".repeat(200)));
        assert!(!is_valid_id(&"a".repeat(201)));
        assert!(!is_valid_id("../secret"));
        assert!(!is_valid_id("foo/bar"));
        assert!(!is_valid_id(""));
        assert!(!is_valid_id("-abc"));
        assert!(!is_valid_id("é"));
    }

    #[test]
    fn redactor_nulls_screenshot_strings_only() {
        let input = br#"{"note":"see \"screenshot\"","screenshot":"HUGE","count":1,"nested":{"screenshot" : "also"}}"#;
        let output = nullify_strings(&["screenshot"], input);
        assert_eq!(String::from_utf8(output).unwrap(),
            r#"{"note":"see \"screenshot\"","screenshot":null,"count":1,"nested":{"screenshot":null}}"#);
        let number = br#"{"screenshot":1}"#;
        assert_eq!(nullify_strings(&["screenshot"], number), number);
    }

    #[test]
    fn events_url() {
        let client = AnnotationClient::new(url::Url::parse("http://127.0.0.1:29703/annotations").unwrap());
        assert_eq!(client.events_url().as_str(), "http://127.0.0.1:29703/annotations/events");
        let client = AnnotationClient::new(url::Url::parse("http://127.0.0.1:29703/annotations/").unwrap());
        assert_eq!(client.events_url().as_str(), "http://127.0.0.1:29703/annotations/events");
    }
}
