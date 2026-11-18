import Foundation

struct PersonMatch {
    let range: NSRange
    let canonical: String?
    let reason: String
}

// Conservative, offline field/context and patronymic rules.
// No model download or network requests. A detection is a suggestion, not a guarantee.
final class PersonalDataDetector {
    static let phone = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?:\+?7|8)[\s().-]*[3489]\d{2}[\s().-]*\d{3}[\s.-]*\d{2}[\s.-]*\d{2}(?![\p{L}\p{N}_])"#)
    static let phoneKeys: Set<String> = ["phone", "phonenumber", "mobilephone", "mobile", "telephone", "msisdn", "abonentnumber", "subscriberphone", "телефон", "номертелефона"]
    static let personKeys: Set<String> = ["fio", "fullname", "firstname", "lastname", "middlename", "surname", "givenname", "familyname", "patronymic", "customername", "clientname", "subscribername", "имя", "фамилия", "отчество", "фио"]
    static func key(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func isPhone(_ value: String) -> Bool {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return phone.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))?.range == NSRange(value.startIndex..., in: value)
    }
    private static let forms: [String: String] = {
        let names = "Александр Алексей Анатолий Андрей Антон Аркадий Артем Артур Борис Вадим Валентин Валерий Василий Виктор Виталий Владимир Владислав Вячеслав Геннадий Георгий Глеб Григорий Даниил Денис Дмитрий Евгений Егор Иван Игорь Илья Кирилл Константин Леонид Максим Михаил Никита Николай Олег Павел Петр Роман Руслан Сергей Станислав Степан Тимофей Федор Юрий Ярослав Алина Алла Анастасия Ангелина Анна Антонина Валентина Валерия Варвара Василиса Вера Вероника Виктория Галина Дарья Диана Евгения Екатерина Елена Елизавета Зоя Инна Ирина Карина Кристина Ксения Лариса Лидия Любовь Людмила Маргарита Марина Мария Надежда Наталия Наталья Нина Оксана Олеся Ольга Полина Раиса Светлана София Софья Тамара Татьяна Ульяна Юлия Яна Жанна Эльвира Элеонора Эмилия Ренат Ринат Рустам Тимур Марат Айгуль Алсу Лилия"
        var result: [String: String] = [:]
        for original in names.split(separator: " ") {
            let name = original.lowercased()
            var variants = [name]
            if name.hasSuffix("ия") { variants += ["ии", "ию", "ией"].map { String(name.dropLast(2)) + $0 } }
            else if name.hasSuffix("а") { variants += ["ы", "и", "е", "у", "ой", "ою"].map { String(name.dropLast()) + $0 } }
            else if name.hasSuffix("я") { variants += ["и", "е", "ю", "ей"].map { String(name.dropLast()) + $0 } }
            else if name.hasSuffix("й") || name.hasSuffix("ь") { variants += ["я", "ю", "ем", "е"].map { String(name.dropLast()) + $0 } }
            else if let last = name.last, !"аеёиоуыэюя".contains(last) { variants += ["а", "у", "ом", "е"].map { name + $0 } }
            for variant in variants { result[variant] = name }
        }
        for (canonical, variants) in ["павел": "павла павлу павлом павле", "петр": "петра петру петром петре", "любовь": "любови любовью"] {
            for variant in variants.split(separator: " ") { result[String(variant)] = canonical }
        }
        return result
    }()
    private static let words = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])[А-Яа-яЁё]+(?:-[А-Яа-яЁё]+)?(?![\p{L}\p{N}_])"#)
    private static let context = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])(?i:меня\s+зовут|мо[её]\s+имя|фио|имя\s+клиента|имя\s+абонента)\s*[:=—-]?\s*([А-ЯЁ][а-яё-]+(?:[ \t]+[А-ЯЁ][а-яё-]+){0,2})"#)
    private static let capital = try! NSRegularExpression(pattern: #"^[А-ЯЁ][а-яё]+(?:-[А-ЯЁ][а-яё]+)?$"#)
    private static let patronymic = try! NSRegularExpression(pattern: #"(?i)(?:ович|евич)(?:а|у|ем|е)?$|(?:овн|евн|ичн)(?:а|ы|е|у|ой|ою)$"#)
    private static let shortPatronymic = try! NSRegularExpression(pattern: #"(?i)ич(?:а|у|ем|е)?$"#)
    func people(_ input: String, token: Cancellation) throws -> [PersonMatch] {
        let ns = input as NSString, whole = NSRange(location: 0, length: (input as NSString).length)
        var found = try cancellableMatches(Self.context, in: input, range: whole, token: token).map {
            PersonMatch(range: $0.range(at: 1), canonical: nil, reason: "Имя по контексту")
        }
        let words = try cancellableMatches(Self.words, in: input, range: whole, token: token)
        if words.count >= 3 {
            for i in 0...(words.count - 3) {
                try token.check()
                let ranges = (i...i+2).map { words[$0].range }
                let values = ranges.map { ns.substring(with: $0) }
                guard values.allSatisfy({ Self.capital.firstMatch(in: $0, range: NSRange(location: 0, length: ($0 as NSString).length)) != nil }) else { continue }
                guard (0..<2).allSatisfy({ j in
                    let gap = ns.substring(with: NSRange(location: NSMaxRange(ranges[j]), length: ranges[j+1].location - NSMaxRange(ranges[j])))
                    return !gap.isEmpty && gap.allSatisfy { $0 == " " || $0 == "\t" }
                }) else { continue }
                let valid = [1, 2].contains { j in
                    let value = values[j], r = NSRange(location: 0, length: (value as NSString).length)
                    if Self.patronymic.firstMatch(in: value, range: r) != nil { return true }
                    let name = values[j-1].lowercased().replacingOccurrences(of: "ё", with: "е")
                    return Self.shortPatronymic.firstMatch(in: value, range: r) != nil && Self.forms[name] != nil
                }
                if valid { found.append(PersonMatch(range: NSUnionRange(ranges[0], ranges[2]), canonical: nil, reason: "ФИО с отчеством")) }
            }
        }
        // Stable, linear overlap removal after sorting: context wins at equal location.
        var accepted: [PersonMatch] = [], end = 0
        for item in found.sorted(by: { $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location }) {
            if item.range.location >= end { accepted.append(item); end = NSMaxRange(item.range) }
        }
        return accepted.reversed()
    }
}

// ICU reports progress even before a match; cancellation can stop a long text scan.
func cancellableMatches(_ regex: NSRegularExpression, in text: String, range: NSRange, token: Cancellation) throws -> [NSTextCheckingResult] {
    try token.check()
    var result: [NSTextCheckingResult] = []
    regex.enumerateMatches(in: text, options: [.reportProgress], range: range) { match, _, stop in
        if token.isCancelled { stop.pointee = true; return }
        if let match { result.append(match) }
    }
    try token.check()
    return result
}
