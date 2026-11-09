//
//  FilePreviewManager.swift
//  AndroidFileSync
//
//  Tiered preview: instant thumbnails for videos/images, full pull for documents.
//  Shows in-app QuickLook-style panel instead of always opening external apps.
//

import Foundation
import AppKit
import AVFoundation
import PDFKit
internal import Combine

// MARK: - Preview Content Types

enum PreviewContent: Equatable {
    case image(NSImage)
    case videoThumbnail(NSImage)
    case videoReady(URL)         // Full video file available for inline playback
    case pdfReady(URL)           // Full PDF file available for PDFKit viewer
    case quickLookReady(URL)     // Full document file available for QuickLook viewer
    case audioIcon
    case documentIcon(String) // extension
    case loading
    case error(String)
    
    static func == (lhs: PreviewContent, rhs: PreviewContent) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.audioIcon, .audioIcon):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        case (.documentIcon(let a), .documentIcon(let b)):
            return a == b
        case (.image(let a), .image(let b)):
            return a === b
        case (.videoThumbnail(let a), .videoThumbnail(let b)):
            return a === b
        case (.videoReady(let a), .videoReady(let b)):
            return a == b
        case (.pdfReady(let a), .pdfReady(let b)):
            return a == b
        case (.quickLookReady(let a), .quickLookReady(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - File Category

enum PreviewFileCategory: String {
    case image, video, audio, pdf, document, unknown
    
    init(extension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg", "ico":
            self = .image
        case "mp4", "mov", "avi", "mkv", "m4v", "webm":
            self = .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg":
            self = .audio
        case "pdf":
            self = .pdf
        case "txt", "rtf", "rtfd", "html", "htm", "md", "markdown", "json", "xml", "csv", "tsv",
             "doc", "docx", "dot", "dotx", "xls", "xlsx", "xlsm", "xlsb", "ppt", "pptx", "pps", "ppsx", "pot", "potx",
             "pages", "numbers", "key", "keynote", "epub", "log", "yaml", "yml", "plist",
             "swift", "java", "py", "js", "ts", "c", "cpp", "h", "hpp", "css", "sh", "bash", "zsh":
            self = .document
        default:
            self = .unknown
        }
    }
    
    /// SF Symbol name for this category
    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .unknown: return "doc"
        }
    }
    
    /// Display label (uppercase)
    var label: String { rawValue.uppercased() }
}

// MARK: - Preview Manager

/// Manages file preview with a tiered strategy:
/// - Images: piped directly via `adb exec-out cat` → `NSImage`
/// - Videos: partial pull (first 4 MB) → `AVAssetImageGenerator` thumbnail
/// - PDF: full pull → native PDFKit interactive viewer with thumbnail sidebar & controls
/// - Documents (Word, Excel, PowerPoint, text, etc.): full pull → native QuickLook viewer
/// - Audio: show icon + metadata
///
/// All UI state is `@MainActor`-isolated to ensure thread-safe `@Published` updates.
@MainActor
class FilePreviewManager: ObservableObject {
    // MARK: - Published State
    
    @Published var showPreviewPanel = false
    @Published var previewContent: PreviewContent = .loading
    @Published private(set) var previewFile: UnifiedFile?
    @Published private(set) var isLoadingFullFile = false
    @Published private(set) var fullFilePullProgress: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var loadingFileName = ""
    
    /// Signals to Shell that the current operation should be killed.
    /// `nonisolated` because `Shell.runWithProgressCancellable` reads it from a background thread.
    nonisolated(unsafe) var cancellationRequested = false
    
    // MARK: - Private State
    
    private var currentTask: Task<Void, Never>?
    private var fullPullTask: Task<Void, Never>?
    
    /// Cache of already-pulled full files: devicePath → localTempURL
    private var fileCache: [String: URL] = [:]
    
    /// Cache of preview thumbnails: devicePath → NSImage
    private var thumbnailCache: [String: NSImage] = [:]
    
    /// Temp directory for pulled preview files
    private nonisolated let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidFileSync_Preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    // MARK: - Size Thresholds
    
    /// Images below this size are pulled fully (fast enough over USB)
    private let smallImageThreshold: UInt64 = 8 * 1024 * 1024 // 8 MB
    
    /// Bytes to pull for video thumbnail extraction
    private let videoPartialPullBytes = 4 * 1024 * 1024 // 4 MB
    
    // MARK: - Previewable Extensions (static, computed once)
    
    private static let previewableExtensions: Set<String> = [
        // Images
        "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg", "ico",
        // Videos
        "mp4", "mov", "avi", "mkv", "m4v", "webm",
        // Audio
        "mp3", "m4a", "wav", "flac", "aac", "ogg",
        // Documents
        "pdf", "txt", "rtf", "rtfd", "html", "htm", "md", "markdown", "json", "xml", "csv", "tsv",
        // Office (Word, Excel, PowerPoint)
        "doc", "docx", "dot", "dotx",
        "xls", "xlsx", "xlsm", "xlsb",
        "ppt", "pptx", "pps", "ppsx", "pot", "potx",
        // Apple iWork & eBooks
        "pages", "numbers", "key", "keynote", "epub",
        // Code & Config
        "swift", "java", "py", "js", "ts", "c", "cpp", "h", "hpp", "css", "sh", "bash", "zsh",
        "log", "yaml", "yml", "plist"
    ]
    
    // MARK: - Public API
    
    /// Preview a file using the tiered strategy.
    /// Both Space bar and double-click route here → shows in-app panel.
    func previewFile(_ file: UnifiedFile) {
        guard !file.isDirectory else { return }
        
        // Toggle off if already showing this file
        if showPreviewPanel, previewFile?.path == file.path {
            dismissPreview()
            return
        }
        
        let category = PreviewFileCategory(extension: file.pathExtension)
        let cleanPath = FileNameHelper.cleanRemotePath(file.path)
        
        // Check file cache first — cached videos, PDFs, and documents open instantly on re-open
        if (category == .video || category == .pdf || category == .document),
           let cachedURL = fileCache[file.path] ?? fileCache[cleanPath],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            previewFile = file
            switch category {
            case .pdf:
                previewContent = .pdfReady(cachedURL)
            case .video:
                previewContent = .videoReady(cachedURL)
            default:
                previewContent = .quickLookReady(cachedURL)
            }
            showPreviewPanel = true
            return
        }
        
        // Check thumbnail cache for instant display
        if let cachedThumb = thumbnailCache[file.path] {
            previewFile = file
            previewContent = category == .video ? .videoThumbnail(cachedThumb) : .image(cachedThumb)
            showPreviewPanel = true
            // For videos with cached thumbnail but no cached file, start the pull
            if category == .video {
                currentTask?.cancel()
                cancellationRequested = false
                currentTask = Task {
                    await generateVideoThumbnail(file)
                }
            }
            return
        }
        
        // Cancel any active task
        currentTask?.cancel()
        cancellationRequested = false
        
        // Show panel immediately with loading state
        previewFile = file
        previewContent = .loading
        showPreviewPanel = true
        isLoading = true
        loadingFileName = file.name
        
        // Route to the appropriate loader
        currentTask = Task {
            switch category {
            case .image:
                await loadImagePreview(file)
            case .video:
                await generateVideoThumbnail(file)
            case .pdf:
                await loadPDFPreview(file)
            case .document:
                await loadQuickLookPreview(file)
            case .audio:
                previewContent = .audioIcon
                isLoading = false
            case .unknown:
                previewContent = .documentIcon(file.pathExtension)
                isLoading = false
            }
        }
    }
    
    /// Dismiss the preview panel
    func dismissPreview() {
        showPreviewPanel = false
        isLoading = false
        loadingFileName = ""
        cancellationRequested = true
        currentTask?.cancel()
        currentTask = nil
        fullPullTask?.cancel()
        fullPullTask = nil
        isLoadingFullFile = false
        fullFilePullProgress = ""
    }
    
    /// Cancel all preview operations and close the panel
    func cancelPreview() {
        cancellationRequested = true
        dismissPreview()
        isLoadingFullFile = false
        fullPullTask?.cancel()
        fullPullTask = nil
    }
    
    /// Open the currently previewed file in an external app.
    /// Pulls the full file if not already cached, then opens with NSWorkspace.
    func openInExternalApp() {
        guard let file = previewFile else { return }
        
        let cleanPath = FileNameHelper.cleanRemotePath(file.path)
        // Check file cache — if already pulled, open immediately
        if let cached = fileCache[file.path] ?? fileCache[cleanPath], FileManager.default.fileExists(atPath: cached.path) {
            NSWorkspace.shared.open(cached)
            return
        }
        
        // Pull the full file in background
        isLoadingFullFile = true
        fullFilePullProgress = "Downloading..."
        
        fullPullTask = Task {
            let cleanDevicePath = FileNameHelper.cleanRemotePath(file.path)
            let cleanFileName = FileNameHelper.cleanFileName(file.name)
            let localURL = tempDir.appendingPathComponent(cleanFileName)
            try? FileManager.default.removeItem(at: localURL)
            
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else {
                isLoadingFullFile = false
                return
            }
            
            var (code, _, error, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: ADBManager.deviceArgs(["pull", cleanDevicePath, localURL.path]),
                progressCallback: { [self] text in
                    parseAndUpdateProgress(text)
                },
                cancellationCheck: { [self] in
                    cancellationRequested
                }
            )

            // If pulling failed due to file not found, retry with complementary Unicode normalization (NFC <-> NFD)
            if code != 0 && (error.contains("failed to stat") || error.contains("No such file or directory")) {
                let altPath = cleanDevicePath == cleanDevicePath.precomposedStringWithCanonicalMapping
                    ? cleanDevicePath.decomposedStringWithCanonicalMapping
                    : cleanDevicePath.precomposedStringWithCanonicalMapping
                if altPath != cleanDevicePath {
                    let (retryCode, _, retryErr, _) = await Shell.runWithProgressCancellable(
                        adbPath,
                        args: ADBManager.deviceArgs(["pull", altPath, localURL.path]),
                        progressCallback: { [self] text in
                            parseAndUpdateProgress(text)
                        },
                        cancellationCheck: { [self] in
                            cancellationRequested
                        }
                    )
                    if retryCode == 0 {
                        code = 0
                        error = ""
                    } else {
                        error = retryErr
                    }
                }
            }
            
            isLoadingFullFile = false
            
            guard !cancellationRequested else {
                try? FileManager.default.removeItem(at: localURL)
                return
            }
            
            if code == 0, FileManager.default.fileExists(atPath: localURL.path) {
                fileCache[cleanDevicePath] = localURL
                fileCache[file.path] = localURL
                NSWorkspace.shared.open(localURL)
            } else {
                print("❌ Preview: Failed to pull file: \(error)")
            }
        }
    }
    
    // MARK: - Tiered Preview Methods

    /// Load document preview by pulling the file to temp directory for QuickLook viewing.
    /// Supports Word (doc/docx), Excel (xls/xlsx), PowerPoint (ppt/pptx), and other office/text documents.
    private func loadQuickLookPreview(_ file: UnifiedFile) async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            previewContent = .error("ADB not found")
            isLoading = false
            return
        }

        let cleanDevicePath = FileNameHelper.cleanRemotePath(file.path)
        let cleanFileName = FileNameHelper.cleanFileName(file.name)

        // Check cache first
        if let cachedURL = fileCache[cleanDevicePath] ?? fileCache[file.path], FileManager.default.fileExists(atPath: cachedURL.path) {
            isLoading = false
            previewContent = .quickLookReady(cachedURL)
            return
        }

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localURL = tempDir.appendingPathComponent(cleanFileName)
        try? FileManager.default.removeItem(at: localURL)

        isLoadingFullFile = true
        fullFilePullProgress = "문서 불러오는 중..."

        var (code, _, error, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: ADBManager.deviceArgs(["pull", cleanDevicePath, localURL.path]),
            progressCallback: { [weak self] text in
                self?.parseAndUpdateProgress(text)
            },
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )

        // If pulling failed due to file not found, retry with complementary Unicode normalization (NFC <-> NFD)
        if code != 0 && (error.contains("failed to stat") || error.contains("No such file or directory")) {
            let altPath = cleanDevicePath == cleanDevicePath.precomposedStringWithCanonicalMapping
                ? cleanDevicePath.decomposedStringWithCanonicalMapping
                : cleanDevicePath.precomposedStringWithCanonicalMapping
            if altPath != cleanDevicePath {
                let (retryCode, _, retryErr, _) = await Shell.runWithProgressCancellable(
                    adbPath,
                    args: ADBManager.deviceArgs(["pull", altPath, localURL.path]),
                    progressCallback: { [weak self] text in
                        self?.parseAndUpdateProgress(text)
                    },
                    cancellationCheck: { [weak self] in
                        self?.cancellationRequested ?? false
                    }
                )
                if retryCode == 0 {
                    code = 0
                    error = ""
                } else {
                    error = retryErr
                }
            }
        }

        isLoadingFullFile = false
        isLoading = false

        guard !Task.isCancelled, !cancellationRequested else {
            try? FileManager.default.removeItem(at: localURL)
            return
        }

        if code == 0, FileManager.default.fileExists(atPath: localURL.path) {
            fileCache[cleanDevicePath] = localURL
            fileCache[file.path] = localURL
            previewContent = .quickLookReady(localURL)
        } else {
            print("❌ Preview: Failed to pull/open document: code=\(code), error=\(error)")
            previewContent = .error("문서를 불러올 수 없습니다: \(error.isEmpty ? "알 수 없는 오류" : error)")
        }
    }

    /// Load PDF preview by pulling the file to temp directory for PDFKit viewing.
    private func loadPDFPreview(_ file: UnifiedFile) async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            previewContent = .error("ADB not found")
            isLoading = false
            return
        }

        let cleanDevicePath = FileNameHelper.cleanRemotePath(file.path)
        let cleanFileName = FileNameHelper.cleanFileName(file.name)

        // Check cache first
        if let cachedURL = fileCache[cleanDevicePath] ?? fileCache[file.path], FileManager.default.fileExists(atPath: cachedURL.path) {
            isLoading = false
            previewContent = .pdfReady(cachedURL)
            return
        }

        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let localURL = tempDir.appendingPathComponent(cleanFileName)
        try? FileManager.default.removeItem(at: localURL)

        isLoadingFullFile = true
        fullFilePullProgress = "Loading PDF..."

        var (code, _, error, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: ADBManager.deviceArgs(["pull", cleanDevicePath, localURL.path]),
            progressCallback: { [weak self] text in
                self?.parseAndUpdateProgress(text)
            },
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )

        // If pulling failed due to file not found, retry with complementary Unicode normalization (NFC <-> NFD)
        if code != 0 && (error.contains("failed to stat") || error.contains("No such file or directory")) {
            let altPath = cleanDevicePath == cleanDevicePath.precomposedStringWithCanonicalMapping
                ? cleanDevicePath.decomposedStringWithCanonicalMapping
                : cleanDevicePath.precomposedStringWithCanonicalMapping
            if altPath != cleanDevicePath {
                let (retryCode, _, retryErr, _) = await Shell.runWithProgressCancellable(
                    adbPath,
                    args: ADBManager.deviceArgs(["pull", altPath, localURL.path]),
                    progressCallback: { [weak self] text in
                        self?.parseAndUpdateProgress(text)
                    },
                    cancellationCheck: { [weak self] in
                        self?.cancellationRequested ?? false
                    }
                )
                if retryCode == 0 {
                    code = 0
                    error = ""
                } else {
                    error = retryErr
                }
            }
        }

        isLoadingFullFile = false
        isLoading = false

        guard !Task.isCancelled, !cancellationRequested else {
            try? FileManager.default.removeItem(at: localURL)
            return
        }

        if code == 0, FileManager.default.fileExists(atPath: localURL.path) {
            let doc = PDFDocument(url: localURL) ?? (try? Data(contentsOf: localURL)).flatMap({ PDFDocument(data: $0) })
            if doc != nil {
                fileCache[cleanDevicePath] = localURL
                fileCache[file.path] = localURL
                previewContent = .pdfReady(localURL)
            } else {
                print("❌ Preview: Failed to parse PDF document at \(localURL.path)")
                previewContent = .error("Failed to parse PDF document")
            }
        } else {
            print("❌ Preview: Failed to pull/open PDF: code=\(code), error=\(error)")
            previewContent = .error("Failed to load PDF: \(error.isEmpty ? "Unknown error" : error)")
        }
    }
    
    /// Load image preview by piping bytes via `adb exec-out cat`.
    /// No temp file needed — bytes convert directly to NSImage in memory.
    /// Falls back to `adb pull` for reliability if exec-out gives corrupted data.
    private func loadImagePreview(_ file: UnifiedFile) async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            previewContent = .error("ADB not found")
            isLoading = false
            return
        }
        
        // Limit bytes for very large images; most phone images are < 20 MB
        let maxBytes = file.size > smallImageThreshold ? Int(smallImageThreshold) : 0
        
        // Strategy 1: Pipe via exec-out cat (fastest — no temp file)
        let (_, data, _) = await Shell.runAndCaptureData(
            adbPath,
            args: ADBManager.deviceArgs(["exec-out", "cat", file.path]),
            maxBytes: maxBytes,
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        
        if !data.isEmpty, let image = NSImage(data: data) {
            isLoading = false
            thumbnailCache[file.path] = image
            previewContent = .image(image)
            return
        }
        
        // Strategy 2: Fall back to adb pull (handles exec-out binary corruption)
        print("⚠️ Preview: exec-out cat failed for image, falling back to adb pull")
        let localURL = tempDir.appendingPathComponent(file.name)
        try? FileManager.default.removeItem(at: localURL)
        
        let (code, _, _, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: ADBManager.deviceArgs(["pull", file.path, localURL.path]),
            progressCallback: { _ in },
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        isLoading = false
        
        if code == 0, let image = NSImage(contentsOf: localURL) {
            fileCache[file.path] = localURL
            thumbnailCache[file.path] = image
            previewContent = .image(image)
        } else {
            previewContent = .error("Failed to load image")
        }
    }
    
    /// Generate video preview using a multi-strategy approach:
    /// 1. Show MediaStore thumbnail immediately (fast)
    /// 2. Pull full video in background → transition to inline playback
    /// 3. Placeholder if MediaStore fails
    private func generateVideoThumbnail(_ file: UnifiedFile) async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            previewContent = .error("ADB not found")
            isLoading = false
            return
        }
        
        let fullPullLimit: UInt64 = 50 * 1024 * 1024 // 50 MB
        
        // ── Fast path: cached video → instant playback ───────────────────
        // On re-open, skip the MediaStore query entirely and play immediately.
        if file.size <= fullPullLimit,
           let cachedURL = fileCache[file.path],
           FileManager.default.fileExists(atPath: cachedURL.path) {
            isLoading = false
            previewContent = .videoReady(cachedURL)
            return
        }
        
        // ── Step 1: Show thumbnail immediately ───────────────────────────
        // Get a quick thumbnail from MediaStore while we pull the video
        var gotThumbnail = false
        if let thumb = await fetchMediaStoreThumbnail(file: file, adbPath: adbPath) {
            guard !Task.isCancelled, !cancellationRequested else { return }
            isLoading = false
            thumbnailCache[file.path] = thumb
            previewContent = .videoThumbnail(thumb)
            gotThumbnail = true
        }
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        
        // ── Step 2: Auto-pull video for inline playback ──────────────────
        // For small/medium videos, pull in background and upgrade to .videoReady
        if file.size <= fullPullLimit {
            
            // Show pull progress on the thumbnail overlay
            isLoadingFullFile = true
            fullFilePullProgress = ""
            
            // If we didn't get a thumbnail yet, keep the loading spinner
            if !gotThumbnail {
                isLoading = true
            }
            
            let localURL = tempDir.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: localURL)
            
            let (code, _, _, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: ADBManager.deviceArgs(["pull", file.path, localURL.path]),
                progressCallback: { [weak self] text in
                    self?.parseAndUpdateProgress(text)
                },
                cancellationCheck: { [weak self] in self?.cancellationRequested ?? false }
            )
            
            isLoadingFullFile = false
            fullFilePullProgress = ""
            
            guard !Task.isCancelled, !cancellationRequested else { return }
            
            if code == 0, FileManager.default.fileExists(atPath: localURL.path) {
                fileCache[file.path] = localURL
                isLoading = false
                
                // If we didn't have a thumbnail, extract one from the pulled file
                if !gotThumbnail, let thumb = await Self.extractVideoFrame(from: localURL) {
                    thumbnailCache[file.path] = thumb
                }
                
                // Upgrade to inline video player
                previewContent = .videoReady(localURL)
                return
            }
        }
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        
        // ── Step 3: Fallback ─────────────────────────────────────────────
        if !gotThumbnail {
            isLoading = false
            previewContent = .videoThumbnail(Self.videoPlaceholderIcon)
        }
    }
    
    // MARK: - Video Thumbnail Strategies
    
    /// Strategy 1: Fetch thumbnail from Android MediaStore.
    /// Normalizes the file path to `/storage/emulated/0/...` (what MediaStore uses),
    /// queries for the `_id`, then retrieves the thumbnail.
    private func fetchMediaStoreThumbnail(file: UnifiedFile, adbPath: String) async -> NSImage? {
        // Normalize path: /sdcard/... → /storage/emulated/0/...
        let physicalPath = Self.resolveToPhysicalPath(file.path)
        let escapedPath = physicalPath.replacingOccurrences(of: "'", with: "'\\''")
        
        // Step 1: Query MediaStore for the video's _id
        // Use shell with quoted --where to handle the content command properly
        let queryCmd = "content query --uri content://media/external/video/media --projection _id --where \"_data='\(escapedPath)'\""
        
        let (queryCode, queryOutput, queryErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: ADBManager.deviceArgs(["shell", queryCmd]), timeoutSeconds: 5
        )
        
        print("🔍 Preview: MediaStore query for \(file.name) → code=\(queryCode), output='\(queryOutput.prefix(200))', err='\(queryErr.prefix(100))'")
        
        // Parse _id from output like "Row: 0 _id=12345, ..."
        guard let mediaId = Self.parseMediaStoreId(from: queryOutput) else {
            // Try alternative: query by display_name (less precise but catches more cases)
            return await fetchMediaStoreThumbnailByName(fileName: file.name, adbPath: adbPath)
        }
        
        print("🔍 Preview: Found MediaStore _id=\(mediaId) for \(file.name)")
        
        // Step 2: Try to get thumbnail via the old video/thumbnails table
        // This works on Android 9 and below, and sometimes on 10+
        let thumbQueryCmd = "content query --uri content://media/external/video/thumbnails --projection _data --where \"video_id=\(mediaId)\""
        let (tCode, tOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: ADBManager.deviceArgs(["shell", thumbQueryCmd]), timeoutSeconds: 5
        )
        
        if tCode == 0, let thumbPath = Self.parseMediaStoreDataPath(from: tOutput) {
            print("🔍 Preview: Found thumbnail file at: \(thumbPath)")
            // Pull the tiny thumbnail file (~10-50KB)
            let localThumbURL = tempDir.appendingPathComponent("_ms_thumb_\(file.name).jpg")
            try? FileManager.default.removeItem(at: localThumbURL)
            
            let (pullCode, _, _, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: ADBManager.deviceArgs(["pull", thumbPath, localThumbURL.path]),
                progressCallback: { _ in },
                cancellationCheck: { [weak self] in self?.cancellationRequested ?? false }
            )
            
            if pullCode == 0, let image = NSImage(contentsOf: localThumbURL) {
                print("✅ Preview: Got MediaStore thumbnail file for \(file.name)")
                try? FileManager.default.removeItem(at: localThumbURL)
                return image
            }
        }
        
        // Step 3: Try content read (Android 10+)
        let readArgs = ADBManager.deviceArgs([
            "exec-out", "content", "read",
            "--uri", "content://media/external/video/media/\(mediaId)/thumbnail"
        ])
        
        let (_, thumbData, _) = await Shell.runAndCaptureData(
            adbPath,
            args: readArgs,
            maxBytes: 512 * 1024,
            cancellationCheck: { [weak self] in self?.cancellationRequested ?? false }
        )
        
        if !thumbData.isEmpty, let image = NSImage(data: thumbData) {
            print("✅ Preview: Got MediaStore content read thumbnail for \(file.name) (\(thumbData.count) bytes)")
            return image
        }
        
        print("⚠️ Preview: All MediaStore strategies failed for _id=\(mediaId)")
        return nil
    }
    
    /// Fallback MediaStore query by display_name instead of full path
    private func fetchMediaStoreThumbnailByName(fileName: String, adbPath: String) async -> NSImage? {
        let escapedName = fileName.replacingOccurrences(of: "'", with: "'\\''")
        let queryCmd = "content query --uri content://media/external/video/media --projection _id --where \"_display_name='\(escapedName)'\""
        
        let (_, queryOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: ADBManager.deviceArgs(["shell", queryCmd]), timeoutSeconds: 5
        )
        
        guard let mediaId = Self.parseMediaStoreId(from: queryOutput) else {
            print("⚠️ Preview: MediaStore query by name also failed for \(fileName)")
            return nil
        }
        
        print("🔍 Preview: Found MediaStore _id=\(mediaId) via display_name for \(fileName)")
        
        // Try content read
        let readArgs = ADBManager.deviceArgs([
            "exec-out", "content", "read",
            "--uri", "content://media/external/video/media/\(mediaId)/thumbnail"
        ])
        
        let (_, thumbData, _) = await Shell.runAndCaptureData(
            adbPath,
            args: readArgs,
            maxBytes: 512 * 1024,
            cancellationCheck: { [weak self] in self?.cancellationRequested ?? false }
        )
        
        if !thumbData.isEmpty, let image = NSImage(data: thumbData) {
            print("✅ Preview: Got thumbnail via display_name for \(fileName)")
            return image
        }
        
        return nil
    }
    
    /// Strategy 2: Pull entire video file (for small/medium files) and extract
    /// a frame locally with AVFoundation. This always works because we have the
    /// complete file with moov atom.
    private func fetchFullPullThumbnail(file: UnifiedFile, adbPath: String) async -> NSImage? {
        // Check if we already have this file cached
        if let cachedURL = fileCache[file.path], FileManager.default.fileExists(atPath: cachedURL.path) {
            return await Self.extractVideoFrame(from: cachedURL)
        }
        
        let localURL = tempDir.appendingPathComponent(file.name)
        try? FileManager.default.removeItem(at: localURL)
        
        print("🔍 Preview: Full pull for thumbnail - \(file.name) (\(file.size / 1024 / 1024) MB)")
        
        let (code, _, _, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: ADBManager.deviceArgs(["pull", file.path, localURL.path]),
            progressCallback: { _ in },
            cancellationCheck: { [weak self] in self?.cancellationRequested ?? false }
        )
        
        guard code == 0, FileManager.default.fileExists(atPath: localURL.path) else {
            print("⚠️ Preview: Full pull failed for \(file.name)")
            return nil
        }
        
        // Cache the pulled file so "Open in App" is instant later
        fileCache[file.path] = localURL
        
        let thumb = await Self.extractVideoFrame(from: localURL)
        if thumb != nil {
            print("✅ Preview: Got thumbnail via full pull for \(file.name)")
        }
        return thumb
    }
    
    // MARK: - Helpers (Video)
    
    /// Normalize `/sdcard/...` → `/storage/emulated/0/...` for MediaStore queries
    nonisolated static func resolveToPhysicalPath(_ path: String) -> String {
        AndroidStorageAccess.canonicalPath(path)
    }
    
    /// Parse MediaStore _id from content query output.
    /// Format: "Row: 0 _id=12345" or "Row: 0 _id=12345, other_col=value"
    nonisolated static func parseMediaStoreId(from output: String) -> String? {
        guard let range = output.range(of: #"_id=(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return String(output[range]).replacingOccurrences(of: "_id=", with: "")
    }
    
    /// Parse `_data` path from content query output.
    /// Format: "Row: 0 _data=/storage/emulated/0/.thumbnails/1234.jpg"
    private nonisolated static func parseMediaStoreDataPath(from output: String) -> String? {
        guard let range = output.range(of: #"_data=([^\s,]+)"#, options: .regularExpression) else {
            return nil
        }
        let result = String(output[range]).replacingOccurrences(of: "_data=", with: "")
        // Only return if it looks like an actual path
        return result.hasPrefix("/") ? result : nil
    }
    
    /// Extract a single frame from a video file using AVFoundation.
    /// Runs off the main actor since AVFoundation work is CPU-bound.
    private nonisolated static func extractVideoFrame(from url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        
        // Try frame at 1 second first (avoids black frames), then fallback to 0
        for time in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
            }
        }
        return nil
    }
    
    /// Cached system video icon — created once, reused for all fallbacks.
    nonisolated static let videoPlaceholderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .movie)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }()
    
    // MARK: - Helpers
    
    private nonisolated func parseAndUpdateProgress(_ text: String) {
        // ADB progress format: "[ 45%] /sdcard/video.mp4"
        guard let match = text.range(of: #"\[\s*(\d+)%\]"#, options: .regularExpression) else { return }
        let percentStr = text[match]
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Int(percentStr) else { return }
        Task { @MainActor [weak self] in
            self?.fullFilePullProgress = "Downloading… \(percent)%"
        }
    }
    
    /// Check if a file type is previewable
    static func isPreviewable(_ file: UnifiedFile) -> Bool {
        guard !file.isDirectory else { return false }
        return previewableExtensions.contains(file.pathExtension.lowercased())
    }
    
    // MARK: - Cleanup
    
    func clearCache() {
        fileCache.removeAll()
        thumbnailCache.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }
}
