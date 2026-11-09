import Foundation

struct FileNameHelper {
    // Escape shell-sensitive characters in filenames
    static func escapeForShell(_ filename: String) -> String {
        // Characters that need escaping in shell commands
        let specialChars = CharacterSet(charactersIn: "\\\"'`$!&*()[]{};<>|?~ \t\n")
        
        var escaped = ""
        for char in filename {
            if char.unicodeScalars.first.map(specialChars.contains) == true {
                escaped.append("\\")
            }
            escaped.append(char)
        }
        
        return escaped
    }
    
    /// Escapes a string for safe use inside single quotes in a shell command.
    ///
    /// Inside single quotes, the ONLY character that needs special handling is `'` itself.
    /// The idiom `'\''` ends the current quote, inserts a literal `'`, and reopens the quote.
    /// International/Unicode characters pass through safely — single quotes preserve them as-is.
    static func escapeForSingleQuotedShell(_ value: String) -> String {
        return value.replacingOccurrences(of: "'", with: "'\\''")
    }
    
    // Sanitize filename by replacing problematic characters
    static func sanitizeFilename(_ filename: String, replacement: String = "_") -> String {
        // Replace characters that cause issues on Android
        let problematicChars = CharacterSet(charactersIn: "<>:\"|?*\\")
        
        var sanitized = ""
        for char in filename {
            if char.unicodeScalars.first.map(problematicChars.contains) == true {
                sanitized.append(replacement)
            } else {
                sanitized.append(char)
            }
        }
        
        // Also replace "->" which is interpreted as redirect operator
        sanitized = sanitized.replacingOccurrences(of: "->", with: "_to_")
        sanitized = sanitized.replacingOccurrences(of: ">>", with: "_append_")
        
        return sanitized
    }
    
    // Get safe version with original extension preserved
    static func getSafeFilename(_ filename: String) -> (safe: String, wasModified: Bool) {
        let sanitized = sanitizeFilename(filename)
        return (sanitized, sanitized != filename)
    }

    // MARK: - ADB Shell Output Sanitization

    // Regular expression for stripping ANSI escape sequences (colors, cursor movements, etc.)
    private static let ansiRegex = try? NSRegularExpression(
        pattern: #"\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])"#,
        options: []
    )

    /// Strips ANSI terminal escape codes, carriage returns, and control characters from ADB shell output.
    static func stripANSI(_ text: String) -> String {
        guard let regex = ansiRegex else {
            return text.replacingOccurrences(of: "\r", with: "")
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        return stripped.replacingOccurrences(of: "\r", with: "")
    }

    /// Cleans a filename returned from ADB commands:
    /// - Strips ANSI color codes and terminal escapes
    /// - Removes \r and non-printable control characters
    /// - Preserves exact Unicode byte sequence as stored on the remote device (preserves NFC or NFD)
    /// - Trims leading/trailing whitespace
    static func cleanFileName(_ name: String) -> String {
        let stripped = stripANSI(name)
        let controlChars = CharacterSet.controlCharacters
        let filtered = stripped.unicodeScalars.filter { scalar in
            !controlChars.contains(scalar)
        }
        return String(filtered).trimmingCharacters(in: .whitespaces)
    }

    /// Ensures an Android remote file path is properly formatted:
    /// - Cleans ANSI escapes and control characters
    /// - Ensures a leading slash "/"
    /// - Preserves exact Unicode byte sequence as stored on the remote device (preserves NFC or NFD)
    static func cleanRemotePath(_ path: String) -> String {
        let stripped = stripANSI(path)
        let controlChars = CharacterSet.controlCharacters
        let filtered = stripped.unicodeScalars.filter { scalar in
            !controlChars.contains(scalar)
        }
        let cleaned = String(filtered).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return "/" }
        return cleaned.hasPrefix("/") ? cleaned : "/" + cleaned
    }
}
