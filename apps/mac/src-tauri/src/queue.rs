//! Keeps the queue live (QueueMonitor.swift). Listens to the server's event stream; when the
//! stream drops, polls every 3 s and reports the server unreachable after three failed polls.

use crate::annotations::{AnnotationClient, QueueError, QueueSummary};
use futures_util::StreamExt;
use serde_json::Value;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub enum Connection {
    Connecting,
    Live,
    Polling,
    Unreachable(String),
    WrongServer,
    InvalidUrl,
}

#[derive(Default)]
struct Inner {
    connection: Option<Connection>,
    summary: Option<QueueSummary>,
    items: Vec<Value>,
    failed_polls: u32,
    generation: u64,
    /// The generation a download runs for. One at a time: a second caller asks for one more pass
    /// and waits for it.
    refreshing: Option<u64>,
    /// Refresh requests so far, and the last request the finished passes cover, with that pass's result.
    requested: u64,
    covered: u64,
    covered_ok: bool,
    task: Option<tokio::task::JoinHandle<()>>,
}

type Callback = Box<dyn Fn() + Send + Sync>;

pub struct QueueMonitor {
    inner: Mutex<Inner>,
    /// After every change of the summary or the connection.
    on_change: Callback,
    /// When a refresh succeeds after one or more failures.
    on_reachable: Callback,
    stream: reqwest::Client,
    /// Wakes callers that wait for a pass, after each pass and each new run.
    passes: tokio::sync::Notify,
    /// Wakes a retention pass that waits for the server, after each successful load.
    loaded: tokio::sync::Notify,
}

impl QueueMonitor {
    pub fn new(on_change: impl Fn() + Send + Sync + 'static, on_reachable: impl Fn() + Send + Sync + 'static) -> Arc<QueueMonitor> {
        Arc::new(QueueMonitor { inner: Mutex::default(), on_change: Box::new(on_change), on_reachable: Box::new(on_reachable),
            stream: crate::http::event_stream(), passes: Default::default(), loaded: Default::default() })
    }

    pub fn connection(&self) -> Connection {
        self.inner.lock().unwrap().connection.clone().unwrap_or(Connection::Connecting)
    }

    pub fn summary(&self) -> Option<QueueSummary> {
        self.inner.lock().unwrap().summary.clone()
    }

    /// The full records from the server, with `screenshot` null (see `AnnotationClient::screenshot`).
    pub fn items(&self) -> Vec<Value> {
        self.inner.lock().unwrap().items.clone()
    }

    pub fn start(self: &Arc<Self>, client: Option<AnnotationClient>) {
        let generation = {
            let mut inner = self.inner.lock().unwrap();
            if let Some(task) = inner.task.take() {
                task.abort();
            }
            inner.generation += 1;
            inner.summary = None;
            inner.items = Vec::new();
            inner.failed_polls = 0;
            inner.connection = Some(if client.is_some() { Connection::Connecting } else { Connection::InvalidUrl });
            inner.generation
        };
        // Callers that wait for a pass of the old run get `false`.
        self.passes.notify_waiters();
        (self.on_change)();
        let Some(client) = client else { return };
        let monitor = self.clone();
        let task = crate::runtime::spawn(async move { monitor.run(client, generation).await });
        let mut inner = self.inner.lock().unwrap();
        if inner.generation == generation {
            inner.task = Some(task);
        } else {
            task.abort();
        }
    }

    pub fn refresh_now(self: &Arc<Self>, client: Option<AnnotationClient>) {
        let Some(client) = client else { return };
        let generation = self.inner.lock().unwrap().generation;
        let monitor = self.clone();
        crate::runtime::spawn(async move { monitor.refresh(&client, generation).await });
    }

    async fn run(&self, client: AnnotationClient, generation: u64) {
        tokio::select! {
            _ = self.run_connection(&client, generation) => {},
            _ = self.retain_recent(&client, generation) => {},
        }
    }

    async fn retain_recent(&self, client: &AnnotationClient, generation: u64) {
        loop {
            if !self.current(generation) { return; }
            // Listen before the pass, so a load that succeeds during it is not missed.
            let loaded = self.loaded.notified();
            tokio::pin!(loaded);
            loaded.as_mut().enable();
            let wait = Duration::from_secs(3600);
            match crate::retention::prune(client, chrono::Utc::now().timestamp_millis()).await {
                Ok(report) => {
                    crate::log(&format!("Retention deleted count={} numbers={:?}; failed count={} numbers={:?}",
                        report.deleted.len(), report.deleted, report.failed.len(), report.failed));
                    if !report.deleted.is_empty() { self.refresh(client, generation).await; }
                    tokio::time::sleep(wait).await;
                }
                Err(QueueError::Unreachable(error)) => {
                    // The server may not be up yet. Try again once a load succeeds, not an hour later.
                    crate::log(&format!("Retention waits for the server: {error}"));
                    tokio::select! { _ = loaded => {}, _ = tokio::time::sleep(wait) => {} }
                }
                Err(error) => {
                    crate::log(&format!("Retention failed: {error}"));
                    tokio::time::sleep(wait).await;
                }
            }
        }
    }

    async fn run_connection(&self, client: &AnnotationClient, generation: u64) {
        loop {
            self.listen(client, generation).await;
            // A server that is not the annotation server will not become one by being asked again.
            // A new URL starts a new run.
            if self.wrong_server() {
                return;
            }
            // The stream dropped or never opened. Poll until the server answers, then try the stream again.
            loop {
                tokio::time::sleep(Duration::from_secs(3)).await;
                if !self.current(generation) || self.wrong_server() {
                    return;
                }
                let recovered = self.refresh(client, generation).await;
                if self.wrong_server() {
                    return;
                }
                if recovered {
                    break;
                }
            }
        }
    }

    fn current(&self, generation: u64) -> bool {
        self.inner.lock().unwrap().generation == generation
    }

    fn wrong_server(&self) -> bool {
        self.inner.lock().unwrap().connection == Some(Connection::WrongServer)
    }

    async fn listen(&self, client: &AnnotationClient, generation: u64) {
        if let Ok(response) = self.stream.get(client.events_url()).send().await {
            if response.status().as_u16() == 200 && self.refresh(client, generation).await {
                self.set_connection(Connection::Live, generation);
                let mut bytes = response.bytes_stream();
                let mut line = Vec::new();
                // The server sends a heartbeat every 15 s.
                while let Ok(Some(Ok(chunk))) = tokio::time::timeout(Duration::from_secs(45), bytes.next()).await {
                    for byte in chunk {
                        if byte != b'\n' {
                            line.push(byte);
                            continue;
                        }
                        if line.starts_with(b"data:") {
                            self.refresh(client, generation).await;
                        }
                        line.clear();
                    }
                    if !self.current(generation) {
                        return;
                    }
                }
            }
        }
        if self.inner.lock().unwrap().connection == Some(Connection::Live) {
            self.set_connection(Connection::Polling, generation);
        }
    }

    /// One download at a time per generation. A second caller does not start its own: it waits for
    /// the next pass, which starts after its request. Each caller returns the result of the first
    /// pass that covers its request.
    async fn refresh(&self, client: &AnnotationClient, generation: u64) -> bool {
        let request = {
            let mut inner = self.inner.lock().unwrap();
            inner.requested += 1;
            inner.requested
        };
        let mut covers = loop {
            let passed = self.passes.notified();
            {
                let mut inner = self.inner.lock().unwrap();
                if inner.generation != generation {
                    return false;
                }
                if inner.covered >= request {
                    return inner.covered_ok;
                }
                if inner.refreshing != Some(generation) {
                    inner.refreshing = Some(generation);
                    break inner.requested;
                }
            }
            passed.await;
        };
        // Frees the slot and wakes the waiters also when this future is dropped mid-download.
        let _pass = Pass { monitor: self, generation };
        let mut first = None;
        loop {
            let ok = self.load(client, generation).await;
            let result = *first.get_or_insert(ok);
            let again = {
                let mut inner = self.inner.lock().unwrap();
                if covers > inner.covered {
                    inner.covered = covers;
                    inner.covered_ok = ok;
                }
                let again = inner.generation == generation && inner.requested > covers;
                covers = inner.requested;
                again
            };
            self.passes.notify_waiters();
            if !again {
                return result;
            }
        }
    }

    async fn load(&self, client: &AnnotationClient, generation: u64) -> bool {
        let result = client.queue().await;
        let mut inner = self.inner.lock().unwrap();
        if inner.generation != generation {
            return false;
        }
        match result {
            Ok((summary, items)) => {
                let recovered = inner.failed_polls > 0 || inner.connection != Some(Connection::Live);
                inner.failed_polls = 0;
                inner.summary = Some(summary);
                inner.items = items;
                if inner.connection != Some(Connection::Live) {
                    inner.connection = Some(Connection::Polling);
                }
                drop(inner);
                (self.on_change)();
                if recovered {
                    (self.on_reachable)();
                }
                self.loaded.notify_waiters();
                true
            }
            Err(QueueError::NotAnnotationServer) => {
                inner.connection = Some(Connection::WrongServer);
                drop(inner);
                (self.on_change)();
                false
            }
            Err(error) => {
                inner.failed_polls += 1;
                if inner.failed_polls >= 3 {
                    inner.connection = Some(Connection::Unreachable(error.to_string()));
                    drop(inner);
                    (self.on_change)();
                }
                false
            }
        }
    }

    fn set_connection(&self, connection: Connection, generation: u64) {
        {
            let mut inner = self.inner.lock().unwrap();
            if inner.generation != generation {
                return;
            }
            inner.connection = Some(connection);
        }
        (self.on_change)();
    }
}

/// The running download of one generation.
struct Pass<'a> {
    monitor: &'a QueueMonitor,
    generation: u64,
}

impl Drop for Pass<'_> {
    fn drop(&mut self) {
        {
            let mut inner = self.monitor.inner.lock().unwrap();
            if inner.refreshing == Some(self.generation) {
                inner.refreshing = None;
            }
        }
        self.monitor.passes.notify_waiters();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{closed_url, serve, Reply};
    use std::sync::atomic::{AtomicUsize, Ordering};

    const BODY: &str = r#"{"data":[{"id":"a","number":1,"status":"todo","comment":"x"}],"meta":{"service":"@nckrtl/annotator"}}"#;

    fn monitor() -> (Arc<QueueMonitor>, Arc<AtomicUsize>) {
        let reachable = Arc::new(AtomicUsize::new(0));
        let counter = reachable.clone();
        (QueueMonitor::new(|| {}, move || { counter.fetch_add(1, Ordering::SeqCst); }), reachable)
    }

    #[tokio::test]
    async fn invalid_url() {
        let (monitor, _) = monitor();
        monitor.start(None);
        assert_eq!(monitor.connection(), Connection::InvalidUrl);
    }

    #[tokio::test]
    async fn unreachable_after_three_failed_polls() {
        let (monitor, _) = monitor();
        let client = AnnotationClient::new(closed_url("/annotations"));
        assert!(!monitor.refresh(&client, 0).await);
        assert!(!monitor.refresh(&client, 0).await);
        assert_eq!(monitor.connection(), Connection::Connecting);
        assert!(!monitor.refresh(&client, 0).await);
        assert_eq!(monitor.connection(),
            Connection::Unreachable("Server unreachable: Could not connect to the server.".into()));
    }

    #[tokio::test]
    async fn wrong_server_and_recovery() {
        let (monitor, reachable) = monitor();
        let other = serve(vec![Reply::new(200, r#"{"data":[]}"#)]);
        assert!(!monitor.refresh(&AnnotationClient::new(other.url("/annotations")), 0).await);
        assert_eq!(monitor.connection(), Connection::WrongServer);
        let server = serve(vec![Reply::new(200, BODY)]);
        assert!(monitor.refresh(&AnnotationClient::new(server.url("/annotations")), 0).await);
        assert_eq!(monitor.connection(), Connection::Polling);
        assert_eq!(monitor.summary().unwrap().todo, 1);
        assert_eq!(reachable.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn refreshes_coalesce() {
        let server = serve(vec![Reply::new(200, BODY).delayed(200)]);
        let (monitor, _) = monitor();
        let client = AnnotationClient::new(server.url("/annotations"));
        let (a, b, c) = tokio::join!(monitor.refresh(&client, 0), monitor.refresh(&client, 0), monitor.refresh(&client, 0));
        assert!(a && b && c);
        // The first download, then one more pass for the two callers that waited.
        assert_eq!(server.paths().len(), 2);
    }

    #[tokio::test]
    async fn waiting_callers_get_the_result_of_their_pass() {
        let server = serve(vec![Reply::new(200, BODY).delayed(200), Reply::new(503, "")]);
        let (monitor, _) = monitor();
        let client = AnnotationClient::new(server.url("/annotations"));
        let (a, b, c) = tokio::join!(monitor.refresh(&client, 0), monitor.refresh(&client, 0), monitor.refresh(&client, 0));
        assert_eq!((a, b, c), (true, false, false));
        assert_eq!(server.paths().len(), 2);
    }

    #[tokio::test]
    async fn stream_is_live_only_after_a_load_succeeds() {
        // A slow failing refresh runs; the stream opens; the pass that covers the stream fails too.
        let server = serve(vec![Reply::new(503, "").delayed(300), Reply::new(200, "data: change\n\n"), Reply::new(503, "")]);
        let (monitor, _) = monitor();
        let client = AnnotationClient::new(server.url("/annotations"));
        let (running, _) = tokio::join!(monitor.refresh(&client, 0), async {
            tokio::time::sleep(Duration::from_millis(50)).await;
            monitor.listen(&client, 0).await;
        });
        assert!(!running);
        // `listen` sets Polling only after Live.
        assert_eq!(monitor.connection(), Connection::Connecting);
        assert_eq!(server.paths(), ["/annotations?screenshots=0", "/annotations/events", "/annotations?screenshots=0"]);
    }

    #[tokio::test]
    async fn a_dropped_download_frees_the_slot() {
        let server = serve(vec![Reply::new(200, BODY).delayed(500), Reply::new(200, BODY)]);
        let (monitor, _) = monitor();
        let client = AnnotationClient::new(server.url("/annotations"));
        let (dropped, waiter) = tokio::join!(
            tokio::time::timeout(Duration::from_millis(100), monitor.refresh(&client, 0)),
            async { tokio::time::sleep(Duration::from_millis(20)).await; monitor.refresh(&client, 0).await });
        assert!(dropped.is_err());
        assert!(waiter);
        assert_eq!(server.paths().len(), 2);
    }

    #[tokio::test]
    async fn a_new_run_releases_waiting_callers() {
        let server = serve(vec![Reply::new(200, BODY).delayed(300)]);
        let (monitor, _) = monitor();
        let client = AnnotationClient::new(server.url("/annotations"));
        let (_, waiter) = tokio::join!(monitor.refresh(&client, 0), async {
            tokio::time::sleep(Duration::from_millis(20)).await;
            let waiter = monitor.refresh(&client, 0);
            tokio::pin!(waiter);
            assert!(tokio::time::timeout(Duration::from_millis(20), waiter.as_mut()).await.is_err());
            monitor.start(None);
            waiter.await
        });
        assert!(!waiter);
    }

    #[tokio::test]
    async fn retention_retries_after_the_server_comes_up() {
        let url = closed_url("/annotations");
        let (monitor, _) = monitor();
        let retention = monitor.clone();
        let base = url.clone();
        let task = tokio::spawn(async move { retention.retain_recent(&AnnotationClient::new(base), 0).await });
        tokio::time::sleep(Duration::from_millis(200)).await;
        let listener = std::net::TcpListener::bind(("127.0.0.1", url.port().unwrap())).unwrap();
        let body = r#"{"data":[{"id":"old","number":3,"status":"done","completedAt":1,"comment":"fixture"}],"meta":{"service":"@nckrtl/annotator"}}"#;
        let server = crate::testutil::serve_on(listener, vec![Reply::new(200, body)]);
        assert!(monitor.refresh(&AnnotationClient::new(url), 0).await);
        let deleted = tokio::time::timeout(Duration::from_secs(5), async {
            while !server.paths().contains(&"/annotations/old".to_string()) {
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        }).await;
        task.abort();
        assert!(deleted.is_ok(), "retention waited for the hourly pass");
    }

    #[tokio::test]
    async fn wrong_server_stops_the_run() {
        let server = serve(vec![Reply::new(404, ""), Reply::new(200, r#"{"data":[]}"#)]);
        let (monitor, _) = monitor();
        let run = tokio::time::timeout(Duration::from_secs(10),
            monitor.run_connection(&AnnotationClient::new(server.url("/annotations")), 0)).await;
        assert!(run.is_ok(), "the run kept polling");
        assert_eq!(monitor.connection(), Connection::WrongServer);
        assert_eq!(server.paths().len(), 2);
    }

    #[tokio::test]
    async fn live_stream_refreshes_on_data() {
        // The events endpoint answers 200 with one event, then closes: live, then polling.
        let server = serve(vec![Reply::new(200, "data: change\n\n"), Reply::new(200, BODY)]);
        let (monitor, _) = monitor();
        monitor.listen(&AnnotationClient::new(server.url("/annotations")), 0).await;
        assert_eq!(monitor.connection(), Connection::Polling);
        assert_eq!(server.paths()[..3], ["/annotations/events", "/annotations?screenshots=0", "/annotations?screenshots=0"]);
    }
}
