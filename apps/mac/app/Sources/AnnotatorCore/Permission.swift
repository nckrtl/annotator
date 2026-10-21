/// Permission keys shared with the native capture helper's state and request commands.
public enum Permission: String, CaseIterable, Sendable {
    case accessibility
    case screenRecording

    public var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    public static func missing(in state: JSON) -> [Permission] {
        allCases.filter { !state[$0.rawValue].bool }
    }
}
