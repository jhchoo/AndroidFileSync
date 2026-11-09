//
//  FileDragManager.swift
//  AndroidFileSync
//
//  Created for AndroidFileSync.
//  Manages drag-and-drop operations for moving files into folders.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
internal import Combine

@MainActor
final class FileDragManager: NSObject, ObservableObject, NSDraggingSource {
    static let shared = FileDragManager()

    static let internalFileUTI = "com.androidfilesync.internalfile"
    static let internalFileUTType = UTType(exportedAs: internalFileUTI, conformingTo: .data)

    @Published private(set) var draggedFiles: [UnifiedFile] = []
    @Published private(set) var isDragging: Bool = false

    func startDrag(with files: [UnifiedFile], from view: NSView, event: NSEvent) {
        guard !files.isEmpty else { return }
        self.draggedFiles = files
        self.isDragging = true

        let pbItem = NSPasteboardItem()
        let paths = files.map(\.path)
        if let jsonData = try? JSONEncoder().encode(paths),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            pbItem.setString(jsonString, forType: NSPasteboard.PasteboardType(Self.internalFileUTI))
        }
        pbItem.setString(paths.joined(separator: "\n"), forType: .string)

        let dragItem = NSDraggingItem(pasteboardWriter: pbItem)
        let image = Self.createDragImage(for: files)
        let mouseInView = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: mouseInView.x - 24,
            y: mouseInView.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        dragItem.setDraggingFrame(frame, contents: image)

        view.beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func clearDrag() {
        self.draggedFiles = []
        self.isDragging = false
    }

    // MARK: - NSDraggingSource

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .move
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
