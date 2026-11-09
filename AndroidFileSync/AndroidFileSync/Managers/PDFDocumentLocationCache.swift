//
//  PDFDocumentLocationCache.swift
//  AndroidFileSync
//
//  Cache database for PDF preview locations and user preferences.
//  - Tracks last viewed page, scroll offset, and scale factor per document.
//  - Keeps records valid for 7 days (1 week).
//  - Cleans up stale entries (> 7 days) on app launch.
//

import Foundation

/// Stored location state for a single PDF document.
struct PDFDocumentLocation: Codable {
    var pageIndex: Int
    var scrollOffsetX: Double?
    var scrollOffsetY: Double?
    var scaleFactor: Double?
    var lastOpened: Date
}

@MainActor
final class PDFDocumentLocationCache {
    static let shared = PDFDocumentLocationCache()

    private let userDefaultsKey = "afs_pdf_document_locations_v1"
    private let validityDuration: TimeInterval = 7 * 24 * 60 * 60 // 7 days (1 week)

    private var cache: [String: PDFDocumentLocation] = [:]

    private init() {
        loadFromStorage()
    }

    /// Load saved locations from UserDefaults.
    private func loadFromStorage() {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: PDFDocumentLocation].self, from: data)
            self.cache = decoded
        } catch {
            print("⚠️ [PDFCache] Failed to decode location cache: \(error)")
        }
    }

    /// Persist current locations to UserDefaults.
    private func saveToStorage() {
        do {
            let data = try JSONEncoder().encode(cache)
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        } catch {
            print("⚠️ [PDFCache] Failed to encode location cache: \(error)")
        }
    }

    /// Get last saved location for a document path/key if within 7 days.
    func location(for key: String) -> PDFDocumentLocation? {
        guard let entry = cache[key] else { return nil }
        if Date().timeIntervalSince(entry.lastOpened) > validityDuration {
            cache.removeValue(forKey: key)
            saveToStorage()
            return nil
        }
        return entry
    }

    /// Save or update location for a document path/key.
    func saveLocation(
        for key: String,
        pageIndex: Int,
        scrollOffsetX: Double? = nil,
        scrollOffsetY: Double? = nil,
        scaleFactor: Double? = nil
    ) {
        guard !key.isEmpty else { return }
        cache[key] = PDFDocumentLocation(
            pageIndex: pageIndex,
            scrollOffsetX: scrollOffsetX,
            scrollOffsetY: scrollOffsetY,
            scaleFactor: scaleFactor,
            lastOpened: Date()
        )
        saveToStorage()
    }

    /// Purge entries older than 7 days. Called on app startup.
    func purgeExpiredEntries() {
        let now = Date()
        let initialCount = cache.count
        cache = cache.filter { _, entry in
            now.timeIntervalSince(entry.lastOpened) <= validityDuration
        }
        let removed = initialCount - cache.count
        if removed > 0 {
            saveToStorage()
            print("🧹 [PDFCache] Purged \(removed) expired PDF location entries (older than 7 days).")
        }
    }
}
