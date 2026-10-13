//! A scripted local HTTP server for tests: one reply per connection, in order.

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone)]
pub struct Reply {
    pub status: u16,
    pub body: String,
    pub delay: Duration,
    pub headers: Vec<(String, String)>,
}

impl Reply {
    pub fn new(status: u16, body: &str) -> Reply {
        Reply { status, body: body.into(), delay: Duration::ZERO, headers: Vec::new() }
    }

    pub fn header(mut self, name: &str, value: &str) -> Reply {
        self.headers.push((name.into(), value.into()));
        self
    }

    pub fn delayed(mut self, ms: u64) -> Reply {
        self.delay = Duration::from_millis(ms);
        self
    }
}

#[derive(Clone, Debug)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
    }
}

pub struct Server {
    pub port: u16,
    pub requests: Arc<Mutex<Vec<Request>>>,
}

impl Server {
    pub fn url(&self, path: &str) -> url::Url {
        url::Url::parse(&format!("http://127.0.0.1:{}{path}", self.port)).unwrap()
    }

    pub fn request(&self, index: usize) -> Request {
        self.requests.lock().unwrap()[index].clone()
    }

    pub fn paths(&self) -> Vec<String> {
        self.requests.lock().unwrap().iter().map(|r| r.path.clone()).collect()
    }
}

/// Serves `replies` one per connection; later connections get the last reply again.
pub fn serve(replies: Vec<Reply>) -> Server {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let recorded = requests.clone();
    std::thread::spawn(move || {
        let mut index = 0;
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let reply = replies.get(index).or(replies.last()).cloned().unwrap_or(Reply::new(200, ""));
            index += 1;
            let recorded = recorded.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    return;
                }
                let mut parts = line.split_whitespace();
                let method = parts.next().unwrap_or_default().to_string();
                let path = parts.next().unwrap_or_default().to_string();
                let mut headers = Vec::new();
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).is_err() || header.trim().is_empty() {
                        break;
                    }
                    if let Some((key, value)) = header.trim().split_once(':') {
                        headers.push((key.trim().to_string(), value.trim().to_string()));
                    }
                }
                let length = headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
                    .and_then(|(_, v)| v.parse::<usize>().ok()).unwrap_or(0);
                let mut body = vec![0; length];
                let _ = reader.read_exact(&mut body);
                recorded.lock().unwrap().push(Request { method, path, headers, body });
                std::thread::sleep(reply.delay);
                let extra: String = reply.headers.iter().map(|(k, v)| format!("{k}: {v}\r\n")).collect();
                let response = format!(
                    "HTTP/1.1 {} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\n{extra}Connection: close\r\n\r\n{}",
                    reply.status, reply.body.len(), reply.body);
                let _ = stream.write_all(response.as_bytes());
            });
        }
    });
    Server { port, requests }
}

/// A URL on a port nothing listens on.
pub fn closed_url(path: &str) -> url::Url {
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    url::Url::parse(&format!("http://127.0.0.1:{port}{path}")).unwrap()
}

pub fn temp_dir(name: &str) -> std::path::PathBuf {
    std::env::temp_dir().join(format!("{name}-{}", uuid::Uuid::new_v4()))
}
