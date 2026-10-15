//! Server-wide retention, independent of the selected project or library filter.
use crate::annotations::{AnnotationClient, Item, QueueError};
use serde_json::Value;

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn expired(item: &Value, now: i64) -> bool {
    if item.status() != "done" || item["question"].as_bool() == Some(true) { return false; }
    // Fall back only when completion is absent, never when it is malformed.
    let time = match item.get("completedAt").filter(|value| !value.is_null()) {
        Some(value) => value.as_i64(),
        None => item["createdAt"].as_i64(),
    };
    time.is_some_and(|time| time > 0 && time < now.saturating_sub(DAY_MS))
}

#[derive(Debug, Default, PartialEq)]
pub struct Report {
    pub deleted: Vec<Option<i64>>,
    pub failed: Vec<Option<i64>>,
}

/// A fresh, service-validated snapshot is required before sending any DELETE.
pub async fn prune(client: &AnnotationClient, now: i64) -> Result<Report, QueueError> {
    let (_, items) = client.queue().await?;
    let mut report = Report::default();
    for item in items.iter().filter(|item| expired(item, now)) {
        if client.delete(item.id()).await { report.deleted.push(item.number()); }
        else { report.failed.push(item.number()); }
    }
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{serve, Reply};
    use serde_json::json;

    #[tokio::test]
    async fn deletes_only_expired_finished_records_across_projects() {
        let now = DAY_MS * 3;
        let mut items = vec![
            json!({"id":"old","number":1,"status":"done","completedAt":DAY_MS,"native":{"project":"Conn"}}),
            json!({"id":"fallback","number":2,"status":"done","createdAt":DAY_MS,"native":{"project":"T3 Code"}}),
            json!({"id":"boundary","status":"done","completedAt":now-DAY_MS}),
            json!({"id":"recent","status":"done","completedAt":now-1,"createdAt":1}),
            json!({"id":"todo","status":"todo","createdAt":1}),
            json!({"id":"working","status":"in_progress","completedAt":1}),
            json!({"id":"question","status":"done","question":true,"completedAt":1}),
            json!({"id":"missing","status":"done"}),
            json!({"id":"invalid","status":"done","completedAt":"bad","createdAt":1}),
            json!({"id":"future","status":"done","completedAt":now+1}),
            json!({"id":"zero","status":"done","completedAt":0}),
        ];
        for item in &mut items { item["comment"] = json!("fixture text, never logged"); }
        let body = json!({"meta":{"service":"@nckrtl/annotator"},"data":items}).to_string();
        let server = serve(vec![Reply::new(200, &body), Reply::new(200, "{}"), Reply::new(404, "{}")]);
        let client = AnnotationClient::new(server.url("/annotations"));
        assert_eq!(prune(&client, now).await.unwrap(), Report { deleted: vec![Some(1), Some(2)], failed: vec![] });
        assert_eq!(server.paths(), ["/annotations", "/annotations/old", "/annotations/fallback"]);
        assert_eq!(server.request(1).method, "DELETE");
        assert_eq!(server.request(2).method, "DELETE");
    }

    #[tokio::test]
    async fn refuses_wrong_server_and_reports_failed_deletes() {
        let wrong = serve(vec![Reply::new(200, r#"{"data":[]}"#)]);
        assert_eq!(prune(&AnnotationClient::new(wrong.url("/annotations")), DAY_MS*3).await,
            Err(QueueError::NotAnnotationServer));
        assert_eq!(wrong.paths(), ["/annotations"]);
        let body = r#"{"meta":{"service":"@nckrtl/annotator"},"data":[{"id":"old","number":3,"status":"done","completedAt":1,"comment":"fixture"}]}"#;
        let server = serve(vec![Reply::new(200, body), Reply::new(500, "{}")]);
        assert_eq!(prune(&AnnotationClient::new(server.url("/annotations")), DAY_MS*3).await.unwrap(),
            Report { deleted: vec![], failed: vec![Some(3)] });
    }
}
