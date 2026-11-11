// Views/AppBrowserView.swift
// Main app management interface shown when an Apps sidebar entry is selected

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppBrowserView: View {
    @ObservedObject var appManager: AppManager
    let initialFilter: AppFilter
    let deviceName: String

    @State private var selectedFilter: AppFilter
    @Binding var searchQuery: String
    @State private var selectedPackages: Set<String> = []
    @State private var sortOption: AppSortOption = .name
    
    // Warning popup state variables
    @State private var showADBInstallWarning = false
    @State private var dontShowWarningAgainLocal = false

    enum AppSortOption: String, CaseIterable {
        case name    = "Name"
        case package = "Package"

        var localizedKey: LocalizedStringKey {
            switch self {
            case .name: return "app_browser_sort_name"
            case .package: return "app_browser_sort_package"
            }
        }
    }

    init(appManager: AppManager, initialFilter: AppFilter, deviceName: String, searchQuery: Binding<String>) {
        self.appManager = appManager
        self.initialFilter = initialFilter
        self.deviceName = deviceName
        _selectedFilter = State(initialValue: initialFilter)
        _searchQuery = searchQuery
    }

    // MARK: - Filtered + Sorted apps

    private var displayedApps: [AppInfo] {
        var result = appManager.apps

        if !searchQuery.isEmpty {
            result = result.filter {
                $0.displayName.localizedCaseInsensitiveContains(searchQuery) ||
                $0.packageName.localizedCaseInsensitiveContains(searchQuery)
            }
        }

        switch sortOption {
        case .name:    result.sort { $0.displayName.lowercased() < $1.displayName.lowercased() }
        case .package: result.sort { $0.packageName < $1.packageName }
        }

        return result
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .confirmationDialog(
                    appManager.batchConfirmTitle,
                    isPresented: $appManager.showBatchConfirm,
                    titleVisibility: .visible
                ) {
                    Button(appManager.batchConfirmActionLabel, role: .destructive) {
                        appManager.confirmBatchAction()
                        selectedPackages = []
                    }
                    Button("common_cancel", role: .cancel) {}
                } message: {
                    Text(appManager.batchConfirmMessage)
                }
            Divider()
            content
                .confirmationDialog(
                    appManager.confirmTitle,
                    isPresented: $appManager.showActionConfirm,
                    titleVisibility: .visible
                ) {
                    Button(appManager.confirmLabel, role: .destructive) {
                        appManager.confirmSingleAction()
                    }
                    Button("common_cancel", role: .cancel) {}
                } message: {
                    Text(appManager.confirmMessage)
                }
        }
        .task(id: selectedFilter.rawValue + "|" + deviceName) {
            await appManager.fetchApps(filter: selectedFilter)
            selectedPackages = []
        }
        .alert(String.localized("common_result"), isPresented: $appManager.showAlert) {
            Button("common_ok", role: .cancel) {}
        } message: {
            Text(appManager.alertMessage)
        }
        .sheet(isPresented: $showADBInstallWarning) {
            adbInstallWarningSheet
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            // Filter picker
            Picker("", selection: $selectedFilter) {
                ForEach(AppFilter.allCases) { filter in
                    Label(LocalizedStringKey(filter.localizedKey), systemImage: filter.icon).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)

            Spacer()

            // Install APK button
            Button {
                Task { await handleInstallClick() }
            } label: {
                Label("app_browser_btn_install_apk", systemImage: "plus.app")
                    .font(.system(size: 12))
            }
            .buttonStyle(.bordered)
            .help(Text("app_browser_help_install_apk"))

            if !selectedPackages.isEmpty {
                let hasBusySelected = selectedPackages.contains { appManager.isPackageBusy($0) }
                Button {
                    appManager.handleBatchToolbarClick(selectedPackages: selectedPackages, currentFilter: selectedFilter)
                } label: {
                    Label(batchButtonLabel, systemImage: batchButtonIcon)
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .tint(batchButtonTint)
                .disabled(hasBusySelected)
            }

            // Sort
            Menu {
                ForEach(AppSortOption.allCases, id: \.self) { opt in
                    Button {
                        sortOption = opt
                    } label: {
                        HStack {
                            Text(opt.localizedKey)
                            if sortOption == opt {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .help(Text("common_sort_apps"))

            // Refresh
            Button {
                Task { await appManager.fetchApps(filter: selectedFilter) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help(Text("app_browser_help_refresh_apps"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if appManager.isLoading {
            // ── Loading state — full-page spinner ────────────────────────────
            Spacer()
            VStack(spacing: 12) {
                ProgressView().scaleEffect(1.2)
                Text(appManager.statusMessage)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            Spacer()
        } else if let error = appManager.errorMessage {
            // ── Error state ──────────────────────────────────────────────────
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundColor(.orange)
                Text(error)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            .padding()
            Spacer()
        } else {
            // ── Loaded — always show search + status + list ──────────────────
            VStack(spacing: 0) {
                // Status bar
                HStack {
                    Text(appManager.statusMessage)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !selectedPackages.isEmpty {
                        Text(String.localized("common_selected_count_format", selectedPackages.count))
                            .font(.system(size: 11))
                            .foregroundColor(.blue)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

                Divider()

                // List area — shows empty state OR app rows
                if displayedApps.isEmpty {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(searchQuery.isEmpty ? String.localized("app_browser_empty_message") : String.localized("file_browser_no_results_format", searchQuery))
                            .foregroundColor(.secondary)
                        if !searchQuery.isEmpty {
                            Button("common_clear_search") { searchQuery = "" }
                                .buttonStyle(.bordered)
                                .font(.system(size: 12))
                        }
                    }
                    Spacer()
                } else {
                    List(displayedApps, id: \.id, selection: $selectedPackages) { app in
                        AppRowView(app: app, appManager: appManager, selectedPackages: selectedPackages) { action in
                            appManager.handleAction(action, app: app, selectedPackages: selectedPackages, currentFilter: selectedFilter)
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    // MARK: - Actions

    enum AppAction {
        case uninstall
        case disable
        case enable
        case backupAPK
        case clearData
        case clearCache
        case forceStop
    }



    // MARK: - Batch confirmation helpers (context-aware by filter & count)

    private var selectedApps: [AppInfo] {
        appManager.apps.filter { selectedPackages.contains($0.packageName) }
    }

    enum BatchAction {
        case uninstall
        case disable
        case enable
        case mixed
    }

    private var currentBatchAction: BatchAction {
        let apps = selectedApps
        guard !apps.isEmpty else { return .uninstall }
        
        let allDisabled = apps.allSatisfy { !$0.isEnabled }
        if allDisabled { return .enable }
        
        let systemApps = apps.filter { $0.isSystemApp }
        let userApps = apps.filter { !$0.isSystemApp }
        
        if userApps.isEmpty {
            let hasEnabled = apps.contains { $0.isEnabled }
            return hasEnabled ? .disable : .enable
        } else if systemApps.isEmpty {
            let hasEnabled = apps.contains { $0.isEnabled }
            return hasEnabled ? .uninstall : .enable
        } else {
            let hasEnabled = apps.contains { $0.isEnabled }
            return hasEnabled ? .mixed : .enable
        }
    }

    private var batchButtonLabel: String {
        let n = selectedPackages.count
        switch currentBatchAction {
        case .disable:   return n == 1 ? "Disable (1)" : "Disable (\(n))"
        case .enable:    return n == 1 ? "Enable (1)"  : "Enable (\(n))"
        case .uninstall: return n == 1 ? "Uninstall (1)" : "Uninstall (\(n))"
        case .mixed:     return n == 1 ? "Uninstall/Disable (1)" : "Uninstall/Disable (\(n))"
        }
    }

    private var batchButtonIcon: String {
        switch currentBatchAction {
        case .disable:   return "nosign"
        case .enable:    return "checkmark.circle"
        case .uninstall: return "trash"
        case .mixed:     return "trash.slash"
        }
    }

    private var batchButtonTint: Color {
        switch currentBatchAction {
        case .disable:   return .orange
        case .enable:    return .green
        case .uninstall: return .red
        case .mixed:     return .red
        }
    }

    private func pickAndInstallAPK() async {
        let panel = NSOpenPanel()
        panel.title = "Select APK to Install"
        let apkType = UTType(tag: "apk", tagClass: .filenameExtension, conformingTo: .data) ?? .data
        let xapkType = UTType(tag: "xapk", tagClass: .filenameExtension, conformingTo: .data) ?? .data
        let apksType = UTType(tag: "apks", tagClass: .filenameExtension, conformingTo: .data) ?? .data
        let apkmType = UTType(tag: "apkm", tagClass: .filenameExtension, conformingTo: .data) ?? .data
        panel.allowedContentTypes = [apkType, xapkType, apksType, apkmType, .zip]
        panel.allowsMultipleSelection = false

        guard await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow()) == .OK,
              let url = panel.url else { return }

        appManager.queueInstall(url: url, currentFilter: selectedFilter)
    }
    
    private func handleInstallClick() async {
        let dontShowAgain = UserDefaults.standard.bool(forKey: "ADBInstallWarningDontShowAgain")
        if dontShowAgain || AppManager.hasShownADBInstallWarningInSession {
            await pickAndInstallAPK()
        } else {
            dontShowWarningAgainLocal = false
            showADBInstallWarning = true
        }
    }
    
    private var adbInstallWarningSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.orange)
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("app_browser_install_warning_title")
                        .font(.headline)
                    
                    Text("app_browser_install_warning_step1")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text("app_browser_install_warning_step2")
                        .font(.body)
                        .foregroundColor(.primary)
                        .fontWeight(.semibold)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text("app_browser_install_warning_brand_note")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            
            Divider()
            
            HStack {
                Toggle("app_browser_dont_show_again", isOn: $dontShowWarningAgainLocal)
                    .toggleStyle(.checkbox)
                    .font(.subheadline)
                
                Spacer()
                
                Button("common_cancel") {
                    showADBInstallWarning = false
                }
                .keyboardShortcut(.cancelAction)
                
                Button("common_proceed") {
                    showADBInstallWarning = false
                    AppManager.hasShownADBInstallWarningInSession = true
                    if dontShowWarningAgainLocal {
                        UserDefaults.standard.set(true, forKey: "ADBInstallWarningDontShowAgain")
                    }
                    Task {
                        await pickAndInstallAPK()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

// MARK: - App Row

struct AppRowView: View {
    let app: AppInfo
    @ObservedObject var appManager: AppManager
    let selectedPackages: Set<String>
    let onAction: (AppBrowserView.AppAction) -> Void

    private var batchActionType: AppBrowserView.BatchAction? {
        guard selectedPackages.contains(app.packageName), selectedPackages.count > 1 else { return nil }
        
        let apps = appManager.apps.filter { selectedPackages.contains($0.packageName) }
        guard !apps.isEmpty else { return nil }
        
        let allDisabled = apps.allSatisfy { !$0.isEnabled }
        if allDisabled { return .enable }
        
        let systemApps = apps.filter { $0.isSystemApp }
        let userApps = apps.filter { !$0.isSystemApp }
        
        if userApps.isEmpty {
            let hasEnabled = apps.contains { $0.isEnabled }
            return hasEnabled ? .disable : .enable
        } else if systemApps.isEmpty {
            let hasEnabled = apps.contains { $0.isEnabled }
            return hasEnabled ? .uninstall : .enable
        } else {
            let hasEnabled = apps.contains { $0.isEnabled }
            return hasEnabled ? .mixed : .enable
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // App icon — real if available, placeholder otherwise
            Group {
                if let realIcon = appManager.appIcons[app.packageName] {
                    Image(nsImage: realIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    // Letter-avatar placeholder: first letter + unique gradient per package
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(
                                LinearGradient(
                                    colors: [avatarColor, avatarColor.opacity(0.7)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 36, height: 36)
                        Text(String(app.displayName.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                // Name + status badges
                HStack(spacing: 6) {
                    Text(app.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(app.isEnabled ? .primary : .secondary)

                    if !app.isEnabled {
                        Text("Disabled")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }

                    if app.isSystemApp {
                        Text("System")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(4)
                    }
                }

                // Package name
                Text(app.packageName)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if appManager.operationEngine.isPackageBusy(app.packageName) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .contextMenu {
            if appManager.isPackageBusy(app.packageName) {
                Button {} label: {
                    Label("Operation in progress…", systemImage: "hourglass")
                }
                .disabled(true)
            } else if let batchAction = batchActionType {
                // ── Batch selection primary action ─────────────────────────────────
                switch batchAction {
                case .enable:
                    Button {
                        onAction(.enable)
                    } label: {
                        Label("Enable Apps", systemImage: "checkmark.circle")
                    }
                case .disable:
                    Button(role: .destructive) {
                        onAction(.disable)
                    } label: {
                        Label("Disable System Apps", systemImage: "nosign")
                    }
                case .uninstall:
                    Button(role: .destructive) {
                        onAction(.uninstall)
                    } label: {
                        Label("Uninstall Apps", systemImage: "trash")
                    }
                case .mixed:
                    Button(role: .destructive) {
                        onAction(.uninstall)
                    } label: {
                        Label("Uninstall/Disable Apps", systemImage: "trash.slash")
                    }
                }
            } else {
                // ── Single app primary action ──────────────────────────────────────
                if !app.isEnabled {
                    // Disabled app → only action is to enable
                    Button {
                        onAction(.enable)
                    } label: {
                        Label("Enable App", systemImage: "checkmark.circle")
                    }
                } else if app.isSystemApp {
                    // Enabled system app → can disable (soft-remove for user)
                    Button(role: .destructive) {
                        onAction(.disable)
                    } label: {
                        Label("Disable System App", systemImage: "nosign")
                    }
                } else {
                    // Regular user app → can uninstall
                    Button(role: .destructive) {
                        onAction(.uninstall)
                    } label: {
                        Label("Uninstall", systemImage: "trash")
                    }
                }
            }

            Divider()

            // ── Common actions ─────────────────────────────────────────────────
            Button {
                onAction(.backupAPK)
            } label: {
                Label("Backup APK to Mac", systemImage: "square.and.arrow.down")
            }

            Button {
                onAction(.forceStop)
            } label: {
                Label("Force Stop", systemImage: "stop.circle")
            }

            Divider()

            Button {
                onAction(.clearCache)
            } label: {
                Label("Clear Cache", systemImage: "trash.slash")
            }

            Button(role: .destructive) {
                onAction(.clearData)
            } label: {
                Label("Clear Data & Cache", systemImage: "externaldrive.badge.xmark")
            }
        }
    }

    /// Stable unique color derived from the package name hash.
    /// Gives each app a distinct, visually pleasant avatar background.
    private var avatarColor: Color {
        let palette: [Color] = [
            Color(hue: 0.00, saturation: 0.65, brightness: 0.75),
            Color(hue: 0.05, saturation: 0.70, brightness: 0.80),
            Color(hue: 0.08, saturation: 0.75, brightness: 0.80),
            Color(hue: 0.13, saturation: 0.70, brightness: 0.78),
            Color(hue: 0.28, saturation: 0.60, brightness: 0.60),
            Color(hue: 0.35, saturation: 0.65, brightness: 0.58),
            Color(hue: 0.50, saturation: 0.65, brightness: 0.65),
            Color(hue: 0.55, saturation: 0.60, brightness: 0.75),
            Color(hue: 0.60, saturation: 0.55, brightness: 0.80),
            Color(hue: 0.65, saturation: 0.60, brightness: 0.75),
            Color(hue: 0.72, saturation: 0.58, brightness: 0.72),
            Color(hue: 0.78, saturation: 0.55, brightness: 0.72),
            Color(hue: 0.85, saturation: 0.55, brightness: 0.72),
            Color(hue: 0.92, saturation: 0.60, brightness: 0.75),
        ]
        let hash = abs(app.packageName.hashValue)
        return palette[hash % palette.count]
    }
}
