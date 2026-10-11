import Foundation

/// Hosts this helper treats as this machine.
public enum ServiceURL {
    public static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
