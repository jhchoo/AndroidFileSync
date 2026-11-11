// Models/AppInfo.swift
// Data model for an installed Android app

import Foundation

// MARK: - App Filter

enum AppFilter: String, CaseIterable, Identifiable {
    case all      = "All"
    case user     = "User"
    case system   = "System"
    case disabled = "Disabled"

    var id: String { rawValue }

    var localizedKey: String {
        switch self {
        case .all:      return "common_apps"
        case .user:     return "app_browser_filter_user"
        case .system:   return "app_browser_filter_system"
        case .disabled: return "app_browser_filter_disabled"
        }
    }

    var icon: String {
        switch self {
        case .all:      return "square.grid.2x2.fill"
        case .user:     return "person.fill"
        case .system:   return "gearshape.fill"
        case .disabled: return "nosign"
        }
    }
}

// MARK: - AppInfo

struct AppInfo: Identifiable, Hashable {
    let id: String              // package name, guaranteed unique
    let packageName: String
    let displayName: String     // human-readable label
    let versionName: String
    let isSystemApp: Bool
    var isEnabled: Bool

    // Derive a readable display name from the package name
    // e.g. "com.google.android.youtube" → "YouTube"
    static func labelFrom(package pkg: String) -> String {
        return smartLabel(from: pkg)
    }

    // MARK: - Smart Label Derivation

    /// Smarter label fallback used when `pm dump` returns nothing useful.
    /// Much better than `labelFrom` — strips noise segments and joins remaining words.
    static func smartLabel(from pkg: String) -> String {
        // 1. Check the known map first
        if let friendly = AppInfo.knownLabels[pkg] { return friendly }

        // 2. Break into segments and strip noise
        let noisePrefixes: Set<String> = ["com", "org", "net", "io", "app", "co", "me", "in"]
        let noiseMiddle: Set<String> = [
            "google", "android", "app", "apps", "application", "mobile",
            "phone", "client", "lite", "free"
        ]
        let noiseSuffixes: Set<String> = [
            "android", "app", "androidapp", "mobile", "phone",
            "client", "lite", "free", "official"
        ]

        var segments = pkg.split(separator: ".").map { String($0).lowercased() }

        // Remove TLD-style prefix (com, org, net, etc.)
        if let first = segments.first, noisePrefixes.contains(first) {
            segments.removeFirst()
        }

        // Remove trailing noise suffixes
        while let last = segments.last, noiseSuffixes.contains(last), segments.count > 1 {
            segments.removeLast()
        }

        // Remove well-known middle noise (google, android) unless nothing else
        let filtered = segments.filter { !noiseMiddle.contains($0) }
        if !filtered.isEmpty { segments = filtered }

        // 3. Pick the remaining segments, expand camelCase, title-case each word
        let words = segments.flatMap { seg -> [String] in
            // Split camelCase: "whereIsMyTrain" → ["where","Is","My","Train"]
            let spaced = seg.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2",
                                                  options: .regularExpression)
            return spaced.components(separatedBy: .whitespaces)
        }
        let titled = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return titled.joined(separator: " ")
    }

    // Extracted so both labelFrom and smartLabel can share it
    private static var knownLabels: [String: String] = [
        "com.google.android.youtube":      "YouTube",
        "com.google.android.gm":           "Gmail",
        "com.google.android.apps.maps":    "Google Maps",
        "com.google.android.googlequicksearchbox": "Google",
        "com.google.android.apps.photos":  "Google Photos",
        "com.google.android.music":        "Google Play Music",
        "com.google.android.apps.docs":    "Google Docs",
        "com.google.android.apps.sheets":  "Google Sheets",
        "com.google.android.apps.slides":  "Google Slides",
        "com.google.android.talk":         "Google Meet",
        "com.google.android.calendar":     "Google Calendar",
        "com.google.android.keep":         "Google Keep",
        "com.google.android.apps.translate": "Google Translate",
        "com.google.android.dialer":       "Phone",
        "com.google.android.contacts":     "Contacts",
        "com.google.android.apps.messaging": "Messages",
        "com.android.vending":             "Play Store",
        "com.android.chrome":              "Chrome",
        "com.android.settings":            "Settings",
        "com.android.camera2":             "Camera",
        "com.android.gallery3d":           "Gallery",
        "com.android.calculator2":         "Calculator",
        "com.android.calendar":            "Calendar",
        "com.android.contacts":            "Contacts",
        "com.android.phone":               "Phone",
        "com.android.mms":                 "Messages",
        "com.whatsapp":                    "WhatsApp",
        "com.instagram.android":           "Instagram",
        "com.facebook.katana":             "Facebook",
        "com.twitter.android":             "X (Twitter)",
        "com.spotify.music":               "Spotify",
        "com.netflix.mediaclient":         "Netflix",
        "com.amazon.mShop.android.shopping": "Amazon",
        "org.telegram.messenger":          "Telegram",
        "com.snapchat.android":            "Snapchat",
        "com.linkedin.android":            "LinkedIn",
        "com.microsoft.teams":             "Microsoft Teams",
        "com.microsoft.launcher":          "Microsoft Launcher",
        "com.samsung.android.app.notes":   "Samsung Notes",
        "com.sec.android.app.camera":      "Samsung Camera",
        "com.sec.android.gallery3d":       "Samsung Gallery",
        "com.dreamplug.androidapp":        "CRED",
        "com.adobe.scan.android":         "Adobe Scan",
        "com.digilocker.android":          "DigiLocker",
        "com.whereismytrain.android":      "Where Is My Train",
        "com.azure.authenticator":         "Microsoft Authenticator",
        "com.google.android.apps.work.clouddpc": "Android Device Policy",
        "com.google.android.contactkeys":  "Contact Key Verification",
        "com.pubg.imobile":                "BGMI",
        "com.maxmpz.audioplayer":          "Poweramp",
        "com.canarabank.mobility":         "Canara Bank",
        "in.amazon.mShop.android.shopping": "Amazon Shopping",
    ]
}
