import Foundation
import SwiftUI

enum GrapeTheme { static let accent = Color(red: 0.57, green: 0.36, blue: 0.84) }

enum Language {
    static var isRussian: Bool {
        let language = ProcessInfo.processInfo.environment["GRAPE_TEST_LANGUAGE"] ?? Locale.preferredLanguages.first ?? "en"
        return language.lowercased().hasPrefix("ru")
    }
    static var locale: Locale { Locale(identifier: isRussian ? "ru_RU" : "en_US") }
    static func date(_ date: Date) -> String { date.formatted(.dateTime.day().month().year().hour().minute().locale(locale)) }
}
func L(_ russian: String, _ english: String) -> String { Language.isRussian ? russian : english }
