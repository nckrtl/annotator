import Foundation

public enum JSON: Codable, Sendable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([JSON]), object([String: JSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> JSON {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v: [String: JSON]; if case .object(let o) = self { v = o } else { v = [:] }; v[key] = newValue; self = .object(v) }
    }
    public var string: String { if case .string(let v) = self { v } else { "" } }
    public var bool: Bool { if case .bool(let v) = self { v } else { false } }
    public var int: Int { if case .number(let v) = self { Int(v) } else { 0 } }
    public var double: Double { if case .number(let v) = self { v } else { 0 } }
    public var array: [JSON] { if case .array(let v) = self { v } else { [] } }
    public static func decode(_ data: Data) throws -> JSON { try JSONDecoder().decode(JSON.self, from: data) }
}

public struct BridgeError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Frames arbitrary pipe chunks, including split Unicode and multiple replies in one read.
public struct Lines: Sendable {
    private var data = Data()
    public init() {}
    public mutating func append(_ chunk: Data) throws -> [JSON] {
        data.append(chunk)
        guard data.count <= 16 * 1024 * 1024 else { throw BridgeError("The core sent an oversized response.") }
        var result: [JSON] = []
        while let end = data.firstIndex(of: 10) {
            let line = data[..<end]; data.removeSubrange(...end)
            if !line.isEmpty { result.append(try JSON.decode(Data(line))) }
        }
        return result
    }
}
