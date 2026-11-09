//
//  FolderDropDestinationModifier.swift
//  AndroidFileSync
//
//  Drop destination modifiers for folders in Grid, List, Breadcrumbs, and Sidebar.
//

import SwiftUI
import UniformTypeIdentifiers

struct FolderDropDestinationModifier: ViewModifier {
    let targetFolder: UnifiedFile
    let onMoveFiles: (([UnifiedFile], String) -> Void)?
    let onUploadToFolder: (([URL], String) -> Void)?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if targetFolder.isDirectory {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(showHighlight ? Color.accentColor : Color.clear, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(showHighlight ? Color.accentColor.opacity(0.18) : Color.clear)
                        )
                        .allowsHitTesting(false)
                )
                .onDrop(of: [FileDragManager.internalFileUTType, .fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
        } else {
            content
        }
    }

    private var showHighlight: Bool {
        isTargeted && FileDragManager.shared.canDrop(onto: targetFolder)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        // 1. Internal Android files move
        let internalFiles = FileDragManager.shared.draggedFiles
        if !internalFiles.isEmpty {
            guard FileDragManager.shared.canDrop(onto: targetFolder) else { return false }
            onMoveFiles?(internalFiles, targetFolder.path)
            return true
        }

        // 2. External Mac files upload from Finder
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                   let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                onUploadToFolder?(urls, targetFolder.path)
            }
        }
        return true
    }
}

struct FolderPathDropDestinationModifier: ViewModifier {
    let folderPath: String
    let isFolder: Bool
    let onMoveFiles: (([UnifiedFile], String) -> Void)?
    let onUploadToFolder: (([URL], String) -> Void)?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if isFolder {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(showHighlight ? Color.accentColor : Color.clear, lineWidth: 1.5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(showHighlight ? Color.accentColor.opacity(0.14) : Color.clear)
                        )
                        .allowsHitTesting(false)
                )
                .onDrop(of: [FileDragManager.internalFileUTType, .fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
        } else {
            content
        }
    }

    private var showHighlight: Bool {
        isTargeted && FileDragManager.shared.canDrop(onto: folderPath)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let internalFiles = FileDragManager.shared.draggedFiles
        if !internalFiles.isEmpty {
            guard FileDragManager.shared.canDrop(onto: folderPath) else { return false }
            onMoveFiles?(internalFiles, folderPath)
            return true
        }

        Task {
            var urls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                   let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                onUploadToFolder?(urls, folderPath)
            }
        }
        return true
    }
}

struct BreadcrumbDropModifier: ViewModifier {
    let targetPath: String
    let isCurrent: Bool
    let onMoveFiles: (([UnifiedFile], String) -> Void)?
    let onUploadToFolder: (([URL], String) -> Void)?

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if !isCurrent {
            content
                .background(
                    Capsule()
                        .fill(showHighlight ? Color.accentColor.opacity(0.2) : Color.clear)
                        .overlay(
                            Capsule()
                                .stroke(showHighlight ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                )
                .onDrop(of: [FileDragManager.internalFileUTType, .fileURL], isTargeted: $isTargeted) { providers in
                    handleDrop(providers: providers)
                }
        } else {
            content
        }
    }

    private var showHighlight: Bool {
        isTargeted && FileDragManager.shared.canDrop(onto: targetPath)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let internalFiles = FileDragManager.shared.draggedFiles
        if !internalFiles.isEmpty {
            guard FileDragManager.shared.canDrop(onto: targetPath) else { return false }
            onMoveFiles?(internalFiles, targetPath)
            return true
        }

        Task {
            var urls: [URL] = []
            for provider in providers {
                if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                   let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                onUploadToFolder?(urls, targetPath)
            }
        }
        return true
    }
}

extension View {
    func folderDropTarget(
        folder: UnifiedFile,
        onMoveFiles: (([UnifiedFile], String) -> Void)?,
        onUploadToFolder: (([URL], String) -> Void)?
    ) -> some View {
        self.modifier(FolderDropDestinationModifier(
            targetFolder: folder,
            onMoveFiles: onMoveFiles,
            onUploadToFolder: onUploadToFolder
        ))
    }

    func folderDropTarget(
        folderPath: String,
        isFolder: Bool,
        onMoveFiles: (([UnifiedFile], String) -> Void)?,
        onUploadToFolder: (([URL], String) -> Void)?
    ) -> some View {
        self.modifier(FolderPathDropDestinationModifier(
            folderPath: folderPath,
            isFolder: isFolder,
            onMoveFiles: onMoveFiles,
            onUploadToFolder: onUploadToFolder
        ))
    }

    func breadcrumbDropTarget(
        path: String,
        isCurrent: Bool,
        onMoveFiles: (([UnifiedFile], String) -> Void)?,
        onUploadToFolder: (([URL], String) -> Void)?
    ) -> some View {
        self.modifier(BreadcrumbDropModifier(
            targetPath: path,
            isCurrent: isCurrent,
            onMoveFiles: onMoveFiles,
            onUploadToFolder: onUploadToFolder
        ))
    }
}
