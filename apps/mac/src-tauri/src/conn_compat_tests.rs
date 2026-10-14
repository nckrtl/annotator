use super::*;
use crate::testutil::{serve, Reply};

const OLD: &str = include_str!("../fixtures/conn/old-snapshot.json");
const CURRENT: &str = include_str!("../fixtures/conn/current-snapshot.json");
const FUTURE: &str = include_str!("../fixtures/conn/future-snapshot.json");
const OLD_THREAD: &str = include_str!("../fixtures/conn/old-thread.json");
const CURRENT_THREAD: &str = include_str!("../fixtures/conn/current-thread.json");
const FUTURE_THREAD: &str = include_str!("../fixtures/conn/future-thread.json");
const DESCRIPTOR: &str = r#"{"serverVersion":"0.0.46-preview.20261010.2909","orchestrationProtocolVersion":2}"#;

#[test]
fn old_current_and_future_read_models() {
    for fixture in [OLD, CURRENT, FUTURE] {
        let snapshot: Snapshot = wire::decode(fixture.as_bytes(), "snapshot", None).unwrap();
        assert_eq!(snapshot.project("/example/app").unwrap().id, "project-example");
        assert!(snapshot.latest_model().is_some());
    }
    assert!(wire::thread(OLD_THREAD.as_bytes(), false, None).unwrap().is_idle());
    assert!(wire::thread(CURRENT_THREAD.as_bytes(), true, None).unwrap().is_idle());
    assert!(!wire::thread(FUTURE_THREAD.as_bytes(), true, None).unwrap().is_idle());
}

#[test]
fn missing_and_changed_optional_fields_do_not_block_start() {
    let mut value: Value = serde_json::from_str(CURRENT).unwrap();
    for key in ["title", "createdAt", "updatedAt"] { value["projects"][0].as_object_mut().unwrap().remove(key); }
    for threads in [Value::Null, json!([]), json!([{"modelSelection":{"model":"partial"}}]), json!([{"modelSelection":17,"session":false}])] {
        value["threads"] = threads;
        let snapshot: Snapshot = wire::decode(value.to_string().as_bytes(), "snapshot", None).unwrap();
        assert_eq!(snapshot.project("/example/app").unwrap().id, "project-example");
        assert_eq!(snapshot.latest_model(), None);
    }
    value.as_object_mut().unwrap().remove("threads");
    assert!(wire::decode::<Snapshot>(value.to_string().as_bytes(), "snapshot", None).is_ok());
}

#[test]
fn required_fields_report_path_and_version() {
    for field in ["id", "workspaceRoot"] {
        let mut value: Value = serde_json::from_str(CURRENT).unwrap();
        for invalid in [None, Some(Value::Null), Some(json!(" ")), Some(json!(17))] {
            let project = value["projects"][0].as_object_mut().unwrap();
            project.remove(field);
            if let Some(invalid) = invalid { project.insert(field.into(), invalid); }
            let error = wire::decode::<Snapshot>(value.to_string().as_bytes(), "snapshot", Some("test-version")).unwrap_err().to_string();
            assert!(error.contains("projects[0]") && error.contains(field) && error.contains("test-version"), "{error}");
        }
    }
    let error = wire::thread(br#"{"projection":{"thread":{}}}"#, true, Some("test-version")).unwrap_err().to_string();
    assert!(error.contains("projection.thread") && error.contains("id") && error.contains("test-version"));
    assert!(wire::decode::<Snapshot>(b"{}", "snapshot", None).unwrap_err().to_string().contains("projects"));
}

#[test]
fn unknown_or_missing_activity_never_means_idle() {
    for session in [json!({}), json!({"status":"ready"}), json!({"status":"future", "activeTurnId":null}),
        json!({"status":"running","activeTurnId":"turn-example"}), json!({"status":"ready","activeTurnId":17}), Value::Null] {
        let body = json!({"thread":{"id":"t","session":session}});
        assert!(!wire::thread(body.to_string().as_bytes(), false, None).unwrap().is_idle());
    }
    for runs in [Value::Null, json!([{}]), json!([{"status":"running"}]), json!([{"status":"queued"}]), json!([{"status":"waiting"}]), json!([{"status":"new-state"}])] {
        let body = json!({"projection":{"thread":{"id":"t"},"runs":runs}});
        assert!(!wire::thread(body.to_string().as_bytes(), true, None).unwrap().is_idle());
    }
    for state in ["completed", "failed", "cancelled", "interrupted", "rolled_back"] {
        let body = json!({"projection":{"thread":{"id":"t"},"runs":[{"status":state}]}});
        assert!(wire::thread(body.to_string().as_bytes(), true, None).unwrap().is_idle());
    }
}

#[tokio::test]
async fn negotiates_snapshot_and_thread_and_preserves_authentication() {
    for (descriptor, snapshot, thread, path) in [
        ("{\"serverVersion\":\"old\"}", OLD, OLD_THREAD, "/api/orchestration/snapshot"),
        (DESCRIPTOR, CURRENT, CURRENT_THREAD, "/api/orchestration/shell"),
        (DESCRIPTOR, FUTURE, FUTURE_THREAD, "/api/orchestration/shell"),
    ] {
        let server = serve(vec![Reply::new(200, descriptor), Reply::new(200, snapshot), Reply::new(200, thread)]);
        let client = Client::new(server.url(""), "fixture-token".into());
        client.snapshot().await.unwrap();
        client.thread("thread-example").await.unwrap();
        assert_eq!(server.paths(), ["/.well-known/t3/environment", path, "/api/orchestration/threads/thread-example"]);
        assert_eq!(server.request(1).header("x-t3-orchestration-protocol"), Some("2"));
        assert_eq!(server.request(1).header("authorization"), Some("Bearer fixture-token"));
    }
}

#[tokio::test]
async fn rejects_wrong_thread_and_unknown_protocol_before_writes() {
    let server = serve(vec![Reply::new(200, DESCRIPTOR), Reply::new(200, CURRENT_THREAD)]);
    assert!(Client::new(server.url(""), "fixture".into()).thread("wrong").await.unwrap_err().to_string().contains("id does not match"));
    let server = serve(vec![Reply::new(200, r#"{"serverVersion":"future","orchestrationProtocolVersion":3}"#)]);
    let error = Client::new(server.url(""), "fixture".into()).dispatch(&json!({"type":"thread.create"})).await.unwrap_err();
    assert!(error.to_string().contains("orchestrationProtocolVersion") && error.to_string().contains("future"));
    assert_eq!(server.paths().len(), 1);
}

#[tokio::test]
async fn old_session_start_saves_only_after_dispatch_acknowledgement() {
    for last_reply in [r#"{"sequence":3}"#, "<!doctype html><html>Conn</html>"] {
        let server = serve(vec![Reply::new(200, "{}"), Reply::new(200, OLD), Reply::new(200, r#"{"sequence":2}"#), Reply::new(200, last_reply)]);
        let folder = crate::testutil::temp_dir("conn-start");
        let conn = Conn::new(folder.join("sessions.json"));
        let settings = Settings { t3_endpoint: server.url("").to_string().trim_end_matches('/').into(), ..Settings::default() };
        let project = Project { root:"/example/app".into(), ..Project::new("Example") };
        let result = conn.start_with_client(&settings, &project, "Fix annotation #1", Some(Client::new(server.url(""), "fixture".into()))).await;
        assert_eq!(result.is_ok(), last_reply.starts_with('{'));
        assert_eq!(conn.session(&project, &settings).is_some(), result.is_ok());
        let create: Value = serde_json::from_slice(&server.request(2).body).unwrap();
        let send: Value = serde_json::from_slice(&server.request(3).body).unwrap();
        assert_eq!(create["type"], "thread.create");
        assert_eq!(send["type"], "thread.turn.start");
        assert_eq!(send["message"]["text"], "Fix annotation #1");
        assert_eq!(send["threadId"], create["threadId"]);
        let _ = std::fs::remove_dir_all(folder);
    }
}

async fn http_request(stream: &mut tokio::net::TcpStream) -> (String, Value) {
    use tokio::io::AsyncReadExt;
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        header.push(stream.read_u8().await.unwrap());
        assert!(header.len() < 16_384);
    }
    let header = String::from_utf8(header).unwrap();
    assert!(header.to_lowercase().contains("authorization: bearer fixture-token\r\n"));
    let length = header.lines().find_map(|line| {
        let (key, value) = line.split_once(':')?;
        key.eq_ignore_ascii_case("content-length").then(|| value.trim().parse::<usize>().unwrap())
    }).unwrap_or(0);
    let mut body = vec![0; length];
    stream.read_exact(&mut body).await.unwrap();
    (header.lines().next().unwrap().into(), serde_json::from_slice(&body).unwrap_or(Value::Null))
}

async fn http_reply(stream: &mut tokio::net::TcpStream, body: &str) {
    use tokio::io::AsyncWriteExt;
    stream.write_all(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
}

async fn rpc_request(stream: tokio::net::TcpStream, reply: Value) -> Value {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::{handshake::server::{Request, Response}, Message};
    let mut socket = tokio_tungstenite::accept_hdr_async(stream, |request: &Request, response: Response| {
        assert_eq!(request.uri(), "/ws?orchestrationProtocol=2");
        assert_eq!(request.headers()["authorization"], "Bearer fixture-token");
        Ok(response)
    }).await.unwrap();
    let request: Value = serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(request["_tag"], "Request");
    assert_eq!(request["tag"], "orchestration.dispatchCommand");
    assert_eq!(request["headers"], json!([]));
    assert_eq!(request["payload"]["createdBy"], "user");
    assert_eq!(request["payload"]["creationSource"], "web");
    // Exercise Effect's JSON keepalive independently of WebSocket control pings.
    socket.send(Message::Text(json!({"_tag":"Ping"}).to_string().into())).await.unwrap();
    assert_eq!(socket.next().await.unwrap().unwrap().to_text().unwrap(), r#"{"_tag":"Pong"}"#);
    socket.send(Message::Text(json!({"_tag":"Exit","requestId":request["id"],"exit":reply}).to_string().into())).await.unwrap();
    let _ = socket.next().await;
    request["payload"].clone()
}

#[tokio::test]
async fn v2_session_creates_project_thread_dispatches_and_reads_back_without_keychain() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = url::Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
    let task = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        assert_eq!(http_request(&mut stream).await.0, "GET /.well-known/t3/environment HTTP/1.1");
        http_reply(&mut stream, DESCRIPTOR).await;
        let (mut stream, _) = listener.accept().await.unwrap();
        assert_eq!(http_request(&mut stream).await.0, "GET /api/orchestration/shell HTTP/1.1");
        http_reply(&mut stream, CURRENT).await;
        let (mut stream, _) = listener.accept().await.unwrap();
        let (path, project) = http_request(&mut stream).await;
        assert_eq!(path, "POST /api/projects/mutate HTTP/1.1");
        assert_eq!(project["type"], "project.create");
        assert_eq!(project["createWorkspaceRootIfMissing"], false);
        assert!(project.get("createdAt").is_none());
        http_reply(&mut stream, &json!({"id":project["projectId"],"workspaceRoot":project["workspaceRoot"]}).to_string()).await;
        let (stream, _) = listener.accept().await.unwrap();
        let create = rpc_request(stream, json!({"_tag":"Success","value":{"sequence":2}})).await;
        assert_eq!(create["type"], "thread.create");
        assert_eq!(create["projectId"], project["projectId"]);
        assert_eq!(create["modelSelection"]["model"], "example-model");
        assert_eq!(create["runtimeMode"], "approval-required");
        assert!(create.get("createdAt").is_none());
        let (stream, _) = listener.accept().await.unwrap();
        let send = rpc_request(stream, json!({"_tag":"Success","value":{"sequence":3}})).await;
        assert_eq!(send["type"], "message.dispatch");
        assert_eq!(send["dispatchMode"], json!({"type":"start_immediately"}));
        assert_eq!(send["threadId"], create["threadId"]);
        assert_eq!(send["text"], "Fix annotation #1");
        assert_eq!(send["attachments"], json!([]));
        assert!(send["messageId"].as_str().is_some());
        for field in ["message", "runtimeMode", "interactionMode", "createdAt"] { assert!(send.get(field).is_none()); }
        let (mut stream, _) = listener.accept().await.unwrap();
        assert_eq!(http_request(&mut stream).await.0, "GET /.well-known/t3/environment HTTP/1.1");
        http_reply(&mut stream, DESCRIPTOR).await;
        let (mut stream, _) = listener.accept().await.unwrap();
        assert_eq!(http_request(&mut stream).await.0, format!("GET /api/orchestration/threads/{} HTTP/1.1", create["threadId"].as_str().unwrap()));
        let mut thread: Value = serde_json::from_str(CURRENT_THREAD).unwrap();
        thread["projection"]["thread"]["id"] = create["threadId"].clone();
        http_reply(&mut stream, &thread.to_string()).await;
        let (stream, _) = listener.accept().await.unwrap();
        let nudge = rpc_request(stream, json!({"_tag":"Success","value":{"sequence":4}})).await;
        assert_eq!(nudge["type"], "message.dispatch");
        assert!(nudge["text"].as_str().unwrap().contains("#2"));
    });
    let folder = crate::testutil::temp_dir("conn-v2-start");
    let conn = Conn::new(folder.join("sessions.json"));
    let settings = Settings { t3_endpoint: origin.to_string().trim_end_matches('/').into(), t3_default_model: String::new(), ..Settings::default() };
    let project = Project { root:"/example/new".into(), t3_runtime_mode:"approval-required".into(), ..Project::new("Example") };
    let run = async {
        let id = conn.start_with_client(&settings, &project, "Fix annotation #1", Some(Client::new(origin.clone(), "fixture-token".into()))).await.unwrap();
        assert_eq!(Conn::new(folder.join("sessions.json")).session(&project, &settings).unwrap().thread_id, id);
        let client = Client::new(origin, "fixture-token".into());
        assert!(client.thread(&id).await.unwrap().is_idle());
        client.dispatch(&command::send_message(&id, &nudge_text(&[2]), "approval-required", None)).await.unwrap();
        task.await.unwrap();
    };
    tokio::time::timeout(Duration::from_secs(10), run).await.unwrap();
    std::fs::remove_dir_all(folder).unwrap();
}

#[tokio::test]
async fn rpc_rejection_and_missing_acknowledgement_are_errors() {
    for exit in [json!({"_tag":"Success","value":{}}), json!({"_tag":"Failure","cause":[{"_tag":"Fail","error":{"message":"Fixture rejection"}}]})] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = url::Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let task = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            http_request(&mut stream).await;
            http_reply(&mut stream, DESCRIPTOR).await;
            let (stream, _) = listener.accept().await.unwrap();
            rpc_request(stream, exit).await;
        });
        let client = Client::new(origin, "fixture-token".into());
        assert!(client.dispatch(&command::send_message("t", "Go", "approval-required", None)).await.is_err());
        task.await.unwrap();
    }
}
