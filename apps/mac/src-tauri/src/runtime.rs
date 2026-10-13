//! Private, inherited pipes connect the SwiftUI host to this UI-free process.
use serde::Serialize;
use std::{
    any::{Any, TypeId},
    collections::HashMap,
    io::Write,
    sync::{Arc, Mutex, OnceLock},
};
static RUNTIME: OnceLock<tokio::runtime::Handle> = OnceLock::new();
pub fn initialize() {
    let _ = RUNTIME.set(tokio::runtime::Handle::current());
}
pub fn spawn<F: std::future::Future + Send + 'static>(
    future: F,
) -> tokio::task::JoinHandle<F::Output>
where
    F::Output: Send + 'static,
{
    RUNTIME.get().expect("runtime initialized").spawn(future)
}
pub fn write(value: &impl Serialize) {
    let mut out = std::io::stdout().lock();
    if let Ok(bytes) = serde_json::to_vec(value) {
        let _ = out.write_all(&bytes);
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }
}
#[derive(Clone, Default)]
pub struct AppHandle(Arc<Mutex<HashMap<TypeId, Arc<dyn Any + Send + Sync>>>>);
impl AppHandle {
    pub fn manage<T: Any + Send + Sync>(&self, value: T) {
        self.0
            .lock()
            .unwrap()
            .insert(TypeId::of::<T>(), Arc::new(value));
    }
    pub fn try_state<T: Any + Send + Sync>(&self) -> Option<Arc<T>> {
        self.0
            .lock()
            .unwrap()
            .get(&TypeId::of::<T>())
            .cloned()?
            .downcast()
            .ok()
    }
    pub fn state<T: Any + Send + Sync>(&self) -> Arc<T> {
        self.try_state().expect("managed state")
    }
    pub fn emit(&self, event: &str, payload: impl Serialize) -> Result<(), String> {
        write(&serde_json::json!({"event": event, "payload": payload}));
        Ok(())
    }
    pub fn emit_to(
        &self,
        _target: &str,
        event: &str,
        payload: impl Serialize,
    ) -> Result<(), String> {
        self.emit(event, payload)
    }
    pub fn exit(&self, _code: i32) {
        let _ = self.emit("quit", ());
    }
}
