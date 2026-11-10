//
//  FileBrowserView.swift
//  AndroidFileSync
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - View Mode

enum FileBrowserViewMode: String, CaseIterable {
    case list = "list"
    case tiles = "tiles"

    var icon: String {
        switch self {
        case .list:  return "list.bullet"
        case .tiles: return "square.grid.2x2"
        }
    }

    var label: String {
        switch self {
        case .list:  return "List"
        case .tiles: return "Tiles"
        }
    }
}

struct FileBrowserView: View {
    let files: [UnifiedFile]
    let currentPath: String
    let isLoading: Bool
    let canGoBack: Bool
    @Binding var selectedFiles: Set<String>
    let onNavigate: (String) -> Void
    let onGoBack: () -> Void
    let onDownload: (UnifiedFile) -> Void
    let onUpload: ([URL]) -> Void
    let onDelete: ((UnifiedFile) -> Void)?
    let onRename: ((UnifiedFile, String) -> Void)?
    var onPreview: ((UnifiedFile) -> Void)? = nil
    var isPerformingAction: Bool = false
    var currentActionText: String = ""
    /// Called when the user taps the Stop button during an ongoing operation
    var onCancelAction: (() -> Void)? = nil
    let onBatchDelete: (() -> Void)?
    let onBatchDownload: (() -> Void)?
    let onBatchChangeExtension: ((String) -> Void)?
    var onCopy: (([UnifiedFile]) -> Void)? = nil
    var onCut: (([UnifiedFile]) -> Void)? = nil
    var onDownloadFolder: ((UnifiedFile) -> Void)? = nil
    /// Called when the user chooses "Add to Sidebar" from the folder context menu
    var onAddToSidebar: ((UnifiedFile) -> Void)? = nil
    /// Called when the user chooses "Delete Permanently" from the selection toolbar
    var onPermanentDelete: (() -> Void)? = nil
    var onPermanentDeleteFiles: (([UnifiedFile]) -> Void)? = nil
    
    // Clipboard support
    var clipboardCount: Int = 0
    var clipboardOperation: FileActionManager.ClipboardOperation = .none
    var onPaste: (() -> Void)? = nil
    var onPasteToFolder: ((String) -> Void)? = nil
    var onNewFolder: (() -> Void)? = nil
    var onClearClipboard: (() -> Void)? = nil
    
    // Drag and drop move support
    var onMoveFiles: (([UnifiedFile], String) -> Void)? = nil
    var onUploadToFolder: (([URL], String) -> Void)? = nil
    
    // Deletion support
    var activeDeletions: [LiveDeletion] = []
    var onCancelDeletion: ((UUID) -> Void)? = nil
    var onCancelAllDeletions: (() -> Void)? = nil
    
    // Sorting support
    var sortOption: ActionToolbar.SortOption = .name
    var sortAscending: Bool = true
    /// Monotonically increasing counter — incremented every time ContentView re-sorts.
    /// Rebuilds the native table when the displayed order changes.
    var sortVersion: Int = 0
    var onSortChange: ((ActionToolbar.SortOption, Bool) -> Void)? = nil
    
    // Folder sizes fetched asynchronously — keyed by folder path
    var folderSizes: [String: UInt64] = [:]
    
    // Metadata loading progress (for large directories)
    var isLoadingMetadata: Bool = false
    var metadataLoadedCount: Int = 0
    var metadataTotalCount: Int = 0
    
    // Progressive loading (paginated content:// fallback)
    var isLoadingMoreFiles: Bool = false
    
    // Thumbnail provider for inline file thumbnails
    var thumbnailProvider: ThumbnailProvider? = nil
    var isInteractionEnabled: Bool = true
    var isDualPane: Bool = false
    var onToggleDualPane: (() -> Void)? = nil
    var isActivePane: Bool = false
    
    // View mode toggle (list vs tiles)
    @AppStorage("fileBrowserViewMode") private var viewMode: FileBrowserViewMode = .list

    // Guard against re-entrant sort loop:
    // Column header click → onChange(sortOrder) → onSortChange → ContentView updates displayedFiles
    // → Table re-renders → could trigger onChange(sortOrder) again.
    @State private var isSyncingSortOrder = false
    
    // Deletion Popover States
    @State private var showDeletionPopover = false
    @State private var dismissTask: Task<Void, Never>? = nil
    
    // Table sort state — derived from sortOption/sortAscending props so it survives
    // Table rebuilds from .id(sortVersion). Using @State would reset on rebuild.
    @State private var sortOrder: [KeyPathComparator<UnifiedFile>] = [
        .init(\.name, order: .forward)
    ]
    
    /// Compute the expected sortOrder from current sortOption + sortAscending.
    private var expectedSortOrder: [KeyPathComparator<UnifiedFile>] {
        let order: SortOrder = sortAscending ? .forward : .reverse
        switch sortOption {
        case .name: return [.init(\.name, order: order)]
        case .size: return [.init(\.size, order: order)]
        case .date: return [.init(\.sortableDate, order: order)]
        case .type: return [.init(\.sortableType, order: order)]
        }
    }
    
    // Drag-and-drop visual feedback
    @State private var isDraggingOver = false
    @State private var selectionNavigator = FileSelectionNavigator()
    @State private var gridItemFrames: [String: CGRect] = [:]
    @State private var marqueeRectangle: CGRect?
    
    // Delete confirmation state
    @State private var showDeleteConfirmation = false
    @State private var fileToDelete: UnifiedFile? = nil
    @State private var showBatchDeleteConfirmation = false
    @State private var batchDeleteCount = 0
    @State private var showPermanentDeleteConfirmation = false
    @State private var filesToPermanentlyDelete: [UnifiedFile] = []

    // Change extension state (for context menu)
    @State private var showExtensionDialog = false
    @State private var newExtension = ""
    
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            fileListOrEmptyState
            
            // Selection toolbar - only show when there are selected files in current view
            let selectedFilesList = selectedFiles.isEmpty ? [] : files.filter { selectedFiles.contains($0.id) }
            if !selectedFilesList.isEmpty {
                SelectionToolbar(
                    selectedFiles: selectedFilesList,
                    onClearSelection: { selectedFiles.removeAll() },
                    onDelete: { onBatchDelete?() },
                    onDownload: { onBatchDownload?() },
                    onRename: onRename,
                    onChangeExtension: onBatchChangeExtension,
                    onPermanentDelete: onPermanentDelete
                )
            }
        }
        .overlay(alignment: .top) {
            if isDualPane {
                Rectangle()
                    .fill(isActivePane ? Color.accentColor : Color.clear)
                    .frame(height: 2.5)
            }
        }
        .onChange(of: currentPath) { _ in
            selectionNavigator = FileSelectionNavigator()
        }
        .alert("Move \(fileToDelete?.name ?? "item") to Trash?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                fileToDelete = nil
            }
            Button("Move to Trash", role: .destructive) {
                if let file = fileToDelete {
                    onDelete?(file)
                }
                fileToDelete = nil
            }
        } message: {
            Text("You can restore this item from the Trash.")
        }
        // Change extension alert (no pre-fill needed, so SwiftUI alert works fine here)
        .alert("Change Extension", isPresented: $showExtensionDialog) {
            TextField("New Extension", text: $newExtension)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {
                newExtension = ""
            }
            Button("Change") {
                if !newExtension.isEmpty {
                    onBatchChangeExtension?(newExtension)
                }
                newExtension = ""
            }
        } message: {
            Text("Enter new extension (e.g. txt, jpg) for \(selectedFiles.count) files.")
        }
        // Batch delete confirmation alert
        .alert("Move \(batchDeleteCount) items to Trash?", isPresented: $showBatchDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                batchDeleteCount = 0
            }
            Button("Move to Trash", role: .destructive) {
                onBatchDelete?()
                batchDeleteCount = 0
            }
        } message: {
            Text("You can restore these items from the Trash.")
        }
        // Permanent delete confirmation alert
        .alert(
            filesToPermanentlyDelete.count <= 1
                ? "Permanently delete \(filesToPermanentlyDelete.first?.name ?? "item")?"
                : "Permanently delete \(filesToPermanentlyDelete.count) items?",
            isPresented: $showPermanentDeleteConfirmation
        ) {
            Button("Cancel", role: .cancel) {
                filesToPermanentlyDelete = []
            }
            Button("Delete Permanently", role: .destructive) {
                let targets = filesToPermanentlyDelete
                filesToPermanentlyDelete = []
                if let onPermanentDeleteFiles {
                    onPermanentDeleteFiles(targets)
                } else {
                    onPermanentDelete?()
                }
            }
        } message: {
            Text("This cannot be undone. The item\(filesToPermanentlyDelete.count == 1 ? " will" : "s will") be permanently removed from the device.")
        }
    }
    
    // MARK: - View Components
    
    private var pathBar: some View {
        HStack(spacing: 0) {
            // Back button
            if canGoBack {
                Button(action: onGoBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go back")
                .padding(.trailing, 2)
            }
            
            // Breadcrumb path
            breadcrumbPath
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()

            HStack(spacing: 8) {
                clipboardStatus
                inlineActionStatus
            }
            
            // Item count
            if isLoading {
                LoadingSpinner()
            } else if isLoadingMoreFiles {
                HStack(spacing: 4) {
                    LoadingSpinner()
                    Text("\(files.count) items")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .help("Loading more files from MediaStore...")
            } else if isLoadingMetadata {
                HStack(spacing: 4) {
                    LoadingSpinner()
                    Text("\(metadataLoadedCount)/\(metadataTotalCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .help("Loading file details...")
            } else {
                Text(files.count == 1 ? "1 item" : "\(files.count) items")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .fixedSize()
            }

            selectionMenu
            
            Divider().frame(height: 16).padding(.horizontal, 10)
            
            // View mode toggle — List / Tiles
            viewModeToggle

            // Dual pane toggle button
            if let onToggleDualPane = onToggleDualPane {
                Divider().frame(height: 16).padding(.horizontal, 4)

                Button(action: onToggleDualPane) {
                    Image(systemName: isDualPane ? "square.split.2x1.fill" : "square.split.2x1")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(isDualPane ? .accentColor : .secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isDualPane ? "Single pane view" : "Dual pane (2-split) view")
            }

            Divider().frame(height: 16).padding(.horizontal, 4)

            // Upload button — accent-tinted, non-intrusive Apple style
            Button(action: showUploadDialog) {
                Label("Upload to Android", systemImage: "arrow.up.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.accentColor)
            .fixedSize()
            .help("Upload files to this folder")
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
    
    // MARK: - Breadcrumb Navigation

    struct BreadcrumbItem: Identifiable, Equatable {
        var id: String { path }
        let name: String
        let path: String
        let isCurrent: Bool
    }

    private var breadcrumbItems: [BreadcrumbItem] {
        let root = deviceStorageRoot
        let current = currentPath

        var items: [BreadcrumbItem] = []

        if current == root || current == root + "/" {
            items.append(BreadcrumbItem(name: "Internal Storage", path: root, isCurrent: true))
            return items
        }

        if current.hasPrefix(root) {
            items.append(BreadcrumbItem(name: "Internal Storage", path: root, isCurrent: false))
            let relative = current.dropFirst(root.count)
            let rawParts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            var accumulated = root
            for (idx, part) in rawParts.enumerated() {
                accumulated += "/" + part
                let isLast = (idx == rawParts.count - 1)
                items.append(BreadcrumbItem(name: part, path: accumulated, isCurrent: isLast))
            }
        } else {
            // Path outside standard storage root (e.g. /sdcard alias, /data/local/tmp, or custom root)
            let parts = current.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            if parts.isEmpty {
                items.append(BreadcrumbItem(name: "/", path: "/", isCurrent: true))
            } else {
                var accumulated = ""
                for (idx, part) in parts.enumerated() {
                    accumulated += "/" + part
                    let isLast = (idx == parts.count - 1)
                    items.append(BreadcrumbItem(name: part, path: accumulated, isCurrent: isLast))
                }
            }
        }

        return items
    }

    // Breadcrumb segments built from current path
    private var breadcrumbPath: some View {
        let allItems = breadcrumbItems

        return HStack(spacing: 3) {
            if allItems.isEmpty {
                Text("/")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else if allItems.count > 4 {
                // Deep path: first > … (dropdown menu) > parent > current
                let first = allItems[0]
                let hidden = Array(allItems[1..<(allItems.count - 2)])
                let parent = allItems[allItems.count - 2]
                let current = allItems[allItems.count - 1]

                // 1. Root / First item
                breadcrumbSegmentView(item: first)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))

                // 2. Collapsed menu for middle segments
                Menu {
                    ForEach(hidden) { item in
                        Button(item.name) {
                            onNavigate(item.path)
                        }
                    }
                } label: {
                    Text("…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.05))
                        )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Show intermediate folders")

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))

                // 3. Parent item
                breadcrumbSegmentView(item: parent)

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))

                // 4. Current folder
                breadcrumbSegmentView(item: current)
            } else {
                // 4 or fewer segments: show all directly
                ForEach(Array(allItems.enumerated()), id: \.offset) { index, item in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(Color(NSColor.tertiaryLabelColor))
                    }
                    breadcrumbSegmentView(item: item)
                }
            }
        }
    }

    @ViewBuilder
    private func breadcrumbSegmentView(item: BreadcrumbItem) -> some View {
        if item.isCurrent {
            Text(item.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            BreadcrumbButton(title: item.name) {
                onNavigate(item.path)
            }
            .breadcrumbDropTarget(path: item.path, isCurrent: item.isCurrent, onMoveFiles: onMoveFiles, onUploadToFolder: onUploadToFolder)
        }
    }

    private var deviceStorageRoot: String {
        // Keep resolved aliases out of the user-facing breadcrumb.
        AndroidStorageAccess.storageRoot(for: currentPath) ?? "/storage/emulated/0"
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        if isLoading {
            LoadingSpinner()
        } else {
            Text("\(files.count) items")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var inlineActionAccentColor: Color {
        let action = currentActionText.lowercased()
        if action.contains("delete") || action.contains("deleting") || action.contains("trash") { return .red }
        if action.contains("restore") { return .green }
        if action.contains("rename") { return .blue }
        if action.contains("paste") || action.contains("pasting") ||
            action.contains("copy") || action.contains("copying") ||
            action.contains("move") || action.contains("moving") ||
            action.contains("cut") || action.contains("cutting") {
            return .orange
        }
        return .secondary
    }

    private var inlineActionStatus: some View {
        HStack(spacing: 6) {
            if isPerformingAction {
                LoadingSpinner(size: 12, color: inlineActionAccentColor)
                Text(currentActionText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(inlineActionAccentColor.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 156, alignment: currentActionText.count > 18 ? .leading : .center)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 6)
                    .background(
                        Capsule()
                            .fill(inlineActionAccentColor.opacity(0.08))
                    )
                    .onHover { hovering in
                        if isDeletionAction {
                            updateHoverState(isHovering: hovering)
                        }
                    }
                    .popover(isPresented: $showDeletionPopover, arrowEdge: .bottom) {
                        deletionDetailsPopover
                    }
                
                // Stop button
                if onCancelAction != nil {
                    Button {
                        onCancelAction?()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Stop operation")
                }
            }
        }
        .frame(width: isPerformingAction ? 250 : 0, alignment: .trailing)
        .clipped()
        .padding(.trailing, isPerformingAction ? 10 : 0)
    }
    
    private var isDeletionAction: Bool {
        let action = currentActionText.lowercased()
        return action.contains("delete") || action.contains("deleting") || action.contains("trash")
    }
    
    private func updateHoverState(isHovering: Bool) {
        if isHovering {
            dismissTask?.cancel()
            dismissTask = nil
            showDeletionPopover = true
        } else {
            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                if !Task.isCancelled {
                    showDeletionPopover = false
                }
            }
        }
    }
    
    private var deletionDetailsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Deletion Progress")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 4)
            
            let deletions = activeDeletions.filter { !$0.isComplete }
            if deletions.isEmpty {
                Text("No active deletions")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(deletions) { deletion in
                            HStack(spacing: 8) {
                                Image(systemName: deletion.isPermanent ? "trash.slash.fill" : "trash.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 11))
                                
                                Text(deletion.fileName)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 160, alignment: .leading)
                                
                                Spacer()
                                
                                if deletion.isRunning {
                                    LoadingSpinner(size: 10)
                                } else {
                                    Text("Pending")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                
                                Button {
                                    onCancelDeletion?(deletion.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
                
                Divider()
                
                Button(role: .destructive) {
                    onCancelAllDeletions?()
                    showDeletionPopover = false
                } label: {
                    Text("Cancel All Deletions")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 250)
        .onHover { hovering in
            updateHoverState(isHovering: hovering)
        }
    }
    
    private var clipboardStatus: some View {
        HStack(spacing: 4) {
            if clipboardCount > 0 && !isPerformingAction {
                HStack(spacing: 6) {
             
                    Button {
                        onPaste?()
                    } label: {
                        HStack(spacing: 2) {
                         
                            Image(systemName: clipboardOperation == .cut ? "scissors" : "doc.on.clipboard")
                        .font(.system(size: 10))
                        .foregroundColor(.blue)
                    
                    Text("\(clipboardCount) ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.blue.opacity(0.85))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.borderless)
                    
                    Button {
                        onClearClipboard?()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(
                    Capsule()
                        .fill(Color.blue.opacity(0.08))
                )
            }
        }
    }
    
    // MARK: - View Mode Toggle

    private var allFilesSelected: Bool {
        !files.isEmpty && selectedFiles.count >= files.count && files.allSatisfy { selectedFiles.contains($0.id) }
    }

    private var selectionMenu: some View {
        Menu {
            Button {
                selectedFiles = Set(files.map(\.id))
            } label: {
                Label("Select All", systemImage: "checkmark.circle")
            }
            .disabled(files.isEmpty || allFilesSelected)

            Button {
                selectedFiles.removeAll()
            } label: {
                Label("Deselect All", systemImage: "xmark.circle")
            }
            .disabled(selectedFiles.isEmpty)
        } label: {
            Image(systemName: selectedFiles.isEmpty ? "checkmark.circle" : "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(selectedFiles.isEmpty ? Color.secondary : Color.accentColor)
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Selection options")
        .accessibilityLabel("Selection options")
    }

    private var viewModeToggle: some View {
        HStack(spacing: 2) {
            ForEach(FileBrowserViewMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewMode = mode
                    }
                } label: {
                    Image(systemName: mode.icon)
                        .font(.system(size: 12, weight: viewMode == mode ? .semibold : .regular))
                        .foregroundColor(viewMode == mode ? .accentColor : .secondary)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(viewMode == mode ? Color.accentColor.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(mode.label)
                .accessibilityLabel("\(mode.label) view")
                .accessibilityValue(viewMode == mode ? "Selected" : "")
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    @ViewBuilder
    private var fileListOrEmptyState: some View {
        ZStack {
            if files.isEmpty && !isLoading {
                emptyFolderView
            } else {
                switch viewMode {
                case .list:
                    fileList
                case .tiles:
                    fileGridView
                }
            }

            if shouldShowDropOverlay {
                dropOverlay
            }
        }
        .onDrop(of: [FileDragManager.internalFileUTType, .fileURL], isTargeted: $isDraggingOver) { providers in
            // 1. Internal Android files move (from another pane)
            let internalFiles = FileDragManager.shared.draggedFiles
            if !internalFiles.isEmpty {
                guard FileDragManager.shared.canDrop(onto: currentPath) else { return false }
                onMoveFiles?(internalFiles, currentPath)
                return true
            }

            // 2. External Mac files upload from Finder
            Task {
                var urls: [URL] = []
                for provider in providers {
                    do {
                        let item = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier)
                        if let url = item as? URL {
                            urls.append(url)
                        } else if let data = item as? Data,
                                  let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                    } catch {
                        print("⚠️ Failed to load dropped item: \(error)")
                    }
                }
                
                if !urls.isEmpty {
                    await MainActor.run {
                        onUpload(urls)
                    }
                }
            }
            return true
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
    
    private func handleDeleteShortcut() {
        let items = files.filter { selectedFiles.contains($0.id) }
        guard !items.isEmpty else { return }

        if items.count == 1 {
            fileToDelete = items.first
            showDeleteConfirmation = true
        } else {
            batchDeleteCount = items.count
            showBatchDeleteConfirmation = true
        }
    }

    private func handleClick(_ index: Int?, modifiers: NSEvent.ModifierFlags) {
        guard let index, files.indices.contains(index) else {
            if modifiers.intersection([.command, .shift]).isEmpty {
                selectedFiles.removeAll()
                selectionNavigator = FileSelectionNavigator()
            }
            return
        }
        selectedFiles = selectionNavigator.select(
            files[index].id, in: files.map(\.id), selection: selectedFiles,
            extending: modifiers.contains(.shift), toggling: modifiers.contains(.command)
        )
    }

    private func handleOpen(_ index: Int) {
        guard files.indices.contains(index) else { return }
        let file = files[index]
        if file.isDirectory { onNavigate(file.path) }
        else if FilePreviewManager.isPreviewable(file) { onPreview?(file) }
        else { onDownload(file) }
    }

    private func handleSpaceAction() {
        guard let singleId = selectedFiles.count == 1 ? selectedFiles.first : nil,
              let file = files.first(where: { $0.id == singleId }) else { return }
        if file.isDirectory {
            onNavigate(file.path)
        } else if FilePreviewManager.isPreviewable(file) {
            onPreview?(file)
        }
    }

    private func handleRenameSelection() {
        guard let onRename = onRename else { return }
        let selected = files.filter { selectedFiles.contains($0.id) }
        guard selected.count == 1, let file = selected.first else { return }
        let kind = file.isDirectory ? "Folder" : "File"
        if let newName = TextInputDialog.show(
            title: "Rename \(kind)",
            message: "Enter a new name for \"\(file.name)\"",
            placeholder: file.name,
            initialValue: file.name,
            confirmLabel: "Rename"
        ), newName != file.name {
            onRename(file, newName)
        }
    }

    private func handleMarquee(_ indexes: Set<Int>, anchor: Int?, focus: Int?) {
        selectedFiles = Set(indexes.filter { files.indices.contains($0) }.map { files[$0].id })
        selectionNavigator.setMarqueeSelection(
            selectedFiles,
            anchorID: anchor.flatMap { files.indices.contains($0) ? files[$0].id : nil },
            focusedID: focus.flatMap { files.indices.contains($0) ? files[$0].id : nil }
        )
    }

    private func keyboardNavigation(isGrid: Bool, columns: Int = 1,
                                    frames: [String: CGRect] = [:], selectedIDs: Set<String>? = nil,
                                    scrollTo: ((String) -> Void)? = nil) -> some View {
        let selection = selectedIDs ?? selectedFiles
        let mappedFrames: [Int: CGRect] = (isGrid && !frames.isEmpty)
            ? Dictionary(uniqueKeysWithValues: files.enumerated().compactMap { index, file in
                frames[file.id].map { (index, $0) }
            })
            : [:]
        let selectedIdxSet: Set<Int> = selection.isEmpty
            ? []
            : Set(files.indices.filter { selection.contains(files[$0].id) })
        return FileBrowserKeyboardNavigation(isGrid: isGrid, onMove: { direction, flags in
            let index = handleSelectionMove(direction, modifiers: flags, columns: columns)
            if let index { scrollTo?(files[index].id) }
            return index
        }, itemFrames: mappedFrames, selectedIndexes: selectedIdxSet,
            isEnabled: isInteractionEnabled, onClick: handleClick, onOpen: handleOpen,
            onRename: handleRenameSelection,
            onSpace: handleSpaceAction,
            onDrag: handleMarquee, onMarqueeChange: { marqueeRectangle = $0 },
            onItemDrag: { indexes, event, view in
                let filesToDrag = indexes.sorted().compactMap { files.indices.contains($0) ? files[$0] : nil }
                guard !filesToDrag.isEmpty else { return }
                FileDragManager.shared.startDrag(with: filesToDrag, from: view, event: event)
            })
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let rectangle = marqueeRectangle {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.75), lineWidth: 1))
                .frame(width: rectangle.width, height: rectangle.height)
                .offset(x: rectangle.minX, y: rectangle.minY)
                .allowsHitTesting(false)
        }
    }

    @discardableResult
    private func handleSelectionMove(_ direction: MoveCommandDirection,
                                     modifiers: NSEvent.ModifierFlags, columns: Int = 1) -> Int? {
        let offset: Int
        switch direction {
        case .up: offset = -columns
        case .down: offset = columns
        case .left where viewMode == .tiles: offset = -1
        case .right where viewMode == .tiles: offset = 1
        default: return nil
        }
        selectedFiles = selectionNavigator.move(
            by: offset, in: files.map(\.id), selection: selectedFiles,
            extending: modifiers.contains(.shift)
        )
        return files.firstIndex { $0.id == selectionNavigator.focusedID }
    }

    private var emptyFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: isDraggingOver ? "arrow.down.doc.fill" : "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(isDraggingOver ? .blue : .secondary)
            
            Text(isDraggingOver ? "Drop files to upload" : "Folder is empty")
                .foregroundColor(isDraggingOver ? .blue : .secondary)
            
            if !isDraggingOver {
                Text("Drag files here or click the Upload button")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .contextMenu {
            emptyAreaContextMenu
        }
    }
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Grid / Tiles View

    private var fileGridView: some View {
        let frames = gridItemFrames
        let selection = selectedFiles
        let columns = [GridItem(.adaptive(minimum: 98, maximum: 126), spacing: 10)]

        return GeometryReader { geometry in
            let columnCount = max(1, Int((geometry.size.width - 32 + 10) / (98 + 10)))
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(files) { file in
                            FileTileView(
                                file: file,
                                isSelected: selectedFiles.contains(file.id),
                                thumbnailProvider: thumbnailProvider,
                                fallbackIcon: getFileIcon(for: file),
                                fallbackColor: getFileColor(for: file),
                                detailText: tileDetailText(for: file)
                            )
                            .folderDropTarget(folder: file, onMoveFiles: onMoveFiles, onUploadToFolder: onUploadToFolder)
                            .background(
                                GeometryReader { itemGeometry in
                                    Color.clear.preference(key: FileBrowserItemFrames.self, value: [
                                        file.id: itemGeometry.frame(in: .named("fileBrowserGrid"))
                                    ])
                                }
                            )
                            .contextMenu {
                                fileContextMenu(for: file)
                            }
                            .id(file.id)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .scrollContentBackground(.hidden)
                .coordinateSpace(name: "fileBrowserGrid")
                .onPreferenceChange(FileBrowserItemFrames.self) { newFrames in
                    if gridItemFrames != newFrames {
                        gridItemFrames = newFrames
                    }
                }
                .background(
                    keyboardNavigation(isGrid: true, columns: columnCount, frames: frames, selectedIDs: selection, scrollTo: { proxy.scrollTo($0) })
                )
                .overlay(alignment: .topLeading) { marqueeOverlay }
                .contextMenu {
                    emptyAreaContextMenu
                }
            }
        }
    }

    private var fileList: some View {
        Table(files, selection: $selectedFiles, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 8) {
                    if let provider = thumbnailProvider {
                        FileThumbnailView(
                            file: file,
                            thumbnailProvider: provider,
                            fallbackIcon: getFileIcon(for: file),
                            fallbackColor: getFileColor(for: file)
                        )
                        .frame(width: 26, height: 26)
                    } else if file.isDirectory {
                        CategorizedFolderIcon(folderName: file.name, size: 26)
                    } else {
                        Image(systemName: getFileIcon(for: file))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(getFileColor(for: file))
                            .font(.system(size: 15))
                            .frame(width: 26, height: 26)
                    }
                    Text(file.name)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .folderDropTarget(folder: file, onMoveFiles: onMoveFiles, onUploadToFolder: onUploadToFolder)
            }
            
            TableColumn("Size", value: \.size) { file in
                sizeColumnContent(for: file)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .folderDropTarget(folder: file, onMoveFiles: onMoveFiles, onUploadToFolder: onUploadToFolder)
            }
            .width(min: 70, ideal: 90, max: 110)
            
            TableColumn("Date", value: \.sortableDate) { file in
                dateColumnContent(for: file)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .folderDropTarget(folder: file, onMoveFiles: onMoveFiles, onUploadToFolder: onUploadToFolder)
            }
            .width(min: 160, ideal: 170, max: 200)
            
            TableColumn("Type", value: \.sortableType) { file in
                Text(file.isDirectory ? "Folder" : getFileType(for: file))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .folderDropTarget(folder: file, onMoveFiles: onMoveFiles, onUploadToFolder: onUploadToFolder)
            }
            // No .width() — fills remaining space, eliminates trailing column separator
        }
        .id(sortVersion) // Force Table rebuild when sort changes — SwiftUI Table won't re-order rows otherwise
        .tableStyle(InsetTableStyle(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(keyboardNavigation(isGrid: false))
        .overlay(alignment: .topLeading) { marqueeOverlay }
        .onAppear {
            // Sync sortOrder when Table is (re)created by .id(sortVersion)
            isSyncingSortOrder = true
            sortOrder = expectedSortOrder
            DispatchQueue.main.async { isSyncingSortOrder = false }
        }
        .onChange(of: sortOrder) { newOrder in
            // Column header was clicked → extract sort params → tell ContentView
            guard !isSyncingSortOrder else { return }
            guard let first = newOrder.first else { return }
            
            isSyncingSortOrder = true
            let ascending = first.order == .forward
            if first.keyPath == \UnifiedFile.name { onSortChange?(.name, ascending) }
            else if first.keyPath == \UnifiedFile.size { onSortChange?(.size, ascending) }
            else if first.keyPath == \UnifiedFile.sortableDate { onSortChange?(.date, ascending) }
            else if first.keyPath == \UnifiedFile.sortableType { onSortChange?(.type, ascending) }
            
            DispatchQueue.main.async { isSyncingSortOrder = false }
        }
        // Use contextMenu with primaryAction for double-click - this is the macOS-native approach
                // that works with selection (macOS 13+)
                .contextMenu(forSelectionType: String.self, menu: { selectedIds in
                    if selectedIds.isEmpty {
                        emptyAreaContextMenu
                    } else {
                        // Context menu for selected items
                        let selectedItems = files.filter { selectedIds.contains($0.id) }
                        let isSingleSelection = selectedIds.count <= 1
                        let hasOnlyFiles = !selectedItems.isEmpty && selectedItems.allSatisfy { !$0.isDirectory }
                        
                        if let firstItem = selectedItems.first {
                            // Preview option (for single previewable files)
                            if isSingleSelection && !firstItem.isDirectory && FilePreviewManager.isPreviewable(firstItem) {
                                Button {
                                    onPreview?(firstItem)
                                } label: {
                                    Label("Preview", systemImage: "eye")
                                }
                                Divider()
                            }
                            
                            // Download
                            if !firstItem.isDirectory || !isSingleSelection {
                                Button(isSingleSelection ? "Download to Mac" : "Download Selected to Mac") {
                                    if isSingleSelection, let file = selectedItems.first, !file.isDirectory {
                                        onDownload(file)
                                    } else {
                                        onBatchDownload?()
                                    }
                                }
                                Divider()
                            }
                            
                            // Folder download option
                            if isSingleSelection && firstItem.isDirectory {
                                Button {
                                    onDownloadFolder?(firstItem)
                                } label: {
                                    Label("Download Folder to Mac", systemImage: "folder.badge.gearshape")
                                }

                                // ── Add to Sidebar ──────────────────────────────
                                Button {
                                    onAddToSidebar?(firstItem)
                                } label: {
                                    Label("Add to Sidebar", systemImage: "sidebar.left")
                                }

                                Divider()
                            }
                            
                            // Copy
                            Button(isSingleSelection ? "Copy" : "Copy \(selectedIds.count) items") {
                                let items = isSingleSelection ? [firstItem] : selectedItems
                                onCopy?(items)
                            }
                            
                            // Cut
                            Button(isSingleSelection ? "Cut" : "Cut \(selectedIds.count) items") {
                                let items = isSingleSelection ? [firstItem] : selectedItems
                                onCut?(items)
                            }
                            
                            // Paste into Folder (if a single directory is selected)
                            if isSingleSelection && firstItem.isDirectory && clipboardCount > 0 && onPasteToFolder != nil {
                                Button {
                                    onPasteToFolder?(firstItem.path)
                                } label: {
                                    Label(
                                        "Paste into \"\(firstItem.name)\"",
                                        systemImage: clipboardOperation == .cut ? "scissors" : "doc.on.clipboard"
                                    )
                                }
                            }
                            
                            // Paste Here
                            if clipboardCount > 0 {
                                Button {
                                    onPaste?()
                                } label: {
                                    Label(pasteMenuTitle, systemImage: clipboardOperation == .cut ? "scissors" : "doc.on.clipboard")
                                }
                                .disabled(onPaste == nil)
                            }
                            
                            Divider()
                        
                        // Rename - only for single selection
                        if isSingleSelection {
                            Button("Rename") {
                                let kind = firstItem.isDirectory ? "Folder" : "File"
                                if let newName = TextInputDialog.show(
                                    title: "Rename \(kind)",
                                    message: "Enter a new name for \"\(firstItem.name)\"",
                                    placeholder: firstItem.name,
                                    initialValue: firstItem.name,
                                    confirmLabel: "Rename"
                                ), newName != firstItem.name {
                                    onRename?(firstItem, newName)
                                }
                            }
                            .disabled(onRename == nil)
                        }
                        
                        // Change Extension - only for multiple files (no folders)
                        if selectedIds.count > 1 && hasOnlyFiles {
                            Button("Change Extension...") {
                                showExtensionDialog = true
                            }
                            .disabled(onBatchChangeExtension == nil)
                        }
                        
                        // Move to Trash
                        Button(isSingleSelection ? "Move to Trash" : "Move \(selectedIds.count) items to Trash", role: .destructive) {
                            if isSingleSelection {
                                fileToDelete = firstItem
                                showDeleteConfirmation = true
                            } else {
                                batchDeleteCount = selectedIds.count
                                showBatchDeleteConfirmation = true
                            }
                        }

                        // 완전 삭제
                        Button(isSingleSelection ? "완전 삭제" : "\(selectedIds.count)개 항목 완전 삭제", role: .destructive) {
                            filesToPermanentlyDelete = selectedItems
                            showPermanentDeleteConfirmation = true
                        }
                    }
                    }
                }, primaryAction: { selectedIds in
                    // Double-click action
                    if let firstId = selectedIds.first,
                       let file = files.first(where: { $0.id == firstId }) {
                        if file.isDirectory {
                            onNavigate(file.path)
                        } else if FilePreviewManager.isPreviewable(file) {
                            onPreview?(file)
                        } else {
                            onDownload(file)
                        }
                    }
                })
    }
    
    @ViewBuilder
    private func fileContextMenu(for file: UnifiedFile) -> some View {
        // A secondary-click on an unselected tile targets that tile, rather
        // than accidentally applying actions to a previous selection.
        let targetIDs: Set<String> = selectedFiles.contains(file.id) ? selectedFiles : [file.id]
        let selectedItems = files.filter { targetIDs.contains($0.id) }
        let isSingleSelection = targetIDs.count == 1
        let hasOnlyFiles = !selectedItems.isEmpty && selectedItems.allSatisfy { !$0.isDirectory }

        if isSingleSelection && !file.isDirectory && FilePreviewManager.isPreviewable(file) {
            Button {
                onPreview?(file)
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Divider()
        }
        
        // Batch download remains available for a mixed selection.
        if !file.isDirectory || !isSingleSelection {
            Button(isSingleSelection ? "Download to Mac" : "Download Selected to Mac") {
                if isSingleSelection {
                    onDownload(file)
                } else {
                    onBatchDownload?()
                }
            }
            Divider()
        }
        
        // Download folder
        if file.isDirectory && isSingleSelection {
            Button {
                onDownloadFolder?(file)
            } label: {
                Label("Download Folder to Mac", systemImage: "folder.badge.gearshape")
            }

            Button {
                onAddToSidebar?(file)
            } label: {
                Label("Add to Sidebar", systemImage: "sidebar.left")
            }
            Divider()
        }
        
        // Copy
        Button(isSingleSelection ? "Copy" : "Copy \(targetIDs.count) items") {
            let items = isSingleSelection ? [file] : selectedItems
            onCopy?(items)
        }
        
        // Cut
        Button(isSingleSelection ? "Cut" : "Cut \(targetIDs.count) items") {
            let items = isSingleSelection ? [file] : selectedItems
            onCut?(items)
        }
        
        // Paste into Folder (if this is a single directory)
        if isSingleSelection && file.isDirectory && clipboardCount > 0 && onPasteToFolder != nil {
            Button {
                onPasteToFolder?(file.path)
            } label: {
                Label(
                    "Paste into \"\(file.name)\"",
                    systemImage: clipboardOperation == .cut ? "scissors" : "doc.on.clipboard"
                )
            }
        }
        
        // Paste Here
        if clipboardCount > 0 {
            Button {
                onPaste?()
            } label: {
                Label(
                    pasteMenuTitle,
                    systemImage: clipboardOperation == .cut ? "scissors" : "doc.on.clipboard"
                )
            }
            .disabled(onPaste == nil)
        }
        
        Divider()
        
        // Rename - only for single selection
        if isSingleSelection {
            Button("Rename") {
                let kind = file.isDirectory ? "Folder" : "File"
                if let newName = TextInputDialog.show(
                    title: "Rename \(kind)",
                    message: "Enter a new name for \"\(file.name)\"",
                    placeholder: file.name,
                    initialValue: file.name,
                    confirmLabel: "Rename"
                ), newName != file.name {
                    onRename?(file, newName)
                }
            }
            .disabled(onRename == nil)
        }
        
        // Change Extension - only for multiple files (no folders)
        if targetIDs.count > 1 && hasOnlyFiles {
            Button("Change Extension...") {
                showExtensionDialog = true
            }
            .disabled(onBatchChangeExtension == nil)
        }
        
        // Move to Trash - always available
        Button(isSingleSelection ? "Move to Trash" : "Move \(targetIDs.count) items to Trash", role: .destructive) {
            if isSingleSelection {
                fileToDelete = file
                showDeleteConfirmation = true
            } else {
                batchDeleteCount = targetIDs.count
                showBatchDeleteConfirmation = true
            }
        }
        .disabled(onDelete == nil)

        // 완전 삭제
        Button(isSingleSelection ? "완전 삭제" : "\(targetIDs.count)개 항목 완전 삭제", role: .destructive) {
            filesToPermanentlyDelete = isSingleSelection ? [file] : selectedItems
            showPermanentDeleteConfirmation = true
        }
        .disabled(onPermanentDelete == nil && onPermanentDeleteFiles == nil)
    }

    // MARK: - Context Menu Helpers

    @ViewBuilder
    private var emptyAreaContextMenu: some View {
        if onNewFolder != nil {
            Button {
                onNewFolder?()
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
            
            Divider()
        }
        
        Button {
            onPaste?()
        } label: {
            Label(
                pasteMenuTitle,
                systemImage: clipboardOperation == .cut ? "scissors" : "doc.on.clipboard"
            )
        }
        .disabled(clipboardCount == 0 || onPaste == nil)
    }

    private var pasteMenuTitle: String {
        if clipboardCount > 1 {
            return "Paste Here (\(clipboardCount) items)"
        } else {
            return "Paste Here"
        }
    }
    
    // MARK: - Column Content Helpers
    
    @ViewBuilder
    private func sizeColumnContent(for file: UnifiedFile) -> some View {
        if file.isDirectory {
            if let size = folderSizes[file.path] {
                Text(formatBytes(size))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("--")
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        } else if file.size == 0 && file.modificationDate == nil && isLoadingMetadata {
            Text("···")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.tertiary)
        } else if file.size == 0 && file.modificationDate == nil {
            Text("--")
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            Text(formatBytes(file.size))
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private func dateColumnContent(for file: UnifiedFile) -> some View {
        if let date = file.modificationDate {
            Text(Self.dateFormatter.string(from: date))
                .font(.system(.callout, design: .default))
                .foregroundColor(.secondary)
        } else if !file.isDirectory && file.size == 0 && isLoadingMetadata {
            Text("···")
                .font(.system(.callout, design: .default))
                .foregroundStyle(.tertiary)
        } else {
            Text("--")
                .font(.system(.callout, design: .default))
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Helper Functions
    
    private func getFileIcon(for file: UnifiedFile) -> String {
        if file.isDirectory {
            switch file.name.lowercased() {
            case "dcim", "camera": return "camera.fill"
            case "download", "downloads": return "arrow.down.circle.fill"
            case "pictures", "photos": return "photo.fill"
            case "music": return "music.note"
            case "movies", "videos": return "film.fill"
            case "documents": return "doc.fill"
            default: return "folder.fill"
            }
        }
        
        switch file.pathExtension {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "m4a", "wav", "flac": return "music.note"
        case "pdf": return "doc.text"
        case "zip", "rar", "7z": return "doc.zipper"
        case "apk": return "app.badge"
        default: return "doc"
        }
    }
    
    private func getFileColor(for file: UnifiedFile) -> Color {
        if file.isDirectory { return .blue }
        
        switch file.pathExtension {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .purple
        case "mp4", "mov", "avi", "mkv": return .red
        case "mp3", "m4a", "wav", "flac": return .pink
        case "pdf": return .orange
        case "apk": return .green
        default: return .secondary
        }
    }
    
    private func getFileType(for file: UnifiedFile) -> String {
        let ext = file.pathExtension
        if ext.isEmpty { return "File" }
        return ext.uppercased()
    }

    private func tileDetailText(for file: UnifiedFile) -> String {
        if file.isDirectory {
            if let size = folderSizes[file.path] {
                return "Folder · \(formatBytes(size))"
            }
            return "Folder"
        }

        if file.size == 0 && file.modificationDate == nil {
            return getFileType(for: file)
        }
        return "\(getFileType(for: file)) · \(formatBytes(file.size))"
    }
    
    private var shouldShowDropOverlay: Bool {
        guard isDraggingOver else { return false }
        let internalFiles = FileDragManager.shared.draggedFiles
        if !internalFiles.isEmpty {
            return FileDragManager.shared.canDrop(onto: currentPath)
        }
        return true
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.blue, lineWidth: 3)
            .background(Color.blue.opacity(0.1))
            .padding(8)
            .transition(.opacity)
    }
    
    // MARK: - Actions
    
    private func showUploadDialog() {
        let openPanel = NSOpenPanel()
        openPanel.configureForPerformance() // Assuming you have this extension
        openPanel.title = "Select Files to Upload"
        openPanel.message = "Choose files to upload to \(currentPath)"
        
        openPanel.begin { response in
            if response == .OK {
                onUpload(openPanel.urls)
            }
        }
    }
}

// MARK: - Breadcrumb Button

struct BreadcrumbButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundColor(isHovered ? .accentColor : .secondary)
                .underline(isHovered)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Go to \(title)")
    }
}

// MARK: - Window Drag Area
/// Fixed dimensions avoid the AppKit progress host's fractional constraints on macOS 27.
struct LoadingSpinner: View {
    var size: CGFloat = 16
    var color: Color = .secondary
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
            .onDisappear { spinning = false }
            .accessibilityLabel("Loading")
    }
}

// Allows dragging the app window from the path bar (like the title bar)
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableNSView { DraggableNSView() }
    func updateNSView(_ nsView: DraggableNSView, context: Context) {}
    
    class DraggableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
