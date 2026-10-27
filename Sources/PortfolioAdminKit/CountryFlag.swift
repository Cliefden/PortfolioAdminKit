import Foundation

/// Placeholder shown when a country can't be resolved.
public let unknownCountryFlag = "🌍"

/// Flag emoji for an ISO 3166-1 alpha-2 code (`"SE"`, `"se"`) or an English
/// or Swedish country name (`"Sweden"`, `"Sverige"`), else `🌍`.
///
/// Generalizes Nassau's `countryFlagEmoji(for:)`, which only knew 17 names
/// from a hard-coded map; this resolves every region `Locale` knows.
public func countryFlag(_ countryOrCode: String) -> String {
    guard let code = countryCode(for: countryOrCode) else { return unknownCountryFlag }
    return flagEmoji(isoCode: code) ?? unknownCountryFlag
}

/// The ISO 3166-1 alpha-2 code (uppercase) for a code or country name, or `nil`.
public func countryCode(for countryOrCode: String) -> String? {
    let trimmed = countryOrCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.count == 2, trimmed.unicodeScalars.allSatisfy({ $0.isASCII && $0.properties.isAlphabetic }) {
        let upper = trimmed.uppercased()
        if upper == "UK" { return "GB" }
        return CountryNames.knownCodes.contains(upper) ? upper : nil
    }
    return CountryNames.codeByName[CountryNames.normalize(trimmed)]
}

/// Regional-indicator flag for a two-letter code, or `nil` if it isn't A–Z.
func flagEmoji(isoCode: String) -> String? {
    let upper = isoCode.uppercased()
    guard upper.count == 2 else { return nil }
    var flag = ""
    for scalar in upper.unicodeScalars {
        guard ("A"..."Z").contains(scalar),
              let indicator = UnicodeScalar(0x1F1E6 + scalar.value - 65) else { return nil }
        flag.unicodeScalars.append(indicator)
    }
    return flag
}

enum CountryNames {
    /// Two-letter region codes `Locale` knows (excludes numeric UN M.49 areas).
    static let knownCodes: Set<String> = Set(
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
    )

    /// Names that `Locale` doesn't produce but the data uses.
    static let aliases: [String: String] = [
        "scotland": "GB", "england": "GB", "wales": "GB", "northern ireland": "GB",
        "uk": "GB", "great britain": "GB", "britain": "GB",
        "usa": "US", "united states of america": "US", "america": "US",
        "holland": "NL", "czech republic": "CZ", "south korea": "KR", "russia": "RU",
    ]

    /// Lower-cased, diacritic-folded English + Swedish names → code.
    static let codeByName: [String: String] = {
        var map: [String: String] = [:]
        for identifier in ["en_US", "sv_SE"] {
            let locale = Locale(identifier: identifier)
            for code in knownCodes {
                if let name = locale.localizedString(forRegionCode: code) {
                    let key = normalize(name)
                    if map[key] == nil { map[key] = code }
                }
            }
        }
        for (name, code) in aliases { map[name] = code }
        return map
    }()

    static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: "and")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
