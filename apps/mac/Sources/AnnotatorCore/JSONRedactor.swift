import Foundation

/// Drops large string fields from a JSON document without decoding those strings.
public enum JSONRedactor {
    /// Replaces string values of `keys` with JSON `null`. A matching key whose value is not a string is left as it is.
    public static func nullifyStrings(named keys: Set<String>, in data: Data) -> Data {
        var output = Data()
        output.reserveCapacity(min(data.count, 256 * 1024))
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var index = 0
            var mark = 0
            func flush(until end: Int) {
                if end > mark { output.append(data[mark..<end]) }
                mark = end
            }
            while index < count {
                guard base[index] == quote else {
                    index += 1
                    continue
                }
                guard let (literal, next) = string(base, count, from: index),
                    let key = String(data: literal, encoding: .utf8)
                else {
                    index += 1
                    continue
                }
                var look = next
                while look < count, isSpace(base[look]) { look += 1 }
                guard keys.contains(key), look < count, base[look] == colon else {
                    index = next
                    continue
                }
                var value = look + 1
                while value < count, isSpace(base[value]) { value += 1 }
                guard value < count, base[value] == quote, let (_, after) = string(base, count, from: value) else {
                    index = next
                    continue
                }
                flush(until: index)
                output.append(contentsOf: Data("\"\(key)\":null".utf8))
                index = after
                mark = after
            }
            flush(until: count)
        }
        return output
    }

    private static let quote: UInt8 = 34
    private static let colon: UInt8 = 58

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    /// The raw bytes inside a JSON string that starts at `open`, and the index just after its closing quote.
    private static func string(_ base: UnsafePointer<UInt8>, _ count: Int, from open: Int) -> (Data, Int)? {
        guard open < count, base[open] == quote else { return nil }
        var index = open + 1
        var content = Data()
        var escaped = false
        while index < count {
            let byte = base[index]
            index += 1
            if escaped {
                escaped = false
                content.append(byte)
                continue
            }
            if byte == 92 {
                escaped = true
                content.append(byte)
                continue
            }
            if byte == quote { return (content, index) }
            content.append(byte)
        }
        return nil
    }
}
