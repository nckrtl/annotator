//! Local copies of annotations until the server stores them (PendingStore.swift, Submitter.swift).
//! `pending/` holds records that wait for a retry. `failed/` holds records the server refused,
//! so the comment is never lost silently.

use crate::annotations::{AnnotationClient, PostResult};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;

#[derive(Clone)]
pub struct PendingStore {
    pub root: PathBuf,
}

impl PendingStore {
    /// `~/Library/Application Support/Annotator`, as the Swift app used.
    pub fn standard() -> PendingStore {
        PendingStore { root: crate::settings::home().join("Library/Application Support/Annotator") }
    }

    fn pending_directory(&self) -> PathBuf {
        self.root.join("pending")
    }

    pub fn failed_directory(&self) -> PathBuf {
        self.root.join("failed")
    }

    pub fn save(&self, id: &str, body: &[u8]) -> Result<(), String> {
        crate::settings::write_atomic(&self.pending_directory().join(format!("{id}.json")), body)
    }

    pub fn remove(&self, id: &str) {
        let _ = std::fs::remove_file(self.pending_directory().join(format!("{id}.json")));
    }

    /// Moves a refused record out of the retry queue.
    pub fn mark_failed(&self, id: &str) -> Result<(), String> {
        let folder = self.failed_directory();
        std::fs::create_dir_all(&folder).map_err(|e| e.to_string())?;
        let target = folder.join(format!("{id}.json"));
        let _ = std::fs::remove_file(&target);
        std::fs::rename(self.pending_directory().join(format!("{id}.json")), target).map_err(|e| e.to_string())
    }

    /// Pending records, oldest first.
    pub fn pending(&self) -> Vec<(String, Vec<u8>)> {
        records(&self.pending_directory())
    }

    pub fn failed_count(&self) -> usize {
        records(&self.failed_directory()).len()
    }
}

fn records(folder: &Path) -> Vec<(String, Vec<u8>)> {
    let Ok(entries) = std::fs::read_dir(folder) else { return Vec::new() };
    let mut files: Vec<(std::time::SystemTime, PathBuf)> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|e| e == "json"))
        .map(|path| {
            let created = std::fs::metadata(&path).and_then(|m| m.created()).unwrap_or(std::time::UNIX_EPOCH);
            (created, path)
        })
        .collect();
    files.sort_by_key(|(created, _)| *created);
    files.into_iter()
        .filter_map(|(_, path)| {
            let id = path.file_stem()?.to_string_lossy().into_owned();
            std::fs::read(&path).ok().map(|body| (id, body))
        })
        .collect()
}

#[derive(Default, Clone, Debug, PartialEq)]
pub struct Counts {
    pub pending: usize,
    pub failed: usize,
    pub last_retry_error: Option<String>,
}

/// Posts annotations. Every record is saved locally first and removed only after the server stores it.
pub struct Submitter {
    pub store: PendingStore,
    counts: Mutex<Counts>,
    retrying: AtomicBool,
    on_change: Box<dyn Fn() + Send + Sync>,
}

impl Submitter {
    pub fn new(store: PendingStore, on_change: impl Fn() + Send + Sync + 'static) -> Submitter {
        let submitter = Submitter { store, counts: Mutex::default(), retrying: AtomicBool::new(false), on_change: Box::new(on_change) };
        submitter.count_files();
        submitter
    }

    pub fn counts(&self) -> Counts {
        self.counts.lock().unwrap().clone()
    }

    pub async fn submit(&self, id: &str, body: Vec<u8>, client: Option<AnnotationClient>) -> PostResult {
        if let Err(error) = self.store.save(id, &body) {
            // Without a local copy a failed POST would lose the comment. Say so, but still try to send.
            self.counts.lock().unwrap().last_retry_error = Some(format!("Could not save a local copy: {error}"));
        }
        let Some(client) = client else {
            self.count_files();
            return PostResult::Unreachable("The server URL in Settings is not valid".into());
        };
        let result = client.post(body).await;
        self.settle(id, &result);
        result
    }

    /// Sends every pending record again, oldest first. Stops at the first retryable failure.
    pub async fn retry_pending(&self, client: Option<AnnotationClient>) {
        let Some(client) = client else { return };
        if self.retrying.swap(true, Ordering::SeqCst) {
            return;
        }
        for (id, body) in self.store.pending() {
            let result = client.post(body).await;
            self.settle(&id, &result);
            if result.is_retryable() {
                self.counts.lock().unwrap().last_retry_error = Some(result.message());
                break;
            }
        }
        self.retrying.store(false, Ordering::SeqCst);
        self.count_files();
    }

    fn settle(&self, id: &str, result: &PostResult) {
        if result.is_stored() {
            self.store.remove(id);
            self.counts.lock().unwrap().last_retry_error = None;
        } else if !result.is_retryable() {
            let _ = self.store.mark_failed(id);
        }
        self.count_files();
    }

    fn count_files(&self) {
        {
            let mut counts = self.counts.lock().unwrap();
            counts.pending = self.store.pending().len();
            counts.failed = self.store.failed_count();
        }
        (self.on_change)();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{serve, temp_dir, Reply};

    fn store() -> PendingStore {
        PendingStore { root: temp_dir("annotator-tests") }
    }

    #[test]
    fn save_list_remove() {
        let store = store();
        store.save("a", b"1").unwrap();
        store.save("b", b"2").unwrap();
        let mut ids: Vec<String> = store.pending().into_iter().map(|(id, _)| id).collect();
        ids.sort();
        assert_eq!(ids, ["a", "b"]);
        store.remove("a");
        assert_eq!(store.pending().into_iter().map(|(id, _)| id).collect::<Vec<_>>(), ["b"]);
    }

    #[test]
    fn failed_records_leave_the_retry_queue() {
        let store = store();
        store.save("a", b"1").unwrap();
        store.mark_failed("a").unwrap();
        assert!(store.pending().is_empty());
        assert_eq!(store.failed_count(), 1);
    }

    #[tokio::test]
    async fn submit_keeps_a_copy_until_stored() {
        let submitter = Submitter::new(store(), || {});
        let down = AnnotationClient::new(crate::testutil::closed_url("/annotations"));
        let result = submitter.submit("a", b"{}".to_vec(), Some(down)).await;
        assert!(result.is_retryable());
        assert_eq!(submitter.counts().pending, 1);

        // Retry stops at the first retryable failure and reports it.
        let server = serve(vec![Reply::new(500, r#"{"error":"busy"}"#), Reply::new(201, "{}")]);
        let client = AnnotationClient::new(server.url("/annotations"));
        submitter.retry_pending(Some(client.clone())).await;
        let counts = submitter.counts();
        assert_eq!(counts.pending, 1);
        assert_eq!(counts.last_retry_error.as_deref(), Some("Server error (500): busy. Saved locally; it will retry."));
        submitter.retry_pending(Some(client)).await;
        assert_eq!(submitter.counts(), Counts { pending: 0, failed: 0, last_retry_error: None });
    }

    #[tokio::test]
    async fn refused_records_move_to_failed() {
        let submitter = Submitter::new(store(), || {});
        let server = serve(vec![Reply::new(422, r#"{"error":"bad"}"#)]);
        let result = submitter.submit("a", b"{}".to_vec(), Some(AnnotationClient::new(server.url("/annotations")))).await;
        assert_eq!(result, PostResult::Rejected(422, "bad".into()));
        assert_eq!((submitter.counts().pending, submitter.counts().failed), (0, 1));
    }

    #[tokio::test]
    async fn no_client_keeps_the_copy() {
        let submitter = Submitter::new(store(), || {});
        let result = submitter.submit("a", b"{}".to_vec(), None).await;
        assert_eq!(result, PostResult::Unreachable("The server URL in Settings is not valid".into()));
        assert_eq!(submitter.counts().pending, 1);
    }
}
