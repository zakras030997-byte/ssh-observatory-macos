import Foundation

/// Owner-only display metadata. This value never contains a credential or changes access rights.
struct ControlMetadataDraft: Equatable {
    let name: String
    let note: String

    static let maximumNameScalars = 80
    static let maximumNoteScalars = 1000
    // Bound work before normalization. These limits apply to text, not an escaped JSON body.
    static let maximumRawNameBytes = 4096
    static let maximumRawNoteBytes = 65536

    func normalized() throws -> Self {
        guard name.utf8.count <= Self.maximumRawNameBytes,
              note.utf8.count <= Self.maximumRawNoteBytes,
              name.unicodeScalars.count <= 512, note.unicodeScalars.count <= 4096 else {
            throw MetadataDraftError.inputTooLarge
        }
        let normalizedName = name.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: Self.edgeWhitespace)
        let normalizedNote = note.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .precomposedStringWithCanonicalMapping
        guard !normalizedName.isEmpty else { throw MetadataDraftError.nameRequired }
        guard normalizedName.unicodeScalars.count <= Self.maximumNameScalars else {
            throw MetadataDraftError.nameTooLong
        }
        guard normalizedNote.unicodeScalars.count <= Self.maximumNoteScalars else {
            throw MetadataDraftError.noteTooLong
        }
        guard !normalizedName.unicodeScalars.contains(where: Self.disallowedNameScalar),
              !normalizedNote.unicodeScalars.contains(where: Self.disallowedNoteScalar) else {
            throw MetadataDraftError.controlCharacter
        }
        return Self(name: normalizedName, note: normalizedNote)
    }

    // Frozen Unicode White_Space set; Foundation may classify additional characters.
    private static let edgeWhitespace: CharacterSet = {
        let values = Array(9...13) + [0x20, 0x85, 0xA0, 0x1680] + Array(0x2000...0x200A) + [0x2028,0x2029,0x202F,0x205F,0x3000]
        return CharacterSet(charactersIn: String(String.UnicodeScalarView(values.compactMap(Unicode.Scalar.init))))
    }()
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name.utf8.elementsEqual(rhs.name.utf8) && lhs.note.utf8.elementsEqual(rhs.note.utf8)
    }
    private static func disallowedNameScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .surrogate
    }

    private static func disallowedNoteScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\n" || scalar == "\t" { return false }
        return disallowedNameScalar(scalar)
    }
}

enum MetadataDraftError: Error, LocalizedError, Equatable {
    case inputTooLarge, nameRequired, nameTooLong, noteTooLong, controlCharacter

    var errorDescription: String? {
        switch self {
        case .inputTooLarge: return "Слишком большой текст имени или заметки."
        case .nameRequired: return "Укажите имя устройства."
        case .nameTooLong: return "Имя должно содержать не более 80 кодовых точек Unicode."
        case .noteTooLong: return "Заметка должна содержать не более 1000 кодовых точек Unicode."
        case .controlCharacter: return "Удалите управляющие символы. В заметке допустимы переносы строк и табуляция."
        }
    }
}
