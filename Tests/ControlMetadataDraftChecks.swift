import Foundation

@main struct ControlMetadataDraftChecks {
    static var checks = 0
    static func expect(_ result: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try result() else { throw CheckFailure(label: label) }
        checks += 1
    }
    static func reject(_ draft: ControlMetadataDraft, _ expected: MetadataDraftError, _ label: String) throws {
        do { _ = try draft.normalized(); throw CheckFailure(label: label + " unexpectedly accepted") }
        catch let error as MetadataDraftError { try expect(error == expected, label) }
    }
    static func main() throws {
        let input = ControlMetadataDraft(name: "  Телефон\n", note: "строка1\r\nстрока2\r\tконец  ")
        let clean = try input.normalized()
        try expect(clean.name == "Телефон", "trim name")
        try expect(clean.note == "строка1\nстрока2\n\tконец  ", "normalize only note line endings, preserve spaces")
        try expect(input.name == "  Телефон\n", "validation does not mutate input")
        try expect(try clean.normalized() == clean, "normalization is idempotent")
        try expect(try ControlMetadataDraft(name: "Телефон", note: "").normalized().note.isEmpty, "empty note clears")
        try reject(.init(name: " \n\t", note: ""), .nameRequired, "empty normalized name")
        try expect(try ControlMetadataDraft(name: String(repeating: "Я", count: 80), note: "").normalized().name.unicodeScalars.count == 80, "name 80 unicode scalars")
        try reject(.init(name: String(repeating: "Я", count: 81), note: ""), .nameTooLong, "name 81 scalars")
        try expect(try ControlMetadataDraft(name: String(repeating: "e\u{301}", count: 80), note: "").normalized().name == String(repeating: "é", count: 80), "NFC before scalar limit")
        try expect(try ControlMetadataDraft(name: "🙂", note: String(repeating: "🙂", count: 1000)).normalized().note.unicodeScalars.count == 1000, "1000 four-byte scalars")
        try reject(.init(name: "Телефон", note: String(repeating: "🙂", count: 1001)), .noteTooLong, "note 1001 scalars")
        let decomposedHangul = String(repeating: "\u{1100}\u{1161}\u{11A8}", count: 1000)
        try expect(try ControlMetadataDraft(name: "iPad", note: decomposedHangul).normalized().note == String(repeating: "각", count: 1000), "valid long canonical decomposition accepted before normalized limit")
        let family = "👨‍👩‍👧‍👦"
        try expect(family.count == 1 && family.unicodeScalars.count == 7, "graphemes differ from API length unit")
        try reject(.init(name: String(repeating: family, count: 12), note: ""), .nameTooLong, "family graphemes exceed scalar limit")
        try expect(try ControlMetadataDraft(name: family, note: "").normalized().name == family, "ZWJ preserved")
        try reject(.init(name: "a\u{0}b", note: ""), .controlCharacter, "name NUL")
        try reject(.init(name: "a\nb", note: ""), .controlCharacter, "interior name newline")
        try reject(.init(name: "a", note: "a\u{0}b"), .controlCharacter, "note NUL")
        try reject(.init(name: "a", note: "\u{7}"), .controlCharacter, "note BEL")
        try reject(.init(name: "a", note: "\u{85}"), .controlCharacter, "note next-line control")
        try expect(try ControlMetadataDraft(name: "iPad", note: "<b>обычный текст</b>").normalized().note == "<b>обычный текст</b>", "text remains data")
        try expect(try ControlMetadataDraft(name: "iPad", note: "e\u{301}").normalized().note == "é", "note NFC")
        try expect(try ControlMetadataDraft(name: "\u{A0}Mac\u{A0}", note: "").normalized().name == "Mac", "unicode edge whitespace")
        try reject(.init(name: String(repeating: "a", count: 4097), note: ""), .inputTooLarge, "raw name bound")
        try reject(.init(name: "a", note: String(repeating: "a", count: 65537)), .inputTooLarge, "raw note bound")
        print("ControlMetadataDraft: \(checks) checks PASS; local text validation only, no API or live effects")
    }
    struct CheckFailure: Error { let label: String }
}
