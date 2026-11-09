//
//  FileDragManager.swift
//  AndroidFileSync
//
//  Created for AndroidFileSync.
//  Manages drag-and-drop operations for moving files into folders
//  and exporting files to Finder / macOS via file promises.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
internal import Combine

// MARK: - UnifiedFilePromiseProvider

/// File promise provider that enables dragging files out of AndroidFileSync to Finder,
/// while simultaneously providing internal drag metadata for moving files within the app.
final class UnifiedFilePromiseProvider: NSFilePromiseProvider {
    let file: UnifiedFile
    let allFiles: [UnifiedFile]

    init(file: UnifiedFile, allFiles: [UnifiedFile], delegate: NSFilePromiseProviderDelegate) {
        self.file = file
        self.allFiles = allFiles
        super.init()
        self.fileType = Self.fileType(for: file)
        self.delegate = delegate
        self.userInfo = file
    }

    static func fileType(for file: UnifiedFile) -> String {
        if file.isDirectory {
            return UTType.folder.identifier
        }
        let ext = (file.name as NSString).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext),
           utType.conforms(to: .data) || utType.conforms(to: .directory) || utType.conforms(to: .item) {
            return utType.identifier
        }
        return UTType.data.identifier
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        let internalType = NSPasteboard.PasteboardType(FileDragManager.internalFileUTI)
        if !types.contains(internalType) {
            types.append(internalType)
        }
        if !types.contains(.string) {
            types.append(.string)
        }
        return types
    }

    override func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        if type.rawValue == FileDragManager.internalFileUTI || type == .string {
            return []
        }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type.rawValue == FileDragManager.internalFileUTI {
            let paths = allFiles.map(\.path)
            if let jsonData = try? JSONEncoder().encode(paths),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
            return file.path
        }
        if type == .string {
            return file.path
        }
        return super.pasteboardPropertyList(forType: type)
    }
}

// MARK: - FileDragManager

@MainActor
final class FileDragManager: NSObject, ObservableObject, NSDraggingSource {
    static let shared = FileDragManager()

    static let internalFileUTI = "com.androidfilesync.internalfile"
    static let internalFileUTType = UTType(exportedAs: internalFileUTI, conformingTo: .data)

    @Published private(set) var draggedFiles: [UnifiedFile] = []
    @Published private(set) var isDragging: Bool = false
    weak var downloadManager: DownloadManager?

    private static let promiseOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.androidfilesync.dragdrop.promises"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    func startDrag(with files: [UnifiedFile], from view: NSView, event: NSEvent) {
        guard !files.isEmpty else { return }
        self.draggedFiles = files
        self.isDragging = true

        let image = Self.createDragImage(for: files)
        let mouseInView = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: mouseInView.x - 24,
            y: mouseInView.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )

        let dragItems: [NSDraggingItem] = files.map { file in
            let provider = UnifiedFilePromiseProvider(
                file: file,
                allFiles: files,
                delegate: self
            )
            let item = NSDraggingItem(pasteboardWriter: provider)
            item.setDraggingFrame(frame, contents: image)
            return item
        }

        let session = view.beginDraggingSession(with: dragItems, event: event, source: self)
        session.draggingFormation = .none
    }

    func clearDrag() {
        self.draggedFiles = []
        self.isDragging = false
    }

    // MARK: - NSDraggingSource

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication:
            return .copy
        case .withinApplication:
            return .move
        @unknown default:
            return [.copy, .move]
        }
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Task { @MainActor in
            FileDragManager.shared.clearDrag()
        }
    }

    // MARK: - Validation

    func canDrop(onto destinationPath: String) -> Bool {
        guard !draggedFiles.isEmpty else {
            // External drag (e.g. Finder) is valid onto any directory
            return true
        }

        let normalizedDest = destinationPath.hasSuffix("/") && destinationPath.count > 1
            ? String(destinationPath.dropLast())
            : destinationPath

        // Cannot drop onto any of the dragged items themselves
        if draggedFiles.contains(where: { $0.path == normalizedDest }) {
            return false
        }

        // Cannot drop into a subfolder of any dragged folder
        for file in draggedFiles where file.isDirectory {
            if normalizedDest == file.path || normalizedDest.hasPrefix(file.path + "/") {
                return false
            }
        }

        // Cannot drop into the current parent folder (moving in place is a no-op)
        if draggedFiles.allSatisfy({
            let parent = ($0.path as NSString).deletingLastPathComponent
            return normalizedDest == parent
        }) {
            return false
        }

        return true
    }

    func canDrop(onto folder: UnifiedFile) -> Bool {
        guard folder.isDirectory else { return false }
        return canDrop(onto: folder.path)
    }

    // MARK: - Drag Preview Image

    static func createDragImage(for files: [UnifiedFile]) -> NSImage {
        guard let firstFile = files.first else {
            return NSImage()
        }

        let isMultiple = files.count > 1
        let title = isMultiple ? "\(firstFile.name) +\(files.count - 1)" : firstFile.name

        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let iconSize: CGFloat = 18
        let padding: CGFloat = 8
        let spacing: CGFloat = 6

        let width = min(max(padding * 2 + iconSize + spacing + textSize.width, 80), 240)
        let height: CGFloat = 32
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            // Background pill
            let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            NSColor(calibratedWhite: 0.12, alpha: 0.92).setFill()
            bgPath.fill()
            NSColor.white.withAlphaComponent(0.2).setStroke()
            bgPath.lineWidth = 1
            bgPath.stroke()

            // Icon
            let iconName = firstFile.isDirectory ? "folder.fill" : "doc.fill"
            if let sfImage = NSImage(systemSymbolName: iconName, accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                let configured = sfImage.withSymbolConfiguration(config) ?? sfImage
                let iconRect = NSRect(
                    x: padding,
                    y: (height - iconSize) / 2,
                    width: iconSize,
                    height: iconSize
                )
                if firstFile.isDirectory {
                    NSColor.systemBlue.setFill()
                } else {
                    NSColor(calibratedWhite: 0.85, alpha: 1.0).setFill()
                }
                configured.draw(in: iconRect)
            }

            // Text
            let textX = padding + iconSize + spacing
            let textMaxW = width - textX - padding
            let textRect = NSRect(
                x: textX,
                y: (height - textSize.height) / 2,
                width: textMaxW,
                height: textSize.height
            )
            (title as NSString).draw(
                with: textRect,
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                attributes: attributes
            )

            return true
        }

        return image
    }
}

// MARK: - NSFilePromiseProviderDelegate

extension FileDragManager: NSFilePromiseProviderDelegate {
    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        fileNameForType fileType: String
    ) -> String {
        let name: String
        if let promise = filePromiseProvider as? UnifiedFilePromiseProvider {
            name = promise.file.name
        } else if let file = filePromiseProvider.userInfo as? UnifiedFile {
            name = file.name
        } else {
            name = "file"
        }
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return safeName.isEmpty ? "file" : safeName
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        return Self.promiseOperationQueue
    }

    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let file = (filePromiseProvider as? UnifiedFilePromiseProvider)?.file
                ?? filePromiseProvider.userInfo as? UnifiedFile else {
            completionHandler(NSError(
                domain: "com.androidfilesync.dragdrop",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing file information for promise."]
            ))
            return
        }

        Task {
            do {
                if file.isDirectory {
                    try await Self.downloadFolderPromise(file: file, destinationURL: url)
                } else {
                    try await Self.downloadFilePromise(file: file, destinationURL: url)
                }
                AppLogger.log("✅ Drag to Finder copy completed: \(file.name) → \(url.path)")
                completionHandler(nil)
            } catch {
                AppLogger.log("❌ Drag to Finder copy failed for \(file.name): \(error.localizedDescription)", level: .error)
                completionHandler(error)
            }
        }
    }

    private static func downloadFilePromise(file: UnifiedFile, destinationURL: URL) async throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let manager = await MainActor.run { FileDragManager.shared.downloadManager }
        if let manager = manager {
            try await manager.downloadFile(
                devicePath: file.path,
                fileName: file.name,
                fileSize: file.size,
                to: destinationURL.path
            )
        } else {
            let cleanPath = FileNameHelper.cleanRemotePath(file.path)
            let adbPath = ADBManager.getADBPath()
            let (code, _, err) = await Shell.runAsync(
                adbPath,
                args: ADBManager.deviceArgs(["pull", "-a", cleanPath, destinationURL.path])
            )
            if code != 0 {
                throw NSError(
                    domain: "com.androidfilesync.adb",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "ADB pull failed with code \(code)" : err]
                )
            }
        }
    }

    private static func downloadFolderPromise(file: UnifiedFile, destinationURL: URL) async throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)

        let manager = await MainActor.run { FileDragManager.shared.downloadManager }
        if let manager = manager {
            await manager.downloadFolder(
                devicePath: file.path,
                folderName: file.name,
                to: destinationURL
            )
        } else {
            let cleanPath = FileNameHelper.cleanRemotePath(file.path)
            let adbPath = ADBManager.getADBPath()
            let (code, _, err) = await Shell.runAsync(
                adbPath,
                args: ADBManager.deviceArgs(["pull", "-a", "\(cleanPath)/.", destinationURL.path])
            )
            if code != 0 {
                throw NSError(
                    domain: "com.androidfilesync.adb",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: err.isEmpty ? "ADB folder pull failed with code \(code)" : err]
                )
            }
        }
    }
}
