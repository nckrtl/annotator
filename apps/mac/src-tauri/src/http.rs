//! Shared HTTP clients (HTTP.swift). One per purpose, so connections are reused. Each refuses a
//! redirect to another scheme, host, or port, so a token or a screenshot cannot follow it off the
//! original server.

use reqwest::redirect::{Attempt, Policy};
use reqwest::Client;
use std::sync::LazyLock;
use std::time::Duration;

/// Annotation calls.
pub fn short() -> Client {
    static CLIENT: LazyLock<Client> = LazyLock::new(|| pinned(Client::builder().timeout(Duration::from_secs(15))));
    CLIENT.clone()
}

/// The annotation event stream. No total timeout: the stream stays open, and each read times out
/// instead (see `QueueMonitor::listen`).
pub fn event_stream() -> Client {
    static CLIENT: LazyLock<Client> = LazyLock::new(|| pinned(Client::builder().connect_timeout(Duration::from_secs(45))));
    CLIENT.clone()
}

fn pinned(builder: reqwest::ClientBuilder) -> Client {
    builder.redirect(Policy::custom(stay)).build().expect("HTTP client")
}

fn stay(attempt: Attempt) -> reqwest::redirect::Action {
    let same = attempt.previous().first().is_some_and(|from| same_origin(from, attempt.url()));
    if !same {
        attempt.stop()
    } else if attempt.previous().len() > 10 {
        attempt.error("too many redirects")
    } else {
        attempt.follow()
    }
}

/// Same scheme, host and port.
pub fn same_origin(from: &url::Url, to: &url::Url) -> bool {
    from.scheme().eq_ignore_ascii_case(to.scheme())
        && from.host_str().map(str::to_lowercase) == to.host_str().map(str::to_lowercase)
        && from.port_or_known_default() == to.port_or_known_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{serve, Reply};

    #[test]
    fn origins() {
        let url = |text: &str| url::Url::parse(text).unwrap();
        assert!(same_origin(&url("http://127.0.0.1:1/a"), &url("http://127.0.0.1:1/b")));
        assert!(!same_origin(&url("http://127.0.0.1:1/a"), &url("http://127.0.0.1:2/a")));
        assert!(!same_origin(&url("http://127.0.0.1:1/a"), &url("https://127.0.0.1:1/a")));
        assert!(!same_origin(&url("http://127.0.0.1:1/a"), &url("http://localhost:1/a")));
    }

    #[tokio::test]
    async fn redirect_to_another_port_is_not_followed() {
        let target = serve(vec![Reply::new(200, "secret")]);
        let location = target.url("/x");
        let server = serve(vec![Reply::new(302, "").header("Location", location.as_str())]);
        let response = short().get(server.url("/a")).send().await.unwrap();
        assert_eq!(response.status().as_u16(), 302);
        assert!(target.paths().is_empty());

        let same = serve(vec![Reply::new(302, "").header("Location", "/b"), Reply::new(200, "ok")]);
        let response = short().get(same.url("/a")).send().await.unwrap();
        assert_eq!(response.status().as_u16(), 200);
        assert_eq!(same.paths(), ["/a", "/b"]);
    }
}
