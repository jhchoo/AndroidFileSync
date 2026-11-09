//  ContentView.swift
//  (DEFINITIVE DETECTION FIX)
//
//
//  ContentView.swift
//
//
//  ContentView.swift
//

import SwiftUI
internal import Combine
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @ObservedObject var deviceManager: DeviceManager
    var downloadManager: DownloadManager
    var uploadManager: UploadManager
    
    @State private var activeDownloadsCount = 0
    @State private var activeUploadsCount = 0
    @State private var isDownloading = false
    @State private var isUploading = false
    
    @StateObject private var filePreviewManager = FilePreviewManager()
    @StateObject private var thumbnailProvider = ThumbnailProvider()
    @StateObject private var sidebarManager = SidebarManager()
    @StateObject private var mouseNavCoordinator = MouseNavigationCoordinator()

    @State private var files: [UnifiedFile] = []
    @State private var currentPath = "/sdcard"
    @State private var pathHistory: [String] = []
    @State private var forwardHistory: [String] = []
    @State private var isLoading = false
    @State private var fileLoadError: String?
    @State private var storageRepairAvailable = false
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var folderSizes: [String: UInt64] = [:]
    /// Buffer for collecting folder sizes off the main render cycle.
    /// Flushed to `folderSizes` periodically to avoid per-folder re-renders.
    private var folderSizesBuffer: [String: UInt64] {
        get { _folderSizesBuffer }
        nonmutating set { _folderSizesBuffer = newValue }
    }
    @State private var _folderSizesBuffer: [String: UInt64] = [:]
    @State private var folderSizeFlushTask: Task<Void, Never>? = nil
    
    // Directory cache — stores last 10 visited directories for instant back-navigation
    @State private var directoryCache: [String: [UnifiedFile]] = [:]
    @State private var directoryCacheOrder: [String] = []  // LRU order tracking
    
    // Metadata enrichment tracking
    @State private var metadataTask: Task<Void, Never>? = nil
    @State private var isLoadingMetadata = false
    @State private var metadataLoadedCount = 0
    @State private var metadataTotalCount = 0
    
    // Progressive loading (paginated content:// fallback)
    @State private var isLoadingMoreFiles = false
    
    // File action manager
    @StateObject private var fileActionManager = FileActionManager()

    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // Paste conflict alert
    @State private var showConflictAlert = false
    @State private var showGlobalResultAlert = false
    @State private var globalResultAlertMessage = ""
    
    // Multi-selection state
    @State private var selectedFiles: Set<String> = []
    
    // Trash view state
    @State private var showTrashView = false
    @State private var wirelessDestination: WirelessConnectView.PairingTab?

    // USB Occupied (Claim USB) state — shown on homepage
    @State private var isUSBOccupied = false
    @State private var isClaimingUSB = false
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var supportPromptManager = SupportPromptManager.shared
    @ObservedObject private var donationPromptManager = DonationPromptManager.shared
    @ObservedObject private var diagnosticsControl = DiagnosticsControl.shared

    // Get Info panel state (⌘I)
    @State private var infoFile: UnifiedFile? = nil
    @State private var fileInfoData: [String: String] = [:]
    @State private var isLoadingFileInfo = false
    @State private var fileInfoTask: Task<Void, Never>? = nil

    // Permanent delete confirmation (⌘⌥⌫)
    @State private var showPermanentDeleteConfirmation = false
    @State private var permanentDeleteCount = 0

    // Move to Trash confirmation (⌘⌫)
    @State private var showTrashConfirmation = false
    @State private var trashConfirmCount = 0


    @State private var showReportIssuePopover = false

    // App browser state
    @StateObject private var appManager = AppManager()
    @State private var activeAppFilter: AppFilter? = nil
    @State private var showOperationDetails = false
    
    // Search and sort state
    @State private var searchQuery = ""
    @State private var sortOption: ActionToolbar.SortOption = .name
    @State private var sortAscending: Bool = true
    
    // Filtered and sorted files for display.
    @State private var displayedFiles: [UnifiedFile] = []
    
    // Monotonically increasing version — incremented ONLY when sort parameters change
    // (not on every data refresh). Used by FileBrowserView Equatable to detect re-sorts.
    @State private var sortVersion: Int = 0
    
    // ── Dual Pane (2-Split View) Support ────────────────────────
    @AppStorage("isDualPaneEnabled") private var isDualPaneEnabled: Bool = false
    @State private var activePane: PaneID = .primary

    enum PaneID: Hashable {
        case primary
        case secondary
    }

    // Secondary Pane State
    @State private var secondaryPath: String = "/sdcard"
    @State private var secondaryFiles: [UnifiedFile] = []
    @State private var secondaryDisplayedFiles: [UnifiedFile] = []
    @State private var secondarySelectedFiles: Set<String> = []
    @State private var secondaryPathHistory: [String] = []
    @State private var secondaryForwardHistory: [String] = []
    @State private var secondaryIsLoading: Bool = false
    @State private var secondaryIsLoadingMoreFiles: Bool = false
    @State private var secondaryIsLoadingMetadata: Bool = false
    @State private var secondaryMetadataLoadedCount: Int = 0
    @State private var secondaryMetadataTotalCount: Int = 0
    @State private var secondaryFileLoadError: String? = nil
    @State private var secondaryStorageRepairAvailable: Bool = false
    @State private var secondarySortOption: ActionToolbar.SortOption = .name
    @State private var secondarySortAscending: Bool = true
    @State private var secondarySortVersion: Int = 0
    @State private var secondaryFolderSizes: [String: UInt64] = [:]
    @State private var secondarySearchQuery: String = ""
    @State private var secondaryLoadTask: Task<Void, Never>? = nil
    @State private var secondaryMetadataTask: Task<Void, Never>? = nil

    /// Shared sort and filter logic for both primary and secondary panes.
    private func sortAndFilterFiles(
        source: [UnifiedFile],
        query: String,
        sortOpt: ActionToolbar.SortOption,
        ascending: Bool,
        sizes: [String: UInt64]
    ) -> [UnifiedFile] {
        var result = source
        let activeDeletingPaths = Set(fileActionManager.activeDeletions.filter { !$0.isComplete }.map { $0.filePath })
        if !activeDeletingPaths.isEmpty {
            result = result.filter { !activeDeletingPaths.contains($0.path) }
        }
        if !query.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        result.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory
            }
            switch sortOpt {
            case .name:
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            case .size:
                let lhsSize = lhs.isDirectory ? (sizes[lhs.path] ?? lhs.size) : lhs.size
                let rhsSize = rhs.isDirectory ? (sizes[rhs.path] ?? rhs.size) : rhs.size
                if lhsSize != rhsSize {
                    return ascending ? lhsSize < rhsSize : lhsSize > rhsSize
                }
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            case .type:
                let t0 = lhs.sortableType
                let t1 = rhs.sortableType
                if t0 != t1 { return ascending ? t0 < t1 : t0 > t1 }
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            case .date:
                let d0 = lhs.modificationDate ?? Date.distantPast
                let d1 = rhs.modificationDate ?? Date.distantPast
                if d0 != d1 {
                    return ascending ? d0 < d1 : d0 > d1
                }
                let cmp = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        }
        return result
    }

    /// Recompute the primary displayed file list.
    private func updateDisplayedFiles() {
        displayedFiles = sortAndFilterFiles(
            source: files,
            query: searchQuery,
            sortOpt: sortOption,
            ascending: sortAscending,
            sizes: folderSizes
        )
        thumbnailProvider.requestThumbnails(for: displayedFiles, currentPath: currentPath)
    }

    /// Recompute the secondary displayed file list.
    private func updateSecondaryDisplayedFiles() {
        secondaryDisplayedFiles = sortAndFilterFiles(
            source: secondaryFiles,
            query: secondarySearchQuery,
            sortOpt: secondarySortOption,
            ascending: secondarySortAscending,
            sizes: secondaryFolderSizes
        )
        thumbnailProvider.requestThumbnails(for: secondaryDisplayedFiles, currentPath: secondaryPath)
    }
    
    /// Called when the user changes sort (via column header or toolbar menu).
    /// Increments sortVersion to force FileBrowserView re-render.
    private func sortFiles(by option: ActionToolbar.SortOption, ascending: Bool = true) {
        print("🔄 [SORT] sortFiles() — \(option.rawValue) \(ascending ? "ASC" : "DESC") (was: \(sortOption.rawValue) \(sortAscending ? "ASC" : "DESC"))")
        sortOption = option
        sortAscending = ascending
        sortVersion += 1  // Always bump — guarantees Equatable detects the change
        updateDisplayedFiles()
    }

    private var isAnyOperationActive: Bool {
        appManager.operationEngine.isBusy
    }

    private var unifiedStatusText: String {
        let activeGroups = appManager.operationEngine.activeGroups
        let isMultiGroup = activeGroups.count > 1
        let group = activeGroups.first
        let completed = group?.completedCount ?? 0
        let total = group?.totalCount ?? 0
        let verb = group?.actionVerb ?? "Processing"
        let currentApp = group?.currentRunningName ?? ""
        
        if isMultiGroup {
            return "Multiple operations executing... (\(activeGroups.count) active)"
        } else if total > 1 {
            return "\(verb) apps... \(completed + 1) of \(total) (\(currentApp))"
        } else {
            return "\(verb) \(currentApp)…"
        }
    }

    private var unifiedProgressFraction: Double {
        let activeGroups = appManager.operationEngine.activeGroups
        let totalOps = activeGroups.reduce(0) { $0 + $1.totalCount }
        let completedOps = activeGroups.reduce(0) { $0 + $1.completedCount }
        return totalOps > 0 ? Double(completedOps) / Double(totalOps) : 0.0
    }

    private var unifiedStatusColor: Color {
        let activeGroups = appManager.operationEngine.activeGroups
        if !activeGroups.isEmpty {
            return activeGroups.first?.color ?? .blue
        }
        return .blue
    }

    @ViewBuilder
    private var unifiedStatusBanner: some View {
        if isAnyOperationActive {
            let color = unifiedStatusColor
            let fraction = unifiedProgressFraction
            let statusText = unifiedStatusText
            
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    LoadingSpinner()
                    
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button {
                        showOperationDetails.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Details")
                            Image(systemName: showOperationDetails ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .popover(isPresented: $showOperationDetails, arrowEdge: .bottom) {
                        unifiedDetailsPopoverView
                    }
                    
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(color)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(color.opacity(0.15))
                            .frame(height: 3)
                        Rectangle()
                            .fill(color)
                            .frame(width: geo.size.width * fraction, height: 3)
                            .animation(.linear(duration: 0.3), value: fraction)
                    }
                }
                .frame(height: 3)
                Divider()
            }
            .background(color.opacity(0.08))
        }
    }

    /// Banner shown when the wireless connection drops and the health monitor
    /// is actively attempting to reconnect. Shows animated indicator, status message,
    /// and attempt count. Auto-dismisses when reconnection succeeds.
    @ViewBuilder
    private var reconnectionBanner: some View {
        let monitor = deviceManager.connectionHealthMonitor
        let message = monitor.reconnectMessage
        let attempt = monitor.reconnectAttempt
        
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Animated WiFi icon with pulsing effect
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.isEmpty ? "Device disconnected. Reconnecting..." : message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    
                    if attempt > 0 {
                        Text("Attempt \(attempt) · Your files are safe")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                LoadingSpinner()
                
                // Manual retry button — opens wireless connect view
                Button {
                    wirelessDestination = .qrCode
                } label: {
                    Text("Connect")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            
            // Indeterminate progress bar
            GeometryReader { geo in
                let width = geo.size.width
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.orange.opacity(0.2))
                    .frame(height: 3)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.orange)
                            .frame(width: width * 0.3, height: 3)
                            .modifier(IndeterminateProgressModifier(containerWidth: width))
                    }
            }
            .frame(height: 3)
            
            Divider()
        }
        .background(Color.orange.opacity(0.08))
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.3), value: monitor.isReconnecting)
    }

    private var unifiedDetailsPopoverView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Tasks")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 4)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let activeGroups = appManager.operationEngine.activeGroups
                    if !activeGroups.isEmpty {
                        Text("App Operations")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        ForEach(activeGroups, id: \OperationEngine.OperationGroup.id) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(group.actionVerb)
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text("\(group.completedCount)/\(group.totalCount)")
                                        .font(.system(size: 10, design: .monospaced))
                                    
                                    Button {
                                        appManager.operationEngine.cancelPending(in: group.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                let fraction = group.totalCount > 0 ? Double(group.completedCount) / Double(group.totalCount) : 0.0
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(group.color.opacity(0.2))
                                        .frame(height: 4)
                                        .overlay(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(group.color)
                                                .frame(width: geo.size.width * fraction)
                                        }
                                }
                                .frame(height: 4)
                                
                                ForEach(group.operations, id: \OperationEngine.LiveOperation.id) { op in
                                    LiveOperationRow(op: op)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
            
            Button(role: .destructive) {
                appManager.operationEngine.cancelAllPending()
                showOperationDetails = false
            } label: {
                Text("Cancel All Active Tasks")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
    }

    var body: some View {
        contentWithPresentations
    }

    // Level 1: presentation modifiers (alerts + sheets + keyboard shortcuts)
    // Split from body to stay under Swift type-checker expression complexity limit
    private var contentWithPresentations: some View {
        contentWithAlerts
            .sheet(isPresented: $showTrashView) {
                TrashView(fileActionManager: fileActionManager, onStorageChanged: {
                    Task { 
                        await deviceManager.fetchStorageInfo() 
                        await loadFiles()
                    }
                })
                    .frame(width: 450, height: 400)
            }
            .sheet(item: $wirelessDestination) { destination in
                WirelessConnectView(deviceManager: deviceManager, onConnected: {
                    Task {
                        currentPath = await deviceManager.getRealStoragePath()
                        await loadFiles()
                    }
                }, initialTab: destination)
                .id(destination)
            }
            .background(
                Group {
                    // ── Clipboard shortcuts ────────────────────────────────
                    Button("") { handleGlobalCopy() }.keyboardShortcut("c", modifiers: .command)
                    Button("") { handleGlobalCut() }.keyboardShortcut("x", modifiers: .command)
                    Button("") { handleGlobalPaste() }.keyboardShortcut("v", modifiers: .command)
                    
                    // ── Delete shortcuts (moved here for reliability) ─────
                    Button("") { handleDeleteShortcut() }.keyboardShortcut(.delete, modifiers: .command)
                    Button("") { handlePermanentDeleteShortcut() }.keyboardShortcut(.delete, modifiers: [.command, .option])

                    // ── Finder-style navigation ───────────────────────────
                    Button("") { handleSelectAll() }.keyboardShortcut("a", modifiers: .command)
                    Button("") { handleDeselectAll() }.keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("") { handleNavigateUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                    Button("") { handleOpenSelected() }.keyboardShortcut(.downArrow, modifiers: .command)
                    Button("") { navigateBack() }.keyboardShortcut("[", modifiers: .command)
                    Button("") { navigateForward() }.keyboardShortcut("]", modifiers: .command)

                    // ── File actions ──────────────────────────────────────
                    Button("") { handleGetInfo() }.keyboardShortcut("i", modifiers: .command)
                    Button("") { handleRenameShortcut() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("") { handleRenameShortcut() }.keyboardShortcut(.return, modifiers: [])
                    Button("") { handleQuickPreview() }.keyboardShortcut(.space, modifiers: [])
                    Button("") {
                        if filePreviewManager.showPreviewPanel {
                            filePreviewManager.dismissPreview()
                        } else if filePreviewManager.isLoading {
                            filePreviewManager.cancelPreview()
                        }
                    }.keyboardShortcut(.escape, modifiers: [])
                }
                .hidden()
            )
            .onReceive(NotificationCenter.default.publisher(for: .afsDeleteShortcut)) { _ in
                handleDeleteShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsPermanentDeleteShortcut)) { _ in
                handlePermanentDeleteShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsMouseNavigateBack)) { _ in
                handleMouseBack()
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsMouseNavigateForward)) { _ in
                guard activeAppFilter == nil else { return }
                navigateForward()
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsDeletionsChanged)) { _ in
                updateDisplayedFiles()
                if !fileActionManager.isDeleting {
                    Task {
                        ADBManager.invalidateFolderSizeCache()
                        await deviceManager.fetchStorageInfo()
                    }
                }
            }
            .sheet(item: $infoFile, onDismiss: {
                fileInfoTask?.cancel()
                fileInfoTask = nil
                fileInfoData = [:]
                isLoadingFileInfo = false
            }) { file in
                FileInfoView(file: file, info: fileInfoData, isLoading: isLoadingFileInfo)
            }
    }

    // Level 2: alert modifiers
    private var contentWithAlerts: some View {
        layoutContent
            .alert("Error", isPresented: $showErrorAlert) {
                if AndroidStorageAccess.isPermissionDenied(errorMessage) {
                    Button("Fix storage access") { repairStorageAccess() }
                }
                Button("OK", role: .cancel) { fileActionManager.clearError() }
            } message: {
                Text(errorMessage)
            }
            .alert(pasteConflictTitle, isPresented: $showConflictAlert) {
                Button("Replace") {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .replace)
                        await loadFiles()
                        await deviceManager.fetchStorageInfo()
                    }
                }
                Button("Keep Both") {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .keepBoth)
                        await loadFiles()
                        await deviceManager.fetchStorageInfo()
                    }
                }
                Button("Skip", role: .cancel) {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .skip)
                        await loadFiles()
                        await deviceManager.fetchStorageInfo()
                    }
                }
            } message: {
                Text(pasteConflictMessage)
            }
            .alert("Is AndroidFileSync helping you?", isPresented: $supportPromptManager.shouldShowPrompt) {
                Button("Star on GitHub") {
                    supportPromptManager.openGitHubAndMarkDone()
                }
                Button("Send Feedback") {
                    supportPromptManager.openFeedbackAndSnooze()
                }
                Button("Not Now", role: .cancel) {
                    supportPromptManager.snooze()
                }
            } message: {
                Text("If the app saved you time, a GitHub star helps other users find it. If something can be better, feedback is welcome too.")
            }
            .alert("Support AndroidFileSync ❤️", isPresented: $donationPromptManager.shouldShowPrompt) {
                Button("Donate via PayPal") {
                    donationPromptManager.openPayPalAndMarkDone()
                }
                Button("Not Now", role: .cancel) {
                    donationPromptManager.snooze()
                }
            } message: {
                Text("If AndroidFileSync has been useful, consider a small donation to help keep it free and actively maintained. Thank you!")
            }
            .alert("Result", isPresented: $showGlobalResultAlert) {
                Button("OK", role: .cancel) {
                    appManager.globalResultMessage = nil
                }
            } message: {
                Text(globalResultAlertMessage)
            }
            .alert("Permanently Delete \(permanentDeleteCount) item\(permanentDeleteCount == 1 ? "" : "s")?", isPresented: $showPermanentDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    permanentDeleteCount = 0
                }
                Button("Delete Permanently", role: .destructive) {
                    handlePermanentDelete()
                    permanentDeleteCount = 0
                }
            } message: {
                Text("This cannot be undone. The item\(permanentDeleteCount == 1 ? " will" : "s will") be permanently removed from the device.")
            }
            .alert("Move \(trashConfirmCount) item\(trashConfirmCount == 1 ? "" : "s") to Trash?", isPresented: $showTrashConfirmation) {
                Button("Cancel", role: .cancel) {
                    trashConfirmCount = 0
                }
                Button("Move to Trash", role: .destructive) {
                    executeTrashShortcut()
                    trashConfirmCount = 0
                }
            } message: {
                Text("You can restore \(trashConfirmCount == 1 ? "this item" : "these items") from the Trash.")
            }
            .onChange(of: fileActionManager.pasteConflicts.count) { newCount in
                showConflictAlert = newCount > 0
            }
            .onChange(of: appManager.globalResultMessage) { newValue in
                guard let message = newValue, !message.isEmpty else { return }
                globalResultAlertMessage = message
                showGlobalResultAlert = true
            }
            .onChange(of: deviceManager.sdCardPath) { newPath in
                sidebarManager.updateSDCard(path: newPath)
            }
            .onChange(of: deviceManager.internalStoragePath) { newPath in
                sidebarManager.updateInternalStorage(path: newPath)
                fileActionManager.internalStoragePath = newPath
            }
            .task(id: deviceManager.isConnected ? ADBManager.activeDeviceSerial : nil) {
                guard deviceManager.isConnected, let serial = ADBManager.activeDeviceSerial else { return }
                loadTask?.cancel()
                files = []
                displayedFiles = []
                selectedFiles.removeAll()
                directoryCache.removeAll()
                directoryCacheOrder.removeAll()
                fileLoadError = nil
                isLoading = true
                let path = await deviceManager.getRealStoragePath()
                guard !Task.isCancelled, deviceManager.isConnected, ADBManager.activeDeviceSerial == serial else { return }
                currentPath = path
                sidebarManager.updateInternalStorage(path: path)
                fileActionManager.internalStoragePath = path
                pathHistory.removeAll()
                forwardHistory.removeAll()
                // Storage discovery must also run when the internal listing fails.
                Task { await deviceManager.detectSDCard() }
                await loadFiles()
            }
            .onChange(of: deviceManager.isConnected) { connected in
                if !connected {
                    // If the health monitor is actively reconnecting in the background,
                    // keep the last loaded files visible as a read-only snapshot on screen.
                    guard !deviceManager.connectionHealthMonitor.isReconnecting else {
                        print("📱 ContentView: isConnected changed to false, but health monitor is reconnecting — keeping files visible.")
                        return
                    }
                    
                    // Immediately clear file browser state on disconnect
                    loadTask?.cancel()
                    metadataTask?.cancel()
                    metadataTask = nil
                    folderSizeFlushTask?.cancel()
                    folderSizeFlushTask = nil
                    files = []
                    displayedFiles = []
                    selectedFiles.removeAll()
                    folderSizes = [:]
                    _folderSizesBuffer = [:]
                    directoryCache.removeAll()
                    directoryCacheOrder.removeAll()
                    pathHistory.removeAll()
                    forwardHistory.removeAll()
                    isLoading = false
                    fileLoadError = nil
                    storageRepairAvailable = false
                    isLoadingMetadata = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsTransferCountChanged)) { notification in
                if let type = notification.userInfo?["type"] as? String,
                   let count = notification.userInfo?["count"] as? Int {
                    if type == "download" {
                        self.activeDownloadsCount = count
                    } else if type == "upload" {
                        self.activeUploadsCount = count
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsDownloadBatchCompleted)) { notification in
                if let completed = notification.userInfo?["completed"] as? Int,
                   let total = notification.userInfo?["total"] as? Int {
                    guard completed > 0, completed == total else { return }
                    supportPromptManager.recordSuccessfulBatch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsUploadBatchCompleted)) { notification in
                if let completed = notification.userInfo?["completed"] as? Int,
                   let total = notification.userInfo?["total"] as? Int {
                    guard completed > 0, completed == total else { return }
                    supportPromptManager.recordSuccessfulBatch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsUploadBatchStateChanged)) { notification in
                if let isUploading = notification.userInfo?["isUploading"] as? Bool,
                   let batchTotal = notification.userInfo?["batchTotal"] as? Int {
                    let oldUploading = self.isUploading
                    self.isUploading = isUploading
                    deviceManager.isTransferActive = isUploading || self.isDownloading
                    if !isUploading && oldUploading && batchTotal > 0 {
                        Task {
                            ADBManager.invalidateFolderSizeCache()
                            await loadFiles()
                            await deviceManager.fetchStorageInfo()
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsDownloadBatchStateChanged)) { notification in
                if let isDownloading = notification.userInfo?["isDownloading"] as? Bool {
                    self.isDownloading = isDownloading
                    deviceManager.isTransferActive = self.isUploading || isDownloading
                }
            }
            .onChange(of: diagnosticsControl.isEnabled) { enabled in
                deviceManager.setDiagnosticsEnabled(enabled)
            }
            // ── displayedFiles sync ─────────────────────────────────
            // Rebuild the sorted/filtered list when data or search changes.
            .onChange(of: files) { _ in updateDisplayedFiles() }
            .onChange(of: searchQuery) { _ in updateDisplayedFiles() }
            .onChange(of: secondaryFiles) { _ in updateSecondaryDisplayedFiles() }
            .onChange(of: secondarySearchQuery) { _ in updateSecondaryDisplayedFiles() }
            .onChange(of: isDualPaneEnabled) { enabled in
                if enabled {
                    if secondaryFiles.isEmpty {
                        secondaryPath = currentPath
                        Task { await loadSecondaryFiles() }
                    }
                }
            }
            .onChange(of: activeAppFilter) { _ in
                searchQuery = ""
            }
            .onChange(of: folderSizes) { _ in
                if sortOption == .size {
                    updateDisplayedFiles()
                }
            }
            .onChange(of: secondaryFolderSizes) { _ in
                if secondarySortOption == .size {
                    updateSecondaryDisplayedFiles()
                }
            }

    }

    // Level 3: layout + input modifiers
    private var layoutContent: some View {
        VStack(spacing: 0) {
            // Show connected content OR the reconnection banner while reconnecting
            if deviceManager.isConnected || deviceManager.connectionHealthMonitor.isReconnecting {
                connectedContent
                
                // Reconnection banner — shown when health monitor detects wireless disconnect
                if deviceManager.connectionHealthMonitor.isReconnecting {
                    reconnectionBanner
                }
            } else {
                EmptyStateView(
                    isDetecting: deviceManager.isDetecting,
                    isCheckingDevices: deviceManager.isDetectionInProgress,
                    isSearchingWireless: deviceManager.isWirelessReconnectHuntActive,
                    scanStartedAt: deviceManager.connectionScanStartedAt,
                    scanTimeout: deviceManager.connectionScanTimeout,
                    scanTimedOut: deviceManager.connectionScanTimedOut,
                    lastCheckedAt: deviceManager.lastDetectionDate,
                    recognizedWirelessDevices: deviceManager.recognizedWirelessDevices,
                    isRefreshingRecognizedDevices: deviceManager.isRefreshingRecognizedDevices,
                    lastRecognizedRefreshDate: deviceManager.lastRecognizedRefreshDate,
                    recognizedRefreshError: deviceManager.recognizedRefreshError,
                    connectingWirelessSerials: deviceManager.connectingWirelessSerials,
                    recognizedConnectionErrors: deviceManager.recognizedConnectionErrors,
                    userDisconnected: deviceManager.userDisconnected,
                    unavailableDevice: deviceManager.availableDevices.first { $0.status != "device" },
                    onRetry: {
                        Task { await deviceManager.retryDeviceDetection() }
                    },
                    onConnectWiFi: { tab in
                        wirelessDestination = tab
                    },
                    onRefreshRecognizedDevices: {
                        Task { await deviceManager.refreshRecognizedWirelessDevices() }
                    },
                    onConnectRecognizedDevice: { serial in
                        Task { await deviceManager.connectRecognizedWirelessDevice(serial: serial) }
                    },
                    onRemoveRecognizedDevice: { serial in
                        deviceManager.removeRecognizedWirelessDevice(serial: serial)
                    },
                    isUSBOccupied: isUSBOccupied,
                    isClaimingUSB: isClaimingUSB,
                    onClaimUSB: {
                        isClaimingUSB = true
                        Task {
                            _ = await ADBManager.recoverPrivateUSBTransportIfNeeded(forceRestart: true)
                            // Wait 1.5s for the OS to release the USB driver interface and map it to the private server
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await deviceManager.detectDevice()
                            isUSBOccupied = await deviceManager.isUSBDeviceOccupiedByDefaultServer()
                            isClaimingUSB = false
                            
                            // If the device is still not connected, alert the user with troubleshooting steps
                            if !deviceManager.isConnected {
                                errorMessage = "USB connection was released, but your device is still not detected.\n\nPlease try:\n• Unplugging and re-plugging the USB cable.\n• Toggling 'USB Debugging' off and on in Developer Options.\n• Checking your phone screen for an 'Allow USB debugging' prompt."
                                showErrorAlert = true
                            }
                        }
                    },
                    diagnosticsControl: diagnosticsControl
                )
            }

            TransferProgressContainer(
                downloadManager: downloadManager,
                uploadManager: uploadManager,
                deviceManager: deviceManager,
                appManager: appManager
            )
        }
        .overlay(alignment: .topTrailing) {
            if updateChecker.shouldShowBanner {
                HStack(spacing: 6) {
                    if updateChecker.isUpdating {
                        LoadingSpinner(size: 12)
                    } else {
                        Image(systemName: updateChecker.updateReadyToRestart ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                    }
                    
                    Text(updateChecker.isUpdating ? updateChecker.updateStatusMessage : (updateChecker.updateReadyToRestart ? "v\(updateChecker.latestVersion) ready to apply" : "v\(updateChecker.latestVersion) available"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                    
                    if !updateChecker.isUpdating {
                        if updateChecker.updateReadyToRestart {
                            Button(action: { updateChecker.relaunchApp() }) {
                                Text("Restart Now")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.white)
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button(action: { updateChecker.performAutoUpdate() }) {
                                Text("Update")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.blue)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.white)
                                    .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        Button(action: { updateChecker.dismissForToday() }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                )
                .padding(.top, 6)
                .padding(.trailing, 280) 
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updateChecker.shouldShowBanner)
                .zIndex(100)
            }
        }

        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            updateChecker.checkForUpdates()
            deviceManager.setDiagnosticsEnabled(diagnosticsControl.isEnabled)
            uploadManager.deviceManager = deviceManager
            downloadManager.deviceManager = deviceManager
            uploadManager.appManager = appManager
            downloadManager.appManager = appManager
            uploadManager.downloadManager = downloadManager
            downloadManager.uploadManager = uploadManager
            FileDragManager.shared.downloadManager = downloadManager
            appManager.operationEngine.deviceManager = deviceManager
            appManager.operationEngine.uploadManager = uploadManager
            appManager.operationEngine.downloadManager = downloadManager

            mouseNavCoordinator.onBack = { [self] in
                handleMouseBackButton()
            }
            mouseNavCoordinator.onForward = { [self] in
                handleMouseForwardButton()
            }
            mouseNavCoordinator.start()
        }
        .onDisappear {
            mouseNavCoordinator.stop()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var fileURLs: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url { fileURLs.append(u) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !fileURLs.isEmpty {
                    if let filter = activeAppFilter {
                        // User is in the App Manager!
                        // Install any dropped app package formats
                        for url in fileURLs {
                            let ext = url.pathExtension.lowercased()
                            if ext == "apk" || ext == "xapk" || ext == "apks" || ext == "zip" || ext == "apkm" {
                                appManager.queueInstall(url: url, currentFilter: filter)
                            }
                        }
                    } else {
                        // User is in the File Browser!
                        handleUpload(urls: fileURLs)
                    }
                }
            }
            return true
        }
        .task { await initializeDevice() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if !deviceManager.isConnected,
               !deviceManager.isDetectionInProgress,
               !deviceManager.isWirelessReconnectHuntActive,
               !deviceManager.isRefreshingRecognizedDevices,
               !ADBPairingBrowser.isPairingActive,
               !ADBManager.isPairingInProgress {
                Task {
                    await deviceManager.detectDevice()
                    // Refresh USB occupied status on the homepage
                    if !deviceManager.isConnected {
                        isUSBOccupied = await deviceManager.isUSBDeviceOccupiedByDefaultServer()
                    }
                }
            }
        }
        .onChange(of: deviceManager.isConnected) { connected in
            if connected {
                // Device connected — clear USB occupied banner
                isUSBOccupied = false
                isClaimingUSB = false
            } else {
                // Just disconnected — check if USB is now occupied
                Task {
                    isUSBOccupied = await deviceManager.isUSBDeviceOccupiedByDefaultServer()
                }
            }
        }
    }

    // Extracted to keep `body` chain under Swift complexity limit
    @ViewBuilder
    private var connectedContent: some View {
        NavigationSplitView {
            SidebarView(
                sidebarManager: sidebarManager,
                currentPath: (isDualPaneEnabled && activePane == .secondary) ? secondaryPath : currentPath,
                onNavigate: { path in
                    activeAppFilter = nil
                    if isDualPaneEnabled && activePane == .secondary {
                        navigateSecondaryTo(path)
                    } else {
                        navigateTo(path)
                    }
                },
                trashCount: fileActionManager.trashedItems.count,
                onOpenTrash: { showTrashView = true },
                activeAppFilter: activeAppFilter,
                onSelectAppFilter: { filter in
                    activeAppFilter = filter
                },
                storageStats: deviceManager.storageStats
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                unifiedStatusBanner

                ZStack {
                if let appFilter = activeAppFilter {
                    // ── App Browser ───────────────────────────────────────────
                    AppBrowserView(appManager: appManager, initialFilter: appFilter, deviceName: deviceManager.deviceName, searchQuery: $searchQuery)
                        .transition(.opacity)
                } else {
                    // ── File Browser (Single Pane or 2-Split Dual Pane) ───────
                    VStack(spacing: 0) {
                        if isDualPaneEnabled {
                            HSplitView {
                                primaryFileBrowserSection
                                    .frame(minWidth: 260)
                                secondaryFileBrowserSection
                                    .frame(minWidth: 260)
                            }
                        } else {
                            primaryFileBrowserSection
                        }
                    }
                }

                // In-app QuickLook-style preview panel
                if filePreviewManager.showPreviewPanel {
                    FilePreviewPanel(previewManager: filePreviewManager)
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .navigationTitle(deviceManager.isConnected ? "AndroidFileSync" : "")
            .navigationSubtitle(customSubtitle)
            .toolbar {
                // ── Left side: New Folder + New File ─────────────────────────
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        if activePane == .secondary && isDualPaneEnabled {
                            handleCreateSecondaryNewFolder()
                        } else {
                            handleCreateNewFolder()
                        }
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .help("New Folder (⌘⇧N)")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(activeAppFilter != nil)

                    Button {
                        if activeAppFilter == nil,
                           let name = TextInputDialog.show(
                            title: "New File",
                            message: "Enter a name for the new file",
                            placeholder: "File name",
                            initialValue: "untitled.txt",
                            confirmLabel: "Create"
                        ) {
                            let targetPath = (activePane == .secondary && isDualPaneEnabled) ? secondaryPath : currentPath
                            Task {
                                do {
                                    try await fileActionManager.createFile(at: targetPath, name: name)
                                    if activePane == .secondary && isDualPaneEnabled {
                                        await loadSecondaryFiles()
                                    } else {
                                        await loadFiles()
                                    }
                                    await deviceManager.fetchStorageInfo()
                                } catch { presentFileOperationError(error) }
                            }
                        }
                    } label: {
                        Label("New File", systemImage: "doc.badge.plus")
                    }
                    .help("New File")
                    .disabled(activeAppFilter != nil)
                }

                // ── Right side: Dual Pane + Sort + Refresh + WiFi ────────────
                ToolbarItemGroup(placement: .primaryAction) {
                    // 2-Split Dual Pane toggle button (우측 상단 2분할 버튼)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            toggleDualPane()
                        }
                    } label: {
                        Label("Dual Pane", systemImage: isDualPaneEnabled ? "square.split.2x1.fill" : "square.split.2x1")
                    }
                    .help(isDualPaneEnabled ? "Single pane view" : "Dual pane (2-split) view (⌘⇧D)")
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                    // Sort menu (only in file browser)
                    if activeAppFilter == nil {
                        Menu {
                            ForEach(ActionToolbar.SortOption.allCases, id: \.self) { opt in
                                Button {
                                    if activePane == .secondary && isDualPaneEnabled {
                                        secondarySortOption = opt
                                        secondarySortAscending = (secondarySortOption == opt) ? !secondarySortAscending : true
                                        secondarySortVersion += 1
                                        updateSecondaryDisplayedFiles()
                                    } else {
                                        sortFiles(by: opt, ascending: sortOption == opt ? !sortAscending : true)
                                    }
                                } label: {
                                    let currentOpt = (activePane == .secondary && isDualPaneEnabled) ? secondarySortOption : sortOption
                                    let currentAsc = (activePane == .secondary && isDualPaneEnabled) ? secondarySortAscending : sortAscending
                                    if currentOpt == opt {
                                        Label(opt.rawValue, systemImage: currentAsc ? "chevron.up" : "chevron.down")
                                    } else {
                                        Text(opt.rawValue)
                                    }
                                }
                            }
                        } label: {
                            let currentOpt = (activePane == .secondary && isDualPaneEnabled) ? secondarySortOption : sortOption
                            Label(currentOpt.rawValue, systemImage: "arrow.up.arrow.down")
                        }
                        .help("Sort files")
                    }

                    Button {
                        Task {
                            await loadFiles()
                            if isDualPaneEnabled {
                                await loadSecondaryFiles()
                            }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)

                    // Connection button — icon reflects current connection type
                    Button { wirelessDestination = .qrCode } label: {
                        if deviceManager.connectionType == .wireless {
                            Label("WiFi", systemImage: "wifi")
                                .foregroundColor(.green)
                        } else if deviceManager.connectionType == .usb {
                            Label("USB", systemImage: "cable.connector")
                                .foregroundColor(.primary)
                        } else {
                            Label("WiFi", systemImage: "wifi")
                        }
                    }
                    .help(deviceManager.connectionType == .wireless
                          ? "Manage WiFi connection"
                          : deviceManager.connectionType == .usb
                            ? "Connected via USB — tap to manage connections"
                            : "Connect via WiFi")

                    Button { showReportIssuePopover = true } label: {
                        Label("Report Issue", systemImage: "exclamationmark.bubble")
                    }
                    .help("Report an issue")
                    .popover(isPresented: $showReportIssuePopover, arrowEdge: .bottom) {
                        ReportIssuePopoverView(diagnosticsControl: diagnosticsControl)
                    }

                }
            }
            .searchable(text: $searchQuery, placement: .toolbar, prompt: activeAppFilter != nil ? "Search apps..." : "Search files...")
            }
        }
    }

        // MARK: - Computed Properties for Alerts
    
    private var customSubtitle: String {
        var status = deviceManager.statusMessage
        
        if deviceManager.isConnected {
            let downloadsCount = activeDownloadsCount
            let uploadsCount = activeUploadsCount
            
            var transfers: [String] = []
            if downloadsCount > 0 {
                transfers.append("\(downloadsCount) download\(downloadsCount > 1 ? "s" : "")")
            }
            if uploadsCount > 0 {
                transfers.append("\(uploadsCount) upload\(uploadsCount > 1 ? "s" : "")")
            }
            
            if !transfers.isEmpty {
                status += " • " + transfers.joined(separator: ", ")
            }
        }
        
        return status
    }
    
    private var pasteConflictTitle: String {
        let count = fileActionManager.pasteConflicts.count
        if count == 1 {
            if let first = fileActionManager.pasteConflicts.first {
                return "“\(first.file.name)” already exists"
            }
            return "File already exists"
        }
        return "\(count) items already exist"
    }
    
    private var pasteConflictMessage: String {
        let count = fileActionManager.pasteConflicts.count
        if count == 1 {
            let name = fileActionManager.pasteConflicts.first?.file.name ?? ""
            return "\"\(name)\" already exists at the destination. Replace it, keep both files, or skip?"
        }
        return "\(count) files already exist at the destination. Choose how to proceed for all of them."
    }

    // MARK: - Dual Pane Browser Sections

    @ViewBuilder
    private var primaryFileBrowserSection: some View {
        if let fileLoadError {
            StorageAccessErrorView(
                message: fileLoadError,
                canRepair: storageRepairAvailable,
                isRepairing: deviceManager.isRepairingStorage,
                isLoading: isLoading,
                onRepair: repairStorageAccess,
                onRetry: retryFileAccess,
                onSaveDiagnostics: saveStorageDiagnostics
            )
        } else {
            primaryFileBrowserView
        }
    }

    @ViewBuilder
    private var secondaryFileBrowserSection: some View {
        if let secondaryFileLoadError {
            StorageAccessErrorView(
                message: secondaryFileLoadError,
                canRepair: secondaryStorageRepairAvailable,
                isRepairing: deviceManager.isRepairingStorage,
                isLoading: secondaryIsLoading,
                onRepair: repairStorageAccess,
                onRetry: { Task { await loadSecondaryFiles() } },
                onSaveDiagnostics: saveStorageDiagnostics
            )
        } else {
            secondaryFileBrowserView
        }
    }

    @ViewBuilder
    private var primaryFileBrowserView: some View {
        FileBrowserView(
            files: displayedFiles,
            currentPath: currentPath,
            isLoading: isLoading,
            canGoBack: !pathHistory.isEmpty,
            selectedFiles: $selectedFiles,
            onNavigate: navigateTo,
            onGoBack: navigateBack,
            onDownload: handleDownload,
            onUpload: { urls in handleUpload(urls: urls, destinationPath: currentPath) },
            onDelete: handleDelete,
            onRename: handleRename,
            onPreview: { file in filePreviewManager.previewFile(file) },
            isPerformingAction: fileActionManager.isPerformingAction,
            currentActionText: fileActionManager.currentAction,
            onCancelAction: { fileActionManager.requestCancellation() },
            onBatchDelete: handleBatchDelete,
            onBatchDownload: handleBatchDownload,
            onBatchChangeExtension: { ext in handleBatchChangeExtension(ext) },
            onCopy: { files in fileActionManager.copyToClipboard(files) },
            onCut: { files in fileActionManager.cutToClipboard(files) },
            onDownloadFolder: handleFolderDownload,
            onAddToSidebar: { folder in
                sidebarManager.addItem(
                    name: folder.name,
                    path: folder.path,
                    icon: "folder.fill",
                    color: "blue"
                )
            },
            onPermanentDelete: { handlePermanentDelete() },
            onPermanentDeleteFiles: { files in handlePermanentDelete(files: files) },
            clipboardCount: fileActionManager.clipboard.count,
            clipboardOperation: fileActionManager.clipboardOperation,
            onPaste: {
                Task {
                    do {
                        try await fileActionManager.paste(to: currentPath)
                    } catch {
                        AppLogger.log("❌ [onPaste] Paste failed: \(error.localizedDescription)", level: .error)
                        presentFileOperationError(error)
                    }
                    await loadFiles()
                    if isDualPaneEnabled { await loadSecondaryFiles() }
                    await deviceManager.fetchStorageInfo()
                }
            },
            onPasteToFolder: { targetFolder in
                Task {
                    do {
                        try await fileActionManager.paste(to: targetFolder)
                    } catch {
                        AppLogger.log("❌ [onPasteToFolder] Paste failed: \(error.localizedDescription)", level: .error)
                        presentFileOperationError(error)
                    }
                    await loadFiles()
                    if isDualPaneEnabled { await loadSecondaryFiles() }
                    await deviceManager.fetchStorageInfo()
                }
            },
            onNewFolder: handleCreateNewFolder,
            onClearClipboard: { fileActionManager.clearClipboard() },
            onMoveFiles: { files, dest in handleMoveFiles(files: files, destination: dest) },
            onUploadToFolder: { urls, dest in handleUpload(urls: urls, destinationPath: dest) },
            activeDeletions: fileActionManager.activeDeletions,
            onCancelDeletion: { id in fileActionManager.cancelDeletion(id: id) },
            onCancelAllDeletions: { fileActionManager.cancelAllDeletions() },
            sortOption: sortOption,
            sortAscending: sortAscending,
            sortVersion: sortVersion,
            onSortChange: { option, ascending in sortFiles(by: option, ascending: ascending) },
            folderSizes: folderSizes,
            isLoadingMetadata: isLoadingMetadata,
            metadataLoadedCount: metadataLoadedCount,
            metadataTotalCount: metadataTotalCount,
            isLoadingMoreFiles: isLoadingMoreFiles,
            thumbnailProvider: thumbnailProvider,
            isInteractionEnabled: !filePreviewManager.showPreviewPanel,
            isDualPane: isDualPaneEnabled,
            onToggleDualPane: { toggleDualPane() },
            isActivePane: activePane == .primary
        )
        .onTapGesture {
            activePane = .primary
        }
    }

    @ViewBuilder
    private var secondaryFileBrowserView: some View {
        FileBrowserView(
            files: secondaryDisplayedFiles,
            currentPath: secondaryPath,
            isLoading: secondaryIsLoading,
            canGoBack: !secondaryPathHistory.isEmpty,
            selectedFiles: $secondarySelectedFiles,
            onNavigate: navigateSecondaryTo,
            onGoBack: navigateSecondaryBack,
            onDownload: handleDownload,
            onUpload: { urls in handleUpload(urls: urls, destinationPath: secondaryPath) },
            onDelete: handleDelete,
            onRename: handleRename,
            onPreview: { file in filePreviewManager.previewFile(file) },
            isPerformingAction: fileActionManager.isPerformingAction,
            currentActionText: fileActionManager.currentAction,
            onCancelAction: { fileActionManager.requestCancellation() },
            onBatchDelete: { handleSecondaryBatchDelete() },
            onBatchDownload: { handleBatchDownload() },
            onBatchChangeExtension: { ext in handleBatchChangeExtension(ext, inSecondary: true) },
            onCopy: { files in fileActionManager.copyToClipboard(files) },
            onCut: { files in fileActionManager.cutToClipboard(files) },
            onDownloadFolder: handleFolderDownload,
            onAddToSidebar: { folder in
                sidebarManager.addItem(
                    name: folder.name,
                    path: folder.path,
                    icon: "folder.fill",
                    color: "blue"
                )
            },
            onPermanentDelete: { handleSecondaryPermanentDelete() },
            onPermanentDeleteFiles: { files in handleSecondaryPermanentDelete(files: files) },
            clipboardCount: fileActionManager.clipboard.count,
            clipboardOperation: fileActionManager.clipboardOperation,
            onPaste: {
                Task {
                    do {
                        try await fileActionManager.paste(to: secondaryPath)
                    } catch {
                        AppLogger.log("❌ [onPaste] Paste failed: \(error.localizedDescription)", level: .error)
                        presentFileOperationError(error)
                    }
                    await loadSecondaryFiles()
                    await loadFiles()
                    await deviceManager.fetchStorageInfo()
                }
            },
            onPasteToFolder: { targetFolder in
                Task {
                    do {
                        try await fileActionManager.paste(to: targetFolder)
                    } catch {
                        AppLogger.log("❌ [onPasteToFolder] Paste failed: \(error.localizedDescription)", level: .error)
                        presentFileOperationError(error)
                    }
                    await loadSecondaryFiles()
                    await loadFiles()
                    await deviceManager.fetchStorageInfo()
                }
            },
            onNewFolder: { handleCreateSecondaryNewFolder() },
            onClearClipboard: { fileActionManager.clearClipboard() },
            onMoveFiles: { files, dest in handleMoveFiles(files: files, destination: dest) },
            onUploadToFolder: { urls, dest in handleUpload(urls: urls, destinationPath: dest) },
            activeDeletions: fileActionManager.activeDeletions,
            onCancelDeletion: { id in fileActionManager.cancelDeletion(id: id) },
            onCancelAllDeletions: { fileActionManager.cancelAllDeletions() },
            sortOption: secondarySortOption,
            sortAscending: secondarySortAscending,
            sortVersion: secondarySortVersion,
            onSortChange: { option, ascending in
                secondarySortOption = option
                secondarySortAscending = ascending
                secondarySortVersion += 1
                updateSecondaryDisplayedFiles()
            },
            folderSizes: secondaryFolderSizes,
            isLoadingMetadata: secondaryIsLoadingMetadata,
            metadataLoadedCount: secondaryMetadataLoadedCount,
            metadataTotalCount: secondaryMetadataTotalCount,
            isLoadingMoreFiles: secondaryIsLoadingMoreFiles,
            thumbnailProvider: thumbnailProvider,
            isInteractionEnabled: !filePreviewManager.showPreviewPanel,
            isDualPane: isDualPaneEnabled,
            onToggleDualPane: { toggleDualPane() },
            isActivePane: activePane == .secondary
        )
        .onTapGesture {
            activePane = .secondary
        }
    }

    // MARK: - Dual Pane Navigation & Operations

    private func toggleDualPane() {
        isDualPaneEnabled.toggle()
        if isDualPaneEnabled {
            if secondaryFiles.isEmpty {
                secondaryPath = currentPath
                Task {
                    await loadSecondaryFiles()
                }
            }
        }
    }

    private func loadSecondaryFiles() async {
        let pathSnapshot = secondaryPath
        let serialSnapshot = ADBManager.activeDeviceSerial
        AppLogger.log("📂 [loadSecondaryFiles] Request to load directory: \(secondaryPath)")

        secondaryMetadataTask?.cancel()
        secondaryMetadataTask = nil

        await MainActor.run {
            secondaryIsLoading = true
            secondaryIsLoadingMetadata = false
            secondaryMetadataLoadedCount = 0
            secondaryMetadataTotalCount = 0
        }

        do {
            let newFiles = try await deviceManager.listFiles(path: pathSnapshot) { pageFiles in
                Task { @MainActor in
                    guard self.secondaryPath == pathSnapshot, ADBManager.activeDeviceSerial == serialSnapshot else { return }
                    self.secondaryFiles.append(contentsOf: pageFiles)
                    if self.secondaryIsLoading {
                        self.secondaryIsLoading = false
                        self.secondaryIsLoadingMoreFiles = true
                    }
                }
            }

            await MainActor.run {
                guard self.secondaryPath == pathSnapshot, ADBManager.activeDeviceSerial == serialSnapshot else { return }
                self.secondaryFiles = newFiles
                self.secondaryFileLoadError = nil
                self.secondaryStorageRepairAvailable = false
                self.secondaryIsLoading = false
                self.secondaryIsLoadingMoreFiles = false
                self.updateSecondaryDisplayedFiles()
            }
        } catch {
            await MainActor.run {
                guard self.secondaryPath == pathSnapshot, ADBManager.activeDeviceSerial == serialSnapshot else { return }
                self.secondaryStorageRepairAvailable = AndroidStorageAccess.isPermissionDenied(error.localizedDescription)
                self.secondaryFileLoadError = self.secondaryStorageRepairAvailable
                    ? AndroidStorageAccess.Failure.permissionDenied.localizedDescription
                    : "Couldn't open this folder. Unlock your device and try again."
                self.secondaryFiles = []
                self.secondarySelectedFiles.removeAll()
                self.secondaryIsLoading = false
                self.secondaryIsLoadingMoreFiles = false
                self.updateSecondaryDisplayedFiles()
            }
        }
    }

    private func navigateSecondaryTo(_ path: String) {
        secondaryLoadTask?.cancel()
        secondaryMetadataTask?.cancel()
        secondaryMetadataTask = nil

        secondarySelectedFiles.removeAll()
        secondaryPathHistory.append(secondaryPath)
        secondaryForwardHistory.removeAll()
        secondaryPath = path
        secondaryFileLoadError = nil
        secondaryStorageRepairAvailable = false
        secondaryIsLoading = true
        secondaryIsLoadingMetadata = false
        secondaryIsLoadingMoreFiles = false
        secondaryFolderSizes = [:]

        secondaryLoadTask = Task.detached(priority: .userInitiated) {
            await self.loadSecondaryFiles()
        }
    }

    private func navigateSecondaryBack() {
        guard let previousPath = secondaryPathHistory.popLast() else { return }
        secondaryForwardHistory.append(secondaryPath)

        secondaryLoadTask?.cancel()
        secondaryMetadataTask?.cancel()
        secondaryMetadataTask = nil

        secondarySelectedFiles.removeAll()
        secondaryPath = previousPath
        secondaryFileLoadError = nil
        secondaryStorageRepairAvailable = false
        secondaryIsLoadingMetadata = false
        secondaryIsLoading = true

        secondaryLoadTask = Task.detached(priority: .userInitiated) {
            await self.loadSecondaryFiles()
        }
    }

    private func handleCreateSecondaryNewFolder() {
        if let name = TextInputDialog.show(
            title: "New Folder",
            message: "Enter a name for the new folder",
            placeholder: "Folder name",
            initialValue: "New Folder",
            confirmLabel: "Create"
        ) {
            Task {
                do {
                    try await fileActionManager.createFolder(at: secondaryPath, name: name)
                    await loadSecondaryFiles()
                    await deviceManager.fetchStorageInfo()
                } catch {
                    AppLogger.log("❌ [handleCreateSecondaryNewFolder] Failed to create folder '\(name)': \(error.localizedDescription)", level: .error)
                    presentFileOperationError(error)
                }
            }
        }
    }

    private func handleSecondaryBatchDelete() {
        let filesToDelete = secondaryFiles.filter { secondarySelectedFiles.contains($0.id) }
        guard !filesToDelete.isEmpty else { return }

        let deletedIDs = Set(filesToDelete.map { $0.id })
        secondaryFiles.removeAll { deletedIDs.contains($0.id) }
        updateSecondaryDisplayedFiles()
        secondarySelectedFiles.removeAll()

        Task {
            do {
                try await fileActionManager.deleteFiles(filesToDelete)
                ADBManager.invalidateFolderSizeCache()
                await deviceManager.fetchStorageInfo()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
                await loadSecondaryFiles()
            }
        }
    }

    private func handleSecondaryPermanentDelete(files filesToDelete: [UnifiedFile]? = nil) {
        let targets = filesToDelete ?? secondaryFiles.filter { secondarySelectedFiles.contains($0.id) }
        guard !targets.isEmpty else { return }

        let deletedIDs = Set(targets.map { $0.id })
        secondaryFiles.removeAll { deletedIDs.contains($0.id) }
        updateSecondaryDisplayedFiles()
        secondarySelectedFiles.subtract(deletedIDs)

        Task {
            do {
                try await fileActionManager.deleteFiles(targets, permanent: true)
                ADBManager.invalidateFolderSizeCache()
                await deviceManager.fetchStorageInfo()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
                await loadSecondaryFiles()
            }
        }
    }

    // MARK: - Global Actions

    private func handleGlobalCopy() {
        let sourceFiles = (activePane == .secondary && isDualPaneEnabled) ? secondaryFiles : files
        let sourceSelected = (activePane == .secondary && isDualPaneEnabled) ? secondarySelectedFiles : selectedFiles
        let items = sourceFiles.filter { sourceSelected.contains($0.id) }
        if items.isEmpty {
            print("⌘C: No matching files in active listing (selectedFiles=\(sourceSelected.count), files=\(sourceFiles.count))")
            return
        }
        print("⌘C: Copying \(items.count) item(s): \(items.map(\.name))")
        fileActionManager.copyToClipboard(items)
    }

    private func handleGlobalCut() {
        let sourceFiles = (activePane == .secondary && isDualPaneEnabled) ? secondaryFiles : files
        let sourceSelected = (activePane == .secondary && isDualPaneEnabled) ? secondarySelectedFiles : selectedFiles
        let items = sourceFiles.filter { sourceSelected.contains($0.id) }
        if items.isEmpty {
            print("⌘X: No matching files in active listing")
            return
        }
        print("⌘X: Cutting \(items.count) item(s): \(items.map(\.name))")
        fileActionManager.cutToClipboard(items)
    }

    private func handleCreateNewFolder() {
        guard activeAppFilter == nil else { return }
        let targetPath = (activePane == .secondary && isDualPaneEnabled) ? secondaryPath : currentPath
        if let name = TextInputDialog.show(
            title: "New Folder",
            message: "Enter a name for the new folder",
            placeholder: "Folder name",
            initialValue: "New Folder",
            confirmLabel: "Create"
        ) {
            Task {
                do {
                    try await fileActionManager.createFolder(at: targetPath, name: name)
                    if activePane == .secondary && isDualPaneEnabled {
                        await loadSecondaryFiles()
                    } else {
                        await loadFiles()
                    }
                    await deviceManager.fetchStorageInfo()
                } catch {
                    AppLogger.log("❌ [handleCreateNewFolder] Failed to create folder '\(name)': \(error.localizedDescription)", level: .error)
                    presentFileOperationError(error)
                }
            }
        }
    }

    private func handleGlobalPaste() {
        let targetPath = (activePane == .secondary && isDualPaneEnabled) ? secondaryPath : currentPath
        if !fileActionManager.clipboard.isEmpty {
            // Internal paste — sequential: paste first, then refresh once.
            Task {
                do {
                    try await fileActionManager.paste(to: targetPath)
                } catch {
                    AppLogger.log("❌ [handleGlobalPaste] Paste failed: \(error.localizedDescription)", level: .error)
                    presentFileOperationError(error)
                }
                await loadFiles()
                if isDualPaneEnabled { await loadSecondaryFiles() }
                await deviceManager.fetchStorageInfo()
            }
        } else {
            // Finder drag-paste: read URLs from Mac pasteboard
            guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  !urls.isEmpty else { return }
            handleUpload(urls: urls, destinationPath: targetPath)
        }
    }

    // MARK: - Keyboard Shortcut Handlers

    private func handleSelectAll() {
        guard activeAppFilter == nil else { return }

        // Keep the standard Command-A behavior while editing search or rename text.
        if let textView = NSApp.keyWindow?.firstResponder as? NSTextView,
           textView.isFieldEditor {
            textView.selectAll(nil)
            return
        }

        if activePane == .secondary && isDualPaneEnabled {
            secondarySelectedFiles = Set(secondaryDisplayedFiles.map(\.id))
        } else {
            selectedFiles = Set(displayedFiles.map(\.id))
        }
    }

    private func handleDeselectAll() {
        guard activeAppFilter == nil else { return }
        if activePane == .secondary && isDualPaneEnabled {
            secondarySelectedFiles.removeAll()
        } else {
            selectedFiles.removeAll()
        }
    }

    private func handleMouseBack() {
        guard activeAppFilter == nil else { return }
        handleNavigateUp()
    }

    private func handleNavigateUp() {
        guard activeAppFilter == nil else { return }
        let targetPath = (activePane == .secondary && isDualPaneEnabled) ? secondaryPath : currentPath
        let root = AndroidStorageAccess.storageRoot(for: targetPath) ?? "/storage/emulated/0"
        guard targetPath != root && targetPath != root + "/" else { return }

        // Navigate to the parent directory
        let parent = (targetPath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != targetPath else { return }
        if activePane == .secondary && isDualPaneEnabled {
            navigateSecondaryTo(parent)
        } else {
            navigateTo(parent)
        }
    }

    private func handleOpenSelected() {
        guard activeAppFilter == nil else { return }
        let isSec = (activePane == .secondary && isDualPaneEnabled)
        let sourceFiles = isSec ? secondaryFiles : files
        let sourceSelected = isSec ? secondarySelectedFiles : selectedFiles

        guard let firstId = sourceSelected.first,
              let file = sourceFiles.first(where: { $0.id == firstId }) else { return }

        if file.isDirectory {
            if isSec {
                navigateSecondaryTo(file.path)
            } else {
                navigateTo(file.path)
            }
        } else if FilePreviewManager.isPreviewable(file) {
            filePreviewManager.previewFile(file)
        } else {
            handleDownload(file: file)
        }
    }

    private func handleDeleteShortcut() {
        guard activeAppFilter == nil else { return }
        let sourceFiles = (activePane == .secondary && isDualPaneEnabled) ? secondaryFiles : files
        let sourceSelected = (activePane == .secondary && isDualPaneEnabled) ? secondarySelectedFiles : selectedFiles
        let items = sourceFiles.filter { sourceSelected.contains($0.id) }
        guard !items.isEmpty else { return }

        // Single file (not folder) → delete immediately without confirmation
        if items.count == 1, let file = items.first, !file.isDirectory {
            handleDelete(file)
            return
        }

        trashConfirmCount = items.count
        showTrashConfirmation = true
    }

    /// Actually performs the trash operation after user confirms
    private func executeTrashShortcut() {
        let isSec = (activePane == .secondary && isDualPaneEnabled)
        let sourceFiles = isSec ? secondaryFiles : files
        let sourceSelected = isSec ? secondarySelectedFiles : selectedFiles
        let items = sourceFiles.filter { sourceSelected.contains($0.id) }
        guard !items.isEmpty else { return }

        if items.count == 1 {
            handleDelete(items.first!)
        } else {
            if isSec {
                handleSecondaryBatchDelete()
            } else {
                handleBatchDelete()
            }
        }
    }

    private func handlePermanentDeleteShortcut() {
        guard activeAppFilter == nil else { return }
        let sourceFiles = (activePane == .secondary && isDualPaneEnabled) ? secondaryFiles : files
        let sourceSelected = (activePane == .secondary && isDualPaneEnabled) ? secondarySelectedFiles : selectedFiles
        let items = sourceFiles.filter { sourceSelected.contains($0.id) }
        guard !items.isEmpty else { return }
        permanentDeleteCount = items.count
        showPermanentDeleteConfirmation = true
    }

    private func handleRenameShortcut() {
        guard activeAppFilter == nil else { return }
        let isSec = (activePane == .secondary && isDualPaneEnabled)
        let sourceFiles = isSec ? secondaryFiles : files
        let sourceSelected = isSec ? secondarySelectedFiles : selectedFiles

        guard sourceSelected.count == 1,
              let fileId = sourceSelected.first,
              let file = sourceFiles.first(where: { $0.id == fileId }) else { return }

        let kind = file.isDirectory ? "Folder" : "File"
        if let newName = TextInputDialog.show(
            title: "Rename \(kind)",
            message: "Enter a new name for \"\(file.name)\"",
            placeholder: file.name,
            initialValue: file.name,
            confirmLabel: "Rename"
        ), newName != file.name {
            handleRename(file, newName: newName)
        }
    }

    private func handleQuickPreview() {
        if filePreviewManager.showPreviewPanel {
            filePreviewManager.dismissPreview()
            return
        }
        guard activeAppFilter == nil else { return }
        let isSec = (activePane == .secondary && isDualPaneEnabled)
        let sourceFiles = isSec ? secondaryFiles : files
        let sourceSelected = isSec ? secondarySelectedFiles : selectedFiles

        guard sourceSelected.count == 1,
              let fileId = sourceSelected.first,
              let file = sourceFiles.first(where: { $0.id == fileId }) else { return }

        if file.isDirectory {
            if isSec {
                navigateSecondaryTo(file.path)
            } else {
                navigateTo(file.path)
            }
            return
        }

        guard FilePreviewManager.isPreviewable(file) else { return }
        filePreviewManager.previewFile(file)
    }

    private func handleGetInfo() {
        guard activeAppFilter == nil else { return }
        let isSec = (activePane == .secondary && isDualPaneEnabled)
        let sourceFiles = isSec ? secondaryFiles : files
        let sourceSelected = isSec ? secondarySelectedFiles : selectedFiles

        guard sourceSelected.count == 1,
              let fileId = sourceSelected.first,
              let file = sourceFiles.first(where: { $0.id == fileId }) else { return }

        fileInfoTask?.cancel()
        fileInfoTask = nil

        fileInfoData = [:]
        isLoadingFileInfo = true
        infoFile = file

        let selectedFileID = file.id
        fileInfoTask = Task {
            do {
                let info = try await ADBManager.getFileInfo(path: file.path, isDirectory: file.isDirectory)
                await MainActor.run {
                    guard infoFile?.id == selectedFileID else { return }
                    fileInfoData = info
                    isLoadingFileInfo = false
                }
            } catch {
                await MainActor.run {
                    guard infoFile?.id == selectedFileID else { return }
                    isLoadingFileInfo = false
                }
            }
        }
    }
    
    // MARK: - Functions (Your navigation and data loading logic)

    private func initializeDevice() async {
        // Start IOKit USB monitor FIRST — fires instantly on plug/unplug
        deviceManager.startMonitoring()
        
        await deviceManager.detectDevice()
        
        // NOTE: We do NOT call loadFiles() here.
        // The task keyed to the connected transport is the single source for the initial load.
        // Calling loadFiles() here too caused a race condition where files were loaded twice.
        //
        // NOTE: The earlier USB cold-start polling loop (10×0.3s) was removed because:
        //  1. detectDevice() itself calls recoverPrivateUSBTransportIfNeeded() on cold-start.
        //  2. DeviceManager's wirelessHuntTask handles wireless retry in the background.
        //  3. The 5-second timer re-calls detectDevice() automatically.
        //  All three together give fast re-detection without the 3-second stall.
    }

    
    /// Refreshes the sidebar storage stats (Internal Storage bar) after a file operation
    private func refreshStorageStats() {
        Task { await deviceManager.fetchStorageInfo() }
    }

    private func presentFileOperationError(_ error: Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription
        showErrorAlert = true
    }

    private func retryFileAccess() {
        loadTask?.cancel()
        let serial = ADBManager.activeDeviceSerial
        loadTask = Task {
            isLoading = true
            if AndroidStorageAccess.storageRoot(for: currentPath) == currentPath {
                let path = await deviceManager.getRealStoragePath()
                guard !Task.isCancelled, ADBManager.activeDeviceSerial == serial else { return }
                currentPath = path
            }
            await loadFiles()
        }
    }

    private func repairStorageAccess() {
        guard !deviceManager.isRepairingStorage else { return }
        loadTask?.cancel()
        let serial = ADBManager.activeDeviceSerial
        isLoading = false
        fileLoadError = AndroidStorageAccess.Failure.permissionDenied.localizedDescription
        storageRepairAvailable = true
        loadTask = Task {
            do {
                let path = try await deviceManager.repairStorageAccess()
                guard !Task.isCancelled, ADBManager.activeDeviceSerial == serial else { return }
                currentPath = path
                pathHistory.removeAll()
                forwardHistory.removeAll()
                directoryCache.removeAll()
                directoryCacheOrder.removeAll()
                sidebarManager.updateInternalStorage(path: path)
                fileActionManager.internalStoragePath = path
                await loadFiles()
            } catch {
                guard !Task.isCancelled, ADBManager.activeDeviceSerial == serial else { return }
                isLoading = false
                fileLoadError = error.localizedDescription
                if case AndroidStorageAccess.Failure.firmwareRestricted = error {
                    storageRepairAvailable = false
                }
            }
        }
    }

    private func saveStorageDiagnostics() {
        Task {
            let report = await deviceManager.storageDiagnosticReport()
            let panel = NSSavePanel()
            panel.title = "Save storage diagnostics"
            panel.nameFieldStringValue = "AndroidFileSync-storage-diagnostics.txt"
            panel.allowedContentTypes = [.plainText]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do { try report.write(to: url, atomically: true, encoding: .utf8) }
            catch { presentFileOperationError(error) }
        }
    }
    
    private func loadFiles() async {
        let pathSnapshot = currentPath
        let serialSnapshot = ADBManager.activeDeviceSerial
        AppLogger.log("📂 [loadFiles] Request to load directory: \(currentPath) (connection: \(deviceManager.connectionType.rawValue))")
        // Check if cancelled early
        guard !Task.isCancelled else {
            AppLogger.log("⚠️ [loadFiles] Task cancelled before starting (user navigated away?)")
            return
        }
        
        // Cancel any in-progress metadata loading
        metadataTask?.cancel()
        metadataTask = nil
        
        // Pause download progress updates to avoid ADB contention
        await MainActor.run {
            downloadManager.pauseUpdates()
            isLoading = true
            isLoadingMetadata = false
            metadataLoadedCount = 0
            metadataTotalCount = 0
        }
        
        // Invalidate the ADB-level folder size cache so stale sizes are never shown
        // (e.g., after paste/delete operations change folder contents)
        ADBManager.invalidateFolderSizeCache()
        
        // Check again before expensive operation
        guard !Task.isCancelled else {
            AppLogger.log("⚠️ [loadFiles] Task cancelled before listFiles call (user navigated away?)")
            await MainActor.run {
                isLoading = false
                downloadManager.resumeUpdates()
            }
            return
        }
        
        // Do the expensive work completely off main thread
        var newFiles: [UnifiedFile]
        var receivedProgressiveUpdates = false
        do {
            newFiles = try await deviceManager.listFiles(path: pathSnapshot) { pageFiles in
                // This callback fires for each page of content:// pagination results.
                // Append to UI immediately so user can start browsing while more pages load.
                receivedProgressiveUpdates = true
                Task { @MainActor in
                    guard self.currentPath == pathSnapshot, ADBManager.activeDeviceSerial == serialSnapshot else { return }
                    self.files.append(contentsOf: pageFiles)
                    if self.isLoading {
                        // First page arrived — stop spinner, show subtle "loading more" indicator
                        self.isLoading = false
                        self.isLoadingMoreFiles = true
                    }
                }
            }
        } catch {
            AppLogger.log("❌ [loadFiles] listFiles threw error: \(error.localizedDescription)", level: .error)
            await MainActor.run {
                guard !Task.isCancelled, self.currentPath == pathSnapshot,
                      ADBManager.activeDeviceSerial == serialSnapshot else { return }
                storageRepairAvailable = AndroidStorageAccess.isPermissionDenied(error.localizedDescription)
                fileLoadError = storageRepairAvailable
                    ? AndroidStorageAccess.Failure.permissionDenied.localizedDescription
                    : "Couldn't open this folder. Unlock your device and try again."
                files = []
                selectedFiles.removeAll()
                directoryCache.removeValue(forKey: pathSnapshot)
                directoryCacheOrder.removeAll { $0 == pathSnapshot }
                isLoading = false
                isLoadingMoreFiles = false
                downloadManager.resumeUpdates()
            }
            return
        }
        AppLogger.log("📂 [loadFiles] Finished fetching files. Count: \(newFiles.count)\(receivedProgressiveUpdates ? " (progressive mode)" : "")")
        
        // Check before updating UI
        guard !Task.isCancelled, currentPath == pathSnapshot, ADBManager.activeDeviceSerial == serialSnapshot else {
            AppLogger.log("⚠️ [loadFiles] Task cancelled AFTER fetching \(newFiles.count) files — results DISCARDED (user navigated away?)")
            await MainActor.run {
                isLoading = false
                downloadManager.resumeUpdates()
            }
            return
        }
        
        // Quick, simple update without animation
        await MainActor.run {
            // In progressive mode, files were already added via callback during pagination.
            // The final newFiles array has stat-enriched metadata — replace to upgrade placeholders.
            // In normal mode (ls worked), this is the first and only update.
            self.files = newFiles
            fileLoadError = nil
            storageRepairAvailable = false
            isLoading = false
            isLoadingMoreFiles = false
            downloadManager.resumeUpdates()  // Resume progress updates
            // Cache the directory listing
            cacheDirectory(path: pathSnapshot, files: newFiles)
        }
        if newFiles.isEmpty {
            AppLogger.log("⚠️ [loadFiles] ❗ UI set to EMPTY file list for path: \(pathSnapshot)")
        } else {
            AppLogger.log("📂 [loadFiles] ✅ UI updated with \(newFiles.count) files for path: \(pathSnapshot)")
        }


        
        // Now that files are loaded, fetch SD card and storage info in the background.
        // Doing this here prevents ADB contention during the critical file loading phase!
        Task {
            await deviceManager.detectSDCard()
            await deviceManager.fetchStorageInfo()
        }
        
        // ── Background metadata enrichment for large directories ────────────
        // Find files that came back without metadata (size == 0 and no date = placeholder)
        let filesNeedingMetadata = newFiles.filter { !$0.isDirectory && $0.size == 0 && $0.modificationDate == nil }
        if !filesNeedingMetadata.isEmpty {
            let fileNamesNeedingMeta = filesNeedingMetadata.map { $0.name }
            await MainActor.run {
                isLoadingMetadata = true
                metadataTotalCount = fileNamesNeedingMeta.count
                metadataLoadedCount = 0
            }
            
            metadataTask = Task.detached(priority: .utility) {
                await ADBManager.fetchMetadataBatched(
                    path: pathSnapshot,
                    fileNames: fileNamesNeedingMeta
                ) { batchFiles in
                    // Build a lookup dict from the batch results
                    let batchDict = Dictionary(batchFiles.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
                    
                    Task { @MainActor in
                        guard self.currentPath == pathSnapshot else { return }
                        
                        // Update existing files array in-place
                        var updatedFiles = self.files
                        for i in updatedFiles.indices {
                            if let updated = batchDict[updatedFiles[i].name] {
                                updatedFiles[i] = UnifiedFile(
                                    name: updated.name,
                                    path: updated.path,
                                    isDirectory: updated.isDirectory,
                                    size: updated.size,
                                    modificationDate: updated.modificationDate
                                )
                            }
                        }
                        self.files = updatedFiles
                        self.metadataLoadedCount += batchFiles.count
                        
                        // Update cache with enriched data
                        self.cacheDirectory(path: pathSnapshot, files: updatedFiles)
                    }
                }
                
                // Mark metadata loading complete
                await MainActor.run {
                    guard self.currentPath == pathSnapshot else { return }
                    self.isLoadingMetadata = false
                }
            }
        }
        
        // Fire-and-forget background folder sizing
        let dirsSnapshot = newFiles.filter { $0.isDirectory }
        
        // If folderSizes is already populated, we're refreshing after an operation
        if !folderSizes.isEmpty {
            folderSizes = [:]
        }
        _folderSizesBuffer = [:]
        folderSizeFlushTask?.cancel()
        
        Task.detached(priority: .background) {
            // Accumulate sizes in a local dict, flush to @State periodically
            var localBuffer: [String: UInt64] = [:]
            var lastFlush = Date()
            let flushInterval: TimeInterval = 0.5  // 500ms debounce
            
            await withTaskGroup(of: (String, UInt64?).self) { group in
                let maxConcurrent = 3
                var index = 0
                
                // Add initial tasks
                while index < min(maxConcurrent, dirsSnapshot.count) {
                    let dir = dirsSnapshot[index]
                    group.addTask { return (dir.path, await ADBManager.fetchSingleFolderSize(path: dir.path)) }
                    index += 1
                }
                
                // Process results and add more tasks
                for await (path, sizeOpt) in group {
                    if let size = sizeOpt {
                        localBuffer[path] = size
                    }
                    
                    // Flush to UI if enough time has passed
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= flushInterval {
                        let batch = localBuffer
                        localBuffer = [:]
                        lastFlush = now
                        await MainActor.run {
                            guard self.currentPath == pathSnapshot else { return }
                            self.folderSizes.merge(batch) { _, new in new }
                        }
                    }
                    
                    if index < dirsSnapshot.count {
                        let nextDir = dirsSnapshot[index]
                        group.addTask { return (nextDir.path, await ADBManager.fetchSingleFolderSize(path: nextDir.path)) }
                        index += 1
                    }
                }
            }
            
            // Final flush — any remaining sizes
            if !localBuffer.isEmpty {
                let remaining = localBuffer
                await MainActor.run {
                    guard self.currentPath == pathSnapshot else { return }
                    self.folderSizes.merge(remaining) { _, new in new }
                }
            }
        }
    }

    private func navigateTo(_ path: String) {
        // Cancel any in-progress load and metadata enrichment
        loadTask?.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        thumbnailProvider.cancelLoading()
        
        // Clear selection — navigating to a new folder means different files.
        selectedFiles.removeAll()
        
        pathHistory.append(currentPath)
        forwardHistory.removeAll()  // new navigation branch — clear forward stack
        currentPath = path
        fileLoadError = nil
        storageRepairAvailable = false
        isLoading = true
        isLoadingMetadata = false
        isLoadingMoreFiles = false
        folderSizes = [:]
        
        loadTask = Task.detached(priority: .userInitiated) {
            await self.loadFiles()
        }
    }

    private func navigateBack() {
        guard let previousPath = pathHistory.popLast() else { return }
        
        // Push current path to forward history so ⌘] can return here
        forwardHistory.append(currentPath)
        
        loadTask?.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        
        // Clear selection on back navigation for the same reason.
        selectedFiles.removeAll()
        
        currentPath = previousPath
        fileLoadError = nil
        storageRepairAvailable = false
        isLoadingMetadata = false
        isLoadingMoreFiles = false
        folderSizes = [:]
        
        // Try to use cached data for instant back-navigation
        if let cachedFiles = directoryCache[previousPath] {
            // Show cached data immediately — no loading spinner
            files = cachedFiles
            isLoading = false
            
            // Silently refresh in background
            loadTask = Task.detached(priority: .utility) {
                await self.loadFiles()
            }
        } else {
            isLoading = true
            loadTask = Task.detached(priority: .userInitiated) {
                await self.loadFiles()
            }
        }
    }

    private func navigateForward() {
        guard let nextPath = forwardHistory.popLast() else { return }
        
        loadTask?.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        selectedFiles.removeAll()
        
        // Push current path to back history
        pathHistory.append(currentPath)
        currentPath = nextPath
        fileLoadError = nil
        storageRepairAvailable = false
        isLoadingMetadata = false
        isLoadingMoreFiles = false
        folderSizes = [:]
        
        // Try to use cached data for instant navigation
        if let cachedFiles = directoryCache[nextPath] {
            files = cachedFiles
            isLoading = false
            loadTask = Task.detached(priority: .utility) {
                await self.loadFiles()
            }
        } else {
            isLoading = true
            loadTask = Task.detached(priority: .userInitiated) {
                await self.loadFiles()
            }
        }
    }

    private func handleMouseBackButton() {
        if filePreviewManager.showPreviewPanel {
            filePreviewManager.dismissPreview()
        }
        if showTrashView {
            showTrashView = false
            return
        }
        if activeAppFilter != nil {
            activeAppFilter = nil
            return
        }
        navigateBack()
    }

    private func handleMouseForwardButton() {
        if !filePreviewManager.showPreviewPanel && !showTrashView && activeAppFilter == nil {
            navigateForward()
        }
    }
    
    // MARK: - Diagnostic Upload Helpers



    // MARK: - Directory Cache Helpers
    
    private func cacheDirectory(path: String, files: [UnifiedFile]) {
        // Remove existing entry from order tracking if it exists
        directoryCacheOrder.removeAll { $0 == path }
        
        // Add to end (most recent)
        directoryCacheOrder.append(path)
        directoryCache[path] = files
        
        // Evict oldest entries if cache exceeds 10
        while directoryCacheOrder.count > 10 {
            let oldest = directoryCacheOrder.removeFirst()
            directoryCache.removeValue(forKey: oldest)
        }
    }
    
    private func invalidateCache(for path: String) {
        directoryCache.removeValue(forKey: path)
        directoryCacheOrder.removeAll { $0 == path }
    }
    
    private func handleDownload(file: UnifiedFile) {
        // Capture manager so the closure does not capture self strongly
        let manager = self.downloadManager

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = file.name
        savePanel.title = "Save File"
        savePanel.message = "Choose where to save \(file.name)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task {
                do {
                    try await manager.downloadFile(
                        devicePath: file.path,
                        fileName: file.name,
                        fileSize: file.size,   // ✅ this was missing
                        to: url.path
                    )
                } catch {
                    print("❌ Download failed: \(error)")
                }
            }
        }
    }
    
    private func handleMoveFiles(files: [UnifiedFile], destination: String) {
        Task {
            do {
                try await fileActionManager.moveFiles(files, to: destination)
            } catch {
                AppLogger.log("❌ [handleMoveFiles] Move failed: \(error.localizedDescription)", level: .error)
                presentFileOperationError(error)
            }
            await loadFiles()
            if isDualPaneEnabled {
                await loadSecondaryFiles()
            }
            await deviceManager.fetchStorageInfo()
        }
    }

    private func handleUpload(urls: [URL], destinationPath: String? = nil) {
        let manager = self.uploadManager
        let path = destinationPath ?? self.currentPath

        // Show immediate feedback so the user doesn't stare at a blank screen
        Task { @MainActor in
            manager.isPreparing = true
            manager.preparingMessage = "Preparing upload…"
        }

        Task {
            AppLogger.log("📂 [handleUpload] Starting upload for \(urls.count) URLs. Target destination path: \(path)")
            var allItems: [(localPath: String, fileName: String, fileSize: UInt64, devicePath: String)] = []
            var remoteDirsToCreate: Set<String> = []

            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                    AppLogger.log("⚠️ [handleUpload] File does not exist at local path: \(url.path)", level: .warning)
                    continue
                }

                if isDir.boolValue {
                    AppLogger.log("📂 [handleUpload] Processing local directory: \(url.path)")
                    let basePath = url.path
                    let remoteFolderBase = (path.hasSuffix("/") ? path : path + "/") + url.lastPathComponent
                    remoteDirsToCreate.insert(remoteFolderBase)

                    guard let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                        options: []
                    ) else {
                        AppLogger.log("⚠️ [handleUpload] Failed to create directory enumerator for: \(url.path)", level: .warning)
                        continue
                    }

                    var folderFilesCount = 0
                    for case let fileURL as URL in enumerator {
                        guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
                            continue
                        }

                        let isDir = rv.isDirectory ?? false
                        if isDir {
                            continue
                        }

                        guard rv.isRegularFile == true else { continue }

                        let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
                        let remoteFilePath = remoteFolderBase + "/" + relativePath
                        let remoteDir = (remoteFilePath as NSString).deletingLastPathComponent
                        remoteDirsToCreate.insert(remoteDir)

                        let size = UInt64(rv.fileSize ?? 0)
                        let fileName = (relativePath as NSString).lastPathComponent
                        allItems.append((localPath: fileURL.path, fileName: fileName, fileSize: size, devicePath: remoteDir))
                        folderFilesCount += 1
                    }
                    AppLogger.log("📂 [handleUpload] Enumerated directory: \(url.path) — found \(folderFilesCount) files")
                } else {
                    AppLogger.log("📂 [handleUpload] Processing local file: \(url.path)")
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let size = attrs[.size] as? UInt64 else {
                        AppLogger.log("⚠️ [handleUpload] Failed to retrieve attributes for local file: \(url.path)", level: .warning)
                        continue
                    }
                    allItems.append((localPath: url.path, fileName: url.lastPathComponent, fileSize: size, devicePath: path))
                }
            }

            AppLogger.log("📂 [handleUpload] Collected \(allItems.count) files to upload.")

            guard !allItems.isEmpty else {
                AppLogger.log("⚠️ [handleUpload] No files collected for upload. Exiting.", level: .warning)
                await MainActor.run { manager.isPreparing = false }
                return
            }

            let adb = ADBManager.getADBPath()

            func fullDevicePath(_ item: (localPath: String, fileName: String, fileSize: UInt64, devicePath: String)) -> String {
                let (safeName, _) = FileNameHelper.getSafeFilename(item.fileName)
                return item.devicePath.hasSuffix("/")
                    ? item.devicePath + safeName
                    : item.devicePath + "/" + safeName
            }

            await MainActor.run {
                manager.preparingMessage = "Checking for conflicts (\(allItems.count) files)…"
            }

            var conflictingPaths = Set<String>()
            let allDevicePaths = allItems.map { fullDevicePath($0) }
            let chunkSize = 50
            for chunkStart in stride(from: 0, to: allDevicePaths.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, allDevicePaths.count)
                let chunk = Array(allDevicePaths[chunkStart..<chunkEnd])
                
                let checks = chunk.map { path in
                    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                    return "[ -e '\(escaped)' ] && echo '\(escaped)'"
                }.joined(separator: "; ")
                
                let (code, out, _) = await Shell.runAsync(
                    adb,
                    args: ADBManager.deviceArgs(["shell", checks])
                )
                if code == 0 {
                    for line in out.split(separator: "\n") {
                        let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !path.isEmpty { conflictingPaths.insert(path) }
                    }
                }
            }

            await MainActor.run { manager.isPreparing = false }

            if !conflictingPaths.isEmpty {
                let conflictNames = allItems
                    .filter { conflictingPaths.contains(fullDevicePath($0)) }
                    .map { $0.fileName }

                try? await Task.sleep(nanoseconds: 350_000_000)

                let choice = await MainActor.run {
                    ConflictDialog.show(conflictNames: conflictNames, totalCount: allItems.count)
                }

                switch choice {
                case .replace: break
                case .skip:
                    allItems = allItems.filter { !conflictingPaths.contains(fullDevicePath($0)) }
                case .cancel: return
                }
            }

            guard !allItems.isEmpty else { return }

            let totalBytes = allItems.reduce(UInt64(0)) { $0 + $1.fileSize }
            
            // Storage Capacity Pre-flight Check
            let resolvedStorageRoot = AndroidStorageAccess.storageRoot(for: path)
                ?? "/" + path.split(separator: "/").prefix(2).joined(separator: "/")
            
            if let stats = await MainActor.run(body: { self.deviceManager.storageStats[resolvedStorageRoot] }) {
                let freeBytes = UInt64(stats.totalBytes - stats.usedBytes)
                if totalBytes > freeBytes {
                    let requiredSize = formatBytes(totalBytes)
                    let availableSize = formatBytes(freeBytes)
                    let deficit = formatBytes(totalBytes - freeBytes)
                    
                    // Let macOS finish drag-and-drop cleanup before blocking with modal
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Not Enough Storage"
                        alert.informativeText = "You are trying to upload \(requiredSize), but only \(availableSize) is available on the device.\n\nPlease free up at least \(deficit) before uploading."
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                    return
                }
            }


            if !remoteDirsToCreate.isEmpty {
                await ADBManager.batchCreateFolders(paths: Array(remoteDirsToCreate))
                // Refresh list immediately so the newly created folders appear on screen
                await loadFiles()
            }

            manager.enqueueFiles(files: allItems)
        }
    }

    
    private func handleDelete(_ file: UnifiedFile) {
        files.removeAll { $0.id == file.id }
        secondaryFiles.removeAll { $0.id == file.id }
        updateDisplayedFiles()
        updateSecondaryDisplayedFiles()
        selectedFiles.remove(file.id)
        secondarySelectedFiles.remove(file.id)
        
        Task {
            do {
                try await fileActionManager.deleteFile(file)
                ADBManager.invalidateFolderSizeCache()
                await deviceManager.fetchStorageInfo()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
                await loadFiles()
                if isDualPaneEnabled {
                    await loadSecondaryFiles()
                }
            }
        }
    }
    
    private func handleRename(_ file: UnifiedFile, newName: String) {
        Task {
            do {
                try await fileActionManager.renameFile(file, to: newName)
                
                // Invalidate cache and refresh
                ADBManager.invalidateFolderSizeCache()
                await loadFiles()
                if isDualPaneEnabled {
                    await loadSecondaryFiles()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
    
    // MARK: - Batch Operations
    
    private func handleBatchDelete() {
        let filesToDelete = files.filter { selectedFiles.contains($0.id) }
        guard !filesToDelete.isEmpty else { return }
        
        let deletedIDs = Set(filesToDelete.map { $0.id })
        files.removeAll { deletedIDs.contains($0.id) }
        updateDisplayedFiles()
        selectedFiles.removeAll()
        
        Task {
            do {
                try await fileActionManager.deleteFiles(filesToDelete)
                ADBManager.invalidateFolderSizeCache()
                await deviceManager.fetchStorageInfo()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
                await loadFiles()
            }
        }
    }

    private func handlePermanentDelete(files filesToDelete: [UnifiedFile]? = nil) {
        let targets = filesToDelete ?? files.filter { selectedFiles.contains($0.id) }
        guard !targets.isEmpty else { return }
        
        let deletedIDs = Set(targets.map { $0.id })
        files.removeAll { deletedIDs.contains($0.id) }
        updateDisplayedFiles()
        selectedFiles.subtract(deletedIDs)
        
        Task {
            do {
                try await fileActionManager.deleteFiles(targets, permanent: true)
                ADBManager.invalidateFolderSizeCache()
                await deviceManager.fetchStorageInfo()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
                await loadFiles()
            }
        }
    }
    
    private func handleBatchDownload() {
        let isSec = (activePane == .secondary && isDualPaneEnabled)
        let sourceFiles = isSec ? secondaryFiles : files
        let sourceSelected = isSec ? secondarySelectedFiles : selectedFiles
        let selectedItems = sourceFiles.filter { sourceSelected.contains($0.id) }
        
        guard !selectedItems.isEmpty else {
            errorMessage = "No files or folders selected."
            showErrorAlert = true
            return
        }
        
        let selectedFolders = selectedItems.filter { $0.isDirectory }
        let selectedFileItems = selectedItems.filter { !$0.isDirectory }
        
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Download Folder"
        openPanel.message = "Choose where to save \(selectedItems.count) item(s)"
        
        openPanel.begin { response in
            guard response == .OK, let directory = openPanel.url else { return }
            
            Task.detached(priority: .userInitiated) {
                
                // Build one unified download list
                var allItems: [(devicePath: String, fileName: String, fileSize: UInt64, localPath: String)] = []
                
                // 1. Add individual files
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for file in selectedFileItems {
                    let localFileURL = directory.appendingPathComponent(file.name)
                    allItems.append((
                        devicePath: file.path,
                        fileName: file.name,
                        fileSize: file.size,
                        localPath: localFileURL.path
                    ))
                }
                
                // 2. Scan each folder and add its contents
                for folder in selectedFolders {
                    // Show scanning state
                    await MainActor.run {
                        downloadManager.isScanning = true
                        downloadManager.scanningFolderName = folder.name
                    }
                    
                    do {
                        let folderFiles = try await ADBManager.listAllFilesRecursively(path: folder.path)
                        let destination = directory.appendingPathComponent(folder.name)
                        
                        for file in folderFiles {
                            let localFileURL = destination.appendingPathComponent(file.relativePath)
                            let localDir = localFileURL.deletingLastPathComponent()
                            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
                            
                            let fileName = (file.relativePath as NSString).lastPathComponent
                            allItems.append((
                                devicePath: file.devicePath,
                                fileName: fileName,
                                fileSize: file.size,
                                localPath: localFileURL.path
                            ))
                        }
                    } catch {
                        print("❌ Failed to scan folder \(folder.name): \(error)")
                    }
                }
                
                await MainActor.run {
                    downloadManager.isScanning = false
                    downloadManager.scanningFolderName = ""
                }
                
                guard !allItems.isEmpty else {
                    await MainActor.run {
                        errorMessage = "No files found to download."
                        showErrorAlert = true
                    }
                    return
                }
                
                // Set folder name for UI if we downloaded any folders
                if !selectedFolders.isEmpty {
                    await MainActor.run {
                        downloadManager.currentFolderName = selectedFolders.count == 1
                            ? selectedFolders.first!.name
                            : "\(selectedFolders.count) folders"
                    }
                }
                
                // Single unified download call — correct count from the start
                await downloadManager.downloadMultipleFiles(files: allItems)
                await MainActor.run { selectedFiles.removeAll() }
            }
        }
    }
    
    private func handleFolderDownload(_ folder: UnifiedFile) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Download Location"
        openPanel.message = "Folder '\(folder.name)' will be saved here, preserving its structure."
        
        openPanel.begin { response in
            guard response == .OK, let directory = openPanel.url else { return }
            let destination = directory.appendingPathComponent(folder.name)
            
            Task.detached(priority: .userInitiated) {
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                await downloadManager.downloadFolder(
                    devicePath: folder.path,
                    folderName: folder.name,
                    to: destination
                )
            }
        }
    }
    
    private func handleBatchChangeExtension(_ newExtension: String, inSecondary: Bool = false) {
        let isSec = inSecondary || (activePane == .secondary && isDualPaneEnabled)
        let sourceFiles = isSec ? secondaryFiles : files
        let sourceSelected = isSec ? secondarySelectedFiles : selectedFiles
        let filesToChange = sourceFiles.filter { sourceSelected.contains($0.id) && !$0.isDirectory }
        
        guard !filesToChange.isEmpty else {
            errorMessage = "No files selected for extension change"
            showErrorAlert = true
            return
        }
        
        Task {
            var successCount = 0
            var failCount = 0
            
            for file in filesToChange {
                // Get filename without extension
                let nameWithoutExt: String
                if let dotIndex = file.name.lastIndex(of: ".") {
                    nameWithoutExt = String(file.name[..<dotIndex])
                } else {
                    nameWithoutExt = file.name
                }
                
                let newName = "\(nameWithoutExt).\(newExtension)"
                
                do {
                    try await fileActionManager.renameFile(file, to: newName)
                    successCount += 1
                } catch {
                    print("❌ Failed to rename \(file.name): \(error)")
                    failCount += 1
                }
            }
            
            // Refresh and clear selection
            if isSec {
                await loadSecondaryFiles()
            } else {
                await loadFiles()
            }
            await MainActor.run {
                if isSec {
                    secondarySelectedFiles.removeAll()
                } else {
                    selectedFiles.removeAll()
                }
                
                if failCount > 0 {
                    errorMessage = "Changed \(successCount) files, \(failCount) failed"
                    showErrorAlert = true
                }
            }
        }
    }
}

struct LiveOperationRow: View {
    let op: OperationEngine.LiveOperation
    
    var stateIconName: String {
        switch op.state {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed(let success, let message):
            if message == "Cancelled" { return "slash.circle" }
            return success ? "checkmark.circle" : "xmark.circle"
        }
    }
    
    var stateColor: Color {
        switch op.state {
        case .pending: return .secondary
        case .running: return .blue
        case .completed(let success, let message):
            if message == "Cancelled" { return .secondary }
            return success ? .green : .red
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: stateIconName)
                .font(.system(size: 10))
                .foregroundColor(stateColor)
            Text(op.displayName)
                .font(.system(size: 10))
            Spacer()
            if case .running = op.state {
                LoadingSpinner(size: 12)
            }
        }
        .padding(.leading, 8)
    }
}

/// Animates a progress bar segment back and forth (indeterminate progress indicator).
/// Used by the reconnection banner to show ongoing activity.
struct IndeterminateProgressModifier: ViewModifier, Animatable {
    let containerWidth: CGFloat
    @State private var offset: CGFloat = 0
    
    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: true)
                ) {
                    offset = containerWidth * 0.7
                }
            }
    }
}

// MARK: - Mouse Navigation Coordinator (Back/Forward Side Buttons)

@MainActor
final class MouseNavigationCoordinator: ObservableObject {
    private var monitor: Any?
    var onBack: (() -> Void)?
    var onForward: (() -> Void)?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown]) { [weak self] event in
            // Button 3: Standard Mouse Back button
            if event.buttonNumber == 3 {
                Task { @MainActor [weak self] in
                    self?.onBack?()
                }
                return nil
            } else if event.buttonNumber == 4 {
                // Button 4: Standard Mouse Forward button
                Task { @MainActor [weak self] in
                    self?.onForward?()
                }
                return nil
            }
            return event
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
    }
}

