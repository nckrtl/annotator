//! HTTP(S) endpoints this app will call (ServiceURL.swift). Cleartext is only allowed on this machine.

use url::{Host, Url};

/// An http(s) URL with a host and no userinfo, query, or fragment.
/// `http` is accepted only for `localhost`, `127.0.0.1`, and `::1`.
pub fn parse(text: &str) -> Option<Url> {
    let url = Url::parse(text.trim()).ok()?;
    let host = url.host()?;
    let plain = matches!(url.scheme(), "http" | "https")
        && !matches!(host, Host::Domain(""))
        && url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none();
    if !plain || (url.scheme() == "http" && !is_loopback(&host)) {
        return None;
    }
    Some(url)
}

/// `parse`, and the host must be this machine. Ofide's token never leaves the Mac.
pub fn loopback(text: &str) -> Option<Url> {
    parse(text).filter(|url| url.host().is_some_and(|host| is_loopback(&host)))
}

pub fn is_loopback(host: &Host<&str>) -> bool {
    match host {
        Host::Domain(name) => name.eq_ignore_ascii_case("localhost"),
        Host::Ipv4(address) => *address == std::net::Ipv4Addr::LOCALHOST,
        Host::Ipv6(address) => *address == std::net::Ipv6Addr::LOCALHOST,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn host(url: Option<Url>) -> Option<String> {
        url.and_then(|url| url.host_str().map(String::from))
    }

    #[test]
    fn rejects_userinfo_and_cleartext_off_box() {
        assert!(parse("http://127.0.0.1:29703@attacker.example/annotations").is_none());
        assert!(parse("http://example.com/annotations").is_none());
        assert!(parse("http://127.0.0.1:29703/annotations?x=1").is_none());
        assert!(parse("http://127.0.0.1:29703/annotations?").is_none());
        assert!(parse("http://127.0.0.1:29703/annotations#frag").is_none());
        assert_eq!(host(parse("http://127.0.0.1:29703/annotations")).as_deref(), Some("127.0.0.1"));
        assert_eq!(host(parse(" https://example.com/annotations ")).as_deref(), Some("example.com"));
        assert!(parse("http://localhost:29703/annotations").is_some());
        assert!(parse("ftp://127.0.0.1/annotations").is_none());
        assert!(parse("annotations").is_none());
        assert!(parse("").is_none());
        assert!(loopback("https://example.com/annotations").is_none());
        assert_eq!(host(loopback("http://[::1]:12321")).as_deref(), Some("[::1]"));
        assert!(loopback("https://127.0.0.1:12321").is_some());
    }
}
