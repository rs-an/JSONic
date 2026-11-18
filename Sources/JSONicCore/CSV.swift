import Foundation

public struct ScopeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func check() throws { if isCancelled { throw CancellationError() } }
}
public enum CSVEncoding: String, CaseIterable, Codable {
    case utf8 = "UTF-8", cp1251 = "Windows-1251"
    public var encoding: String.Encoding { self == .utf8 ? .utf8 : .windowsCP1251 }
}
public struct CSVFormat: Codable, Equatable {
    public var delimiter: UInt8
    public var encoding: CSVEncoding
    public init(delimiter: UInt8 = 44, encoding: CSVEncoding = .utf8) { self.delimiter = delimiter; self.encoding = encoding }
    public static func detect(_ url: URL) throws -> CSVFormat {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        let data = try h.read(upToCount: 262144) ?? Data()
        // A sample can end inside a UTF-8 character.
        let utf = (0...min(3, data.count)).contains { String(data: data.dropLast($0), encoding: .utf8) != nil }
        let encoding: CSVEncoding = utf ? .utf8 : .cp1251
        var best: UInt8 = 44, score = -1
        for delimiter: UInt8 in [44, 59, 9] {
            let reader = try CSVReader(url: url, format: CSVFormat(delimiter: delimiter, encoding: encoding))
            if let record = try? reader.next(), let fields = try? parse(record.data, format: reader.format), fields.count > score {
                score = fields.count; best = delimiter
            }
        }
        return CSVFormat(delimiter: best, encoding: encoding)
    }
}
public struct CSVRecord {
    public let offset: UInt64
    public let data: Data
}
// Record boundaries are found in bytes: quoted newlines must not split a record.
public final class CSVReader {
    private let handle: FileHandle
    public let format: CSVFormat
    private var chunk = [UInt8]()
    private var index = 0
    private var position: UInt64 = 0
    private var eof = false
    public init(url: URL, format: CSVFormat) throws { handle = try FileHandle(forReadingFrom: url); self.format = format }
    deinit { try? handle.close() }
    public func next(_ cancellation: Cancellation? = nil) throws -> CSVRecord? {
        let start = position
        var result = Data(), state = 0 // 0 field start, 1 unquoted, 2 quoted, 3 after quote
        while true {
            try cancellation?.check()
            if index == chunk.count {
                if eof { return result.isEmpty ? nil : CSVRecord(offset: start, data: result) }
                chunk = Array(try handle.read(upToCount: 65536) ?? Data()); index = 0
                if chunk.isEmpty {
                    eof = true
                    if state == 2 { throw ScopeError("Незакрытая кавычка CSV, смещение \(start).") }
                    return result.isEmpty ? nil : CSVRecord(offset: start, data: result)
                }
            }
            let segment = index
            while index < chunk.count {
                let b = chunk[index]; index += 1; position += 1
                if position <= 3 && start == 0 && chunk.starts(with: [239,187,191]) { continue }
                if state == 2 {
                    if b == 34 { state = 3 }
                } else if state == 3 && b == 34 {
                    state = 2
                } else if b == 10 {
                    result.append(contentsOf: chunk[segment..<index])
                    return CSVRecord(offset: start, data: result)
                } else if b == format.delimiter { state = 0
                } else if state == 0 && b == 34 { state = 2
                } else if b != 13 { state = 1 }
            }
            result.append(contentsOf: chunk[segment..<index])
        }
    }
}
public func parse(_ data: Data, format: CSVFormat) throws -> [String] {
    var bytes = Array(data)
    if bytes.starts(with: [239,187,191]) { bytes.removeFirst(3) }
    if bytes.last == 10 { bytes.removeLast(); if bytes.last == 13 { bytes.removeLast() } }
    var fields = [String](), field = [UInt8](), state = 0
    func finish() throws {
        guard let value = String(bytes: field, encoding: format.encoding.encoding) else { throw ScopeError("Не удалось прочитать текст. Проверьте кодировку CSV.") }
        fields.append(value); field.removeAll(keepingCapacity: true)
    }
    for b in bytes {
        if state == 2 {
            if b == 34 { state = 3 } else { field.append(b) }
        } else if state == 3 {
            if b == 34 { field.append(34); state = 2 }
            else if b == format.delimiter { try finish(); state = 0 }
            else { throw ScopeError("Некорректный CSV: символ после закрывающей кавычки.") }
        } else if b == format.delimiter { try finish(); state = 0
        } else if b == 34 && state == 0 { state = 2
        } else { field.append(b); state = 1 }
    }
    if state == 2 { throw ScopeError("Незакрытая кавычка CSV.") }
    try finish(); return fields
}
public func csvLine(_ values: [String], delimiter: UInt8) -> Data {
    let sep = String(UnicodeScalar(delimiter))
    let line = values.map { value -> String in
        if value.contains(sep) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }.joined(separator: sep) + "\r\n"
    return Data(line.utf8)
}
