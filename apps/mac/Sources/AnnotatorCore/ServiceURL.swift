import Foundation

/// HTTP(S) endpoints this app will call. Cleartext is only allowed on this machine.
public enum ServiceURL {
    /// An http(s) URL with no userinfo, query, or fragment.
    /// `http` is accepted only for `localhost`, `127.0.0.1`, and `::1`.
    public static func parse(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme, ["http", "https"].contains(scheme),
            let host = url.host()?.lowercased(), !host.isEmpty,
            url.user == nil, url.password == nil,
            url.query == nil, url.fragment == nil
        else { return nil }
        if scheme == "http", !isLoopback(host) { return nil }
        return url
    }

    /// `parse`, and the host must be this machine. Ofide's token never leaves the Mac.
    public static func loopback(_ text: String) -> URL? {
        guard let url = parse(text), let host = url.host()?.lowercased(), isLoopback(host) else { return nil }
        return url
    }

    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
