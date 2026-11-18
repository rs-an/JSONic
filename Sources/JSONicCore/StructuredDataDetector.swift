import Foundation
import Darwin

// Document checksums adapted to Swift from Red Madrobot pii-guard (Apache-2.0).
// Copyright 2026 Red Madrobot. Modified 2026-11-12: Swift port, context gating,
// rejection of repeated-digit placeholders, independent flags and stable identities.
// Email pattern adapted from Microsoft Presidio (MIT), Copyright Microsoft Corporation.
// See ThirdParty/SOURCES.md and the licenses bundled with the app.
struct StructuredHit {
    let range: NSRange
    let kind: MaskKind
    let reason: String
}

struct StructuredDataDetector {
    private struct Rule {
        let kind: MaskKind
        let regex: NSRegularExpression
        let groups: [Int]
        let reason: String
        init(_ kind: MaskKind, _ pattern: String, groups: [Int] = [1], _ reason: String) {
            self.kind = kind; regex = try! NSRegularExpression(pattern: pattern)
            self.groups = groups; self.reason = reason
        }
    }
    private static let fields: [MaskKind: Set<String>] = [
        .email: ["email", "emailaddress", "mail", "электроннаяпочта", "почта"],
        .telegram: ["telegram", "telegramusername", "telegramhandle", "telegramid", "tgusername", "телеграм"],
        .login: ["login", "username", "userlogin", "accountlogin", "логин", "имяпользователя"],
        .inn: ["inn", "taxpayerid", "taxpayernumber", "инн"],
        .snils: ["snils", "снилс"],
        .passport: ["passport", "passportnumber", "passportseries", "паспорт", "номерпаспорта", "серияпаспорта"],
        .address: ["address", "streetaddress", "postaladdress", "residentialaddress", "registrationaddress", "deliveryaddress", "homeaddress", "адрес", "адресрегистрации", "адресдоставки", "адреспроживания"],
        .ip: ["ip", "ipaddress", "clientip", "remoteaddr", "remoteaddress", "sourceip", "destinationip", "xforwardedfor", "xrealip"],
        .secret: ["password", "passwd", "pwd", "passphrase", "secret", "clientsecret", "token", "accesstoken", "refreshtoken", "idtoken", "authtoken", "apikey", "xapikey", "authorization", "proxyauthorization", "cookie", "setcookie", "пароль", "токен", "ключapi"]
    ]
    static func fieldKind(_ field: String) -> MaskKind? {
        let key = PersonalDataDetector.key(field)
        return MaskKind.additional.first { fields[$0]?.contains(key) == true }
    }
    private static let rules: [Rule] = [
        Rule(.secret, #"(?i)(?<![\p{L}\p{N}_])(?:cookie|set-cookie)[ \t]*:[ \t]*([^"\r\n]+)"#, "Заголовок Cookie"),
        // The quoted alternatives also work in malformed JSON and preserve escaped quotes.
        Rule(.secret, #"(?i)(?<![\p{L}\p{N}_])(?:password|passwd|pwd|passphrase|client[_-]?secret|secret|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|token|api[_-]?key|x-api-key|cookie|set-cookie|пароль|токен)["']?[ \t]*[:=][ \t]*(?:"((?:\\.|[^"\\])+)"|'((?:\\.|[^'\\])+)'|([^\s,;"'&}\]]+))"#, groups: [1,2,3], "Явное поле секрета"),
        Rule(.secret, #"(?i)(?<![\p{L}\p{N}_])(?:proxy-)?authorization["']?[ \t]*[:=][ \t]*["']?(?:(?:Bearer|Basic)[ \t]+)?([^\s,"';}\]]+)"#, "Авторизация"),
        Rule(.inn, #"(?i)(?<![\p{L}\p{N}_])(?:инн|inn|taxpayer[_-]?id)["']?[ \t]*(?:[:=№][ \t]*)?["']?([0-9]{12}|[0-9]{10})(?![\p{L}\p{N}_])"#, "ИНН по контексту"),
        Rule(.snils, #"(?i)(?<![\p{L}\p{N}_])(?:снилс|snils)["']?[ \t]*(?:[:=№][ \t]*)?["']?([0-9]{3}[ -]?[0-9]{3}[ -]?[0-9]{3}[ -]?[0-9]{2})(?![\p{L}\p{N}_])"#, "СНИЛС по контексту"),
        Rule(.snils, #"(?<![\p{L}\p{N}_])([0-9]{3}-[0-9]{3}-[0-9]{3}[ ][0-9]{2})(?![\p{L}\p{N}_])"#, "Формат и контрольное число СНИЛС"),
        Rule(.passport, #"(?i)(?<![\p{L}\p{N}_])(?:паспорт(?:а|ом|у|е)?|passport)(?:[ \t]+РФ)?["']?[ \t]*(?:[:=№][ \t]*)?["']?(?:серия[ \t]*)?([0-9]{2}[ \t]?[0-9]{2})[ \t]*(?:[,;]?[ \t]*(?:номер|№)[ \t]*)?([0-9]{6})(?![\p{L}\p{N}_])"#, groups: [0], "Паспорт РФ по контексту"),
        Rule(.email, #"(?i)(?<![\p{L}\p{N}_])(?:email|e-mail|email_address|почта)["']?[ \t]*[:=][ \t]*["']?([^\s"'<>;,={}]+@[^\s"'<>;,={}]+)"#, "Email по контексту"),
        Rule(.login, #"(?i)(?<![\p{L}\p{N}_])(?:login|username|user[_-]?login|логин)["']?[ \t]*[:=][ \t]*(?:"((?:\\.|[^"\\])+)"|'((?:\\.|[^'\\])+)'|([^\s,;"'&)}\]]+))"#, groups: [1,2,3], "Логин по контексту"),
        // Adapted from Presidio EmailRecognizer: Unicode / IDN domains, plus-addressing.
        Rule(.email, #"(?<![\p{L}\p{N}_.+%/=-])([!#$%&'*+\-/=?^_`{|}~\w]+(?:\.[!#$%&'*+\-/=?^_`{|}~\w]+)*@\w+(?:-+\w+)*(?:\.\w+(?:-+\w+)*)+)(?![\p{L}\p{N}_-])"#, "Email в тексте"),
        Rule(.telegram, #"(?i)(?<![\p{L}\p{N}_@./])((?:https?://)?(?:t\.me|telegram\.me)/(?:\+?[A-Za-z0-9_]+)(?:/[A-Za-z0-9_+-]+)*(?:\?[^\s<>"'\]})]+)?)(?![\p{L}\p{N}_])"#, "Ссылка Telegram"),
        Rule(.telegram, #"(?i)(?<![\p{L}\p{N}_])(?:telegram|телеграм(?:е|м)?|tg)["']?(?:[ \t]*[:=][ \t]*|[ \t]+)["']?(@[A-Za-z][A-Za-z0-9_]{3,31})(?![\p{L}\p{N}_])"#, "Telegram по контексту"),
        Rule(.address, #"(?i)(?<![\p{L}\p{N}_])((?:(?:г\.|город)[ \t]+[\p{L}-]+[ \t]*,[ \t]*)?(?:ул\.|улица|проспект|пр-т|переулок|пер\.)[ \t]+[\p{L}0-9][\p{L}0-9 .-]{0,80}?,?[ \t]+(?:д\.|дом)[ \t]*[0-9]{1,4}[а-яa-z]?(?:/[0-9]{1,4})?(?:[ \t]*,[ \t]*(?:корп\.|корпус|стр\.|строение)[ \t]*[0-9]{1,4}[а-яa-z]?)?(?:[ \t]*,[ \t]*(?:кв\.|квартира)[ \t]*[0-9]{1,4})?)(?![\p{L}\p{N}_])"#, "Улица и номер дома"),
        Rule(.ip, #"(?<![\p{L}\p{N}_.])([0-9]{1,3}(?:\.[0-9]{1,3}){3})(?![\p{L}\p{N}_]|\.[\p{L}\p{N}_])"#, "IPv4"),
        Rule(.ip, #"(?<![\p{L}\p{N}_:])([0-9A-Fa-f]*:[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*)(?![\p{L}\p{N}_:])"#, "IPv6")
    ]
    static func matches(_ input: String, enabled: Set<MaskKind>, token: Cancellation) throws -> [StructuredHit] {
        let ns = input as NSString, range = NSRange(location: 0, length: (input as NSString).length)
        var result: [StructuredHit] = []
        for rule in rules where enabled.contains(rule.kind) {
            // Cheap gates avoid regex work for the many short JSON scalar values.
            if rule.kind == .email && !input.contains("@") { continue }
            if rule.kind == .ip && !input.contains(".") && !input.contains(":") { continue }
            if [.inn, .snils, .passport, .address].contains(rule.kind) && !input.contains(where: { $0.isASCII && $0.isNumber }) { continue }
            for match in try cancellableMatches(rule.regex, in: input, range: range, token: token) {
                try token.check()
                if rule.kind == .passport {
                    // Preserve the words "серия" / "номер"; only contiguous digits are a single span.
                    let a = match.range(at: 1), b = match.range(at: 2)
                    let gap = ns.substring(with: NSRange(location: NSMaxRange(a), length: b.location - NSMaxRange(a)))
                    if gap.allSatisfy({ $0.isWhitespace }) {
                        result.append(StructuredHit(range: NSUnionRange(a,b), kind: .passport, reason: rule.reason))
                    } else {
                        result.append(StructuredHit(range: a, kind: .passport, reason: rule.reason + ": серия"))
                        result.append(StructuredHit(range: b, kind: .passport, reason: rule.reason + ": номер"))
                    }
                    continue
                }
                guard var capture = rule.groups.map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound && $0.length > 0 }) else { continue }
                if rule.kind == .email || rule.kind == .ip {
                    while capture.length > 0 && ns.substring(with: capture).hasSuffix(".") { capture.length -= 1 }
                }
                let value = ns.substring(with: capture)
                if rule.kind == .email && !isEmailDomain(value) { continue }
                // Quoted usernames are literal values; unquoted null/nil are log sentinels.
                if rule.kind == .login && match.range(at: 3).location != NSNotFound && isAbsentLogin(value) { continue }
                var reason = rule.reason
                if rule.kind == .snils {
                    let valid = validSNILS(value)
                    if rule.reason.hasPrefix("Формат") && !valid { continue }
                    reason += valid ? " · контрольное число верно" : " · контрольное число не совпало"
                }
                if rule.kind == .inn { reason += validINN(value) ? " · контрольное число верно" : " · контрольное число не совпало" }
                if rule.kind == .ip && canonicalIP(value) == nil { continue }
                result.append(StructuredHit(range: capture, kind: rule.kind, reason: reason))
            }
        }
        return result
    }
    private static func isEmailDomain(_ value: String) -> Bool {
        guard let at = value.lastIndex(of: "@") else { return false }
        let domain = String(value[value.index(after: at)...])
        guard canonicalIP(domain) == nil, let tld = domain.split(separator: ".").last else { return false }
        // Do not infer email from technical actor/session IDs such as id@192.0.2.10.
        // Keep Unicode and punycode TLDs without a network-maintained suffix list.
        return (tld.count >= 2 && tld.allSatisfy(\.isLetter)) ||
            (tld.lowercased().hasPrefix("xn--") && tld.count > 4)
    }
    static func isAbsentLogin(_ value: String) -> Bool {
        ["", "null", "nil", "undefined", "none", "<null>", "(null)"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }
    static func digits(_ value: String) -> String { value.filter { $0.isASCII && $0.isNumber } }
    static func validINN(_ value: String) -> Bool {
        let d = digits(value).compactMap(\.wholeNumberValue)
        guard (d.count == 10 || d.count == 12), Set(d).count > 1 else { return false }
        func checksum(_ weights: [Int]) -> Int { zip(d, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10 }
        if d.count == 10 { return checksum([2,4,10,3,5,9,4,6,8]) == d[9] }
        return checksum([7,2,4,10,3,5,9,4,6,8]) == d[10] && checksum([3,7,2,4,10,3,5,9,4,6,8]) == d[11]
    }
    static func validSNILS(_ value: String) -> Bool {
        let d = digits(value).compactMap(\.wholeNumberValue)
        guard d.count == 11, Set(d).count > 1 else { return false }
        let sum = (0..<9).reduce(0) { $0 + d[$1] * (9 - $1) }
        let remainder = sum % 101
        return (remainder == 100 ? 0 : remainder) == d[9] * 10 + d[10]
    }
    static func canonicalIP(_ value: String) -> String? {
        for family in [AF_INET, AF_INET6] {
            var bytes = [UInt8](repeating: 0, count: 16)
            let valid = value.withCString { p in bytes.withUnsafeMutableBytes { inet_pton(family, p, $0.baseAddress) } }
            if valid == 1 {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                return bytes.withUnsafeBytes { raw in
                    guard inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil else { return nil }
                    return String(cString: buffer)
                }
            }
        }
        return nil
    }
    static func canonical(_ value: String, kind: MaskKind) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .secret, .login: return value // Case-sensitive credentials must never collapse.
        case .inn, .snils, .passport:
            let d = digits(value)
            return !d.isEmpty && trimmed.allSatisfy({ $0.isWhitespace || $0 == "-" || ($0.isASCII && $0.isNumber) }) ? d : trimmed
        case .ip: return canonicalIP(trimmed) ?? trimmed
        case .email:
            guard let at = trimmed.lastIndex(of: "@") else { return trimmed }
            return String(trimmed[...at]) + trimmed[trimmed.index(after: at)...].lowercased()
        case .telegram:
            let lower = trimmed.lowercased()
            for prefix in ["https://t.me/", "http://t.me/", "t.me/", "https://telegram.me/", "http://telegram.me/", "telegram.me/"] where lower.hasPrefix(prefix) {
                let handle = String(trimmed.dropFirst(prefix.count))
                if handle.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) { return handle.lowercased() }
                return trimmed // Invite tokens / query parameters may be case sensitive.
            }
            return (trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed).lowercased()
        default: return trimmed.lowercased()
        }
    }
}
