import Foundation

enum InterfaceLanguage: String {
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static var current: Self = .simplifiedChinese

    var title: String { self == .english ? "English" : "简体中文" }
    var alternate: Self { self == .english ? .simplifiedChinese : .english }

    private static let englishStrings: [String: String] = {
        guard let url = Bundle.main.url(forResource: "English", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }()

    func translate(_ source: String) -> String {
        self == .english ? Self.englishStrings[source] ?? source : source
    }
}

func ui(_ message: InterfaceMessage) -> String {
    message.render(InterfaceLanguage.current)
}

struct InterfaceMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let key: String
    private let arguments: [(InterfaceLanguage) -> String]

    init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    func render(_ language: InterfaceLanguage) -> String {
        let format = language.translate(key)
        guard !arguments.isEmpty else { return format }
        let parts = format.components(separatedBy: "%@")
        guard parts.count == arguments.count + 1 else { return format }
        return zip(parts, arguments).reduce(into: "") { result, part in
            result += part.0 + part.1(language)
        } + (parts.last ?? "")
    }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [(InterfaceLanguage) -> String] = []

        init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) {
            key += literal
        }

        mutating func appendInterpolation(_ value: InterfaceMessage) {
            key += "%@"
            arguments.append { value.render($0) }
        }

        mutating func appendInterpolation<T>(_ value: T) {
            key += "%@"
            let display = String(describing: value)
            arguments.append { _ in display }
        }
    }
}
