import Foundation

public struct JSONEnvelope {
    public let prefix: String
    public let value: Any
    public let suffix: String
}

// Log messages may surround a JSON document with timestamps and service names.
// Scan balanced containers once; braces inside quoted strings are not boundaries.
public func extractJSON(_ text: String, fragments: Bool = false, token: Cancellation? = nil) throws -> JSONEnvelope? {
    try token?.check()
    if !fragments && !text.contains("{") && !text.contains("[") { return nil }
    let data = Data(text.utf8)
    if let value = try? JSONSerialization.jsonObject(with: data, options: fragments ? [.fragmentsAllowed] : []) {
        return JSONEnvelope(prefix: "", value: value, suffix: "")
    }
    let bytes = Array(data)
    var i = 0
    while i < bytes.count {
        if i % 65536 == 0 { try token?.check() }
        guard bytes[i] == 123 || bytes[i] == 91 else { i += 1; continue }
        let start = i
        var stack = [UInt8](), quoted = false, escaped = false
        repeat {
            let b = bytes[i]
            if quoted {
                if escaped { escaped = false }
                else if b == 92 { escaped = true }
                else if b == 34 { quoted = false }
            } else if b == 34 { quoted = true
            } else if b == 123 || b == 91 { stack.append(b)
            } else if b == 125 || b == 93 {
                guard stack.last == (b == 125 ? 123 : 91) else { break }
                stack.removeLast()
            }
            i += 1
            if i % 65536 == 0 { try token?.check() }
        } while i < bytes.count && !stack.isEmpty
        if stack.isEmpty, let value = try? JSONSerialization.jsonObject(with: Data(bytes[start..<i])) {
            return JSONEnvelope(prefix: String(decoding: bytes[..<start], as: UTF8.self), value: value,
                                suffix: String(decoding: bytes[i...], as: UTF8.self))
        }
        // An invalid container is not silently replaced by one of its nested values.
        if i == start { i += 1 }
    }
    return nil
}


public enum JSONInspection {
    case text
    case json(JSONEnvelope)
    case invalid(String)
}

private let jsonCandidate = try! NSRegularExpression(pattern: #"\{|\[\s*(?:[\[\{\"\]]|true\b|false\b|null\b|-?\d+(?:\s*[,\]]|\s*$))"#)

/// A log prefix such as [INFO], [service] or [2026-11-12 ...] is plain text.
public func inspectJSON(_ text: String, token: Cancellation? = nil) throws -> JSONInspection {
    if let envelope = try extractJSON(text, token: token) { return .json(envelope) }
    try token?.check()
    let ns = text as NSString
    guard let candidate = jsonCandidate.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return .text }
    let payload = ns.substring(from: candidate.range.location)
    do { _ = try JSONSerialization.jsonObject(with: Data(payload.utf8)); return .text }
    catch {
        let error = error as NSError
        // Foundation's debug description describes syntax/position without echoing the payload.
        return .invalid((error.userInfo[NSDebugDescriptionErrorKey] as? String) ?? "Нарушен синтаксис или значение обрезано")
    }
}
