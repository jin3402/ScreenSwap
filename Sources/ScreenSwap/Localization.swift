import Foundation

/// Looks a string up in the app bundle's `.lproj` tables.
///
/// English text doubles as the key, so an unbundled build — `swift run`, or the raw
/// binary during development — falls straight back to English instead of showing
/// bare identifiers.
func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}

/// Formatted variant, for strings with substitutions.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, bundle: .main, comment: ""), arguments: arguments)
}
