import Foundation

/// Model references are relative resource paths, not recipe/glob expressions.
public enum GrammarModelPath {
    public static func isValid(_ path: String) -> Bool {
        guard path.hasSuffix(".gram"), !path.hasPrefix("/"),
            let filename = path.split(separator: "/", omittingEmptySubsequences: false).last,
            filename.count > 5
        else { return false }
        return String(path.dropLast(5)).split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains(":")
                && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
        }
    }

    public static func path(for language: String) -> String? {
        let path = language + ".gram"
        return isValid(path) ? path : nil
    }
}
