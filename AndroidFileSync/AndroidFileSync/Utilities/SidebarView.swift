import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sidebar Drag & Click Manager

@MainActor
final class SidebarDragState: NSObject, NSDraggingSource {
    static let shared = SidebarDragState()

    var draggedItem: QuickAccessItem? = nil
    var draggedGroupId: String? = nil

    var currentPath: String = ""
    var hasActiveAppFilter: Bool = false

    var onSelectFolder: ((String, String) -> Void)? = nil
    var onSelectApps: (() -> Void)? = nil
    var onItemMovedToGroup: ((String, String) -> Void)? = nil

    private let rowViews = NSHashTable<SidebarRowTrackingNSView>.weakObjects()
    private var mouseMonitor: Any? = nil

    private weak var mouseDownView: SidebarRowTrackingNSView? = nil
    private var mouseDownItem: QuickAccessItem? = nil
    private var mouseDownGroupId: String? = nil
    private var mouseDownPoint: NSPoint? = nil
    private var lastMouseDownEvent: NSEvent? = nil
    private var didStartDrag: Bool = false

    func installMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return self.handleMouseEvent(event)
        }
    }

    func removeMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
        resetMouseTracking()
    }

    private func resetMouseTracking() {
        mouseDownView = nil
        mouseDownItem = nil
        mouseDownGroupId = nil
        mouseDownPoint = nil
        lastMouseDownEvent = nil
        didStartDrag = false
    }

    func startDrag(item: QuickAccessItem, groupId: String) {
        self.draggedItem = item
        self.draggedGroupId = groupId
    }

    func clear() {
        self.draggedItem = nil
        self.draggedGroupId = nil
    }

    func registerRowView(_ view: SidebarRowTrackingNSView) {
        rowViews.add(view)
    }

    func unregisterRowView(_ view: SidebarRowTrackingNSView) {
        rowViews.remove(view)
    }

    func hitTestRowView(windowPoint: NSPoint, in window: NSWindow?) -> SidebarRowTrackingNSView? {
        guard let window else { return nil }
        for view in rowViews.allObjects {
            guard view.window === window,
                  !view.isHiddenOrHasHiddenAncestor,
                  !view.groupId.isEmpty else { continue }
            if view.containsWindowPoint(windowPoint) {
                return view
            }
        }
        return nil
    }

    private func handleMouseEvent(_ event: NSEvent) -> NSEvent? {
        guard NSApp.modalWindow == nil,
              let window = event.window,
              window.isKeyWindow,
              window.attachedSheet == nil else {
            resetMouseTracking()
            return event
        }

        switch event.type {
        case .leftMouseDown:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Allow Control+click to trigger the context menu normally
            guard !flags.contains(.control) else {
                resetMouseTracking()
                return event
            }
            guard let rowView = hitTestRowView(windowPoint: event.locationInWindow, in: window) else {
                resetMouseTracking()
                return event
            }
            mouseDownView = rowView
            mouseDownItem = rowView.item
            mouseDownGroupId = rowView.groupId
            mouseDownPoint = event.locationInWindow
            lastMouseDownEvent = event
            didStartDrag = false
            // Consume leftMouseDown on sidebar shortcut rows so NSOutlineView does not
            // hijack the drag or swallow the first click after a drag-and-drop.
            return nil

        case .leftMouseDragged:
            guard let downPt = mouseDownPoint else { return event }
            if didStartDrag {
                return nil
            }
            let distance = hypot(event.locationInWindow.x - downPt.x, event.locationInWindow.y - downPt.y)
            guard distance > 3 else {
                return nil
            }
            didStartDrag = true
            guard let view = mouseDownView,
                  let item = mouseDownItem,
                  let groupId = mouseDownGroupId else {
                resetMouseTracking()
                return nil
            }
            let dragEvt = lastMouseDownEvent ?? event
            resetMouseTracking()
            beginSidebarDragSession(item: item, groupId: groupId, from: view, event: dragEvt)
            return nil

        case .leftMouseUp:
            clear()
            guard let downPt = mouseDownPoint,
                  let groupId = mouseDownGroupId else {
                resetMouseTracking()
                return event
            }
            let item = mouseDownItem
            let wasDrag = didStartDrag
            resetMouseTracking()

            if !wasDrag {
                let distance = hypot(event.locationInWindow.x - downPt.x, event.locationInWindow.y - downPt.y)
                if distance <= 6 {
                    if groupId == "__apps__" {
                        onSelectApps?()
                    } else if let item {
                        onSelectFolder?(groupId, item.path)
                    }
                } else if let upView = hitTestRowView(windowPoint: event.locationInWindow, in: window),
                          upView.groupId == groupId,
                          upView.item?.path == item?.path {
                    if groupId == "__apps__" {
                        onSelectApps?()
                    } else if let item {
                        onSelectFolder?(groupId, item.path)
                    }
                }
            }
            return nil

        default:
            return event
        }
    }

    private func beginSidebarDragSession(
        item: QuickAccessItem,
        groupId: String,
        from view: NSView,
        event: NSEvent
    ) {
        self.draggedItem = item
        self.draggedGroupId = groupId

        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString("sidebar-item:" + item.id, forType: .string)

        let dragItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        let image = Self.createDragImage(for: item)
        let mouseInView = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(
            x: mouseInView.x - 18,
            y: mouseInView.y - image.size.height / 2,
            width: image.size.width,
            height: image.size.height
        )
        dragItem.setDraggingFrame(frame, contents: image)

        let session = view.beginDraggingSession(with: [dragItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
    }

    private static func createDragImage(for item: QuickAccessItem) -> NSImage {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let textSize = (item.name as NSString).size(withAttributes: attrs)
        let width = min(max(textSize.width + 40, 90), 200)
        let height: CGFloat = 26
        let size = NSSize(width: width, height: height)

        let image = NSImage(size: size)
        image.lockFocus()

        let bgRect = NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: bgRect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        path.lineWidth = 1
        path.stroke()

        if let symbol = NSImage(systemSymbolName: item.icon, accessibilityDescription: item.name) {
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(.init(paletteColors: [item.color.color]))
            let configured = symbol.withSymbolConfiguration(config) ?? symbol
            let iconRect = NSRect(x: 8, y: (height - 15) / 2, width: 15, height: 15)
            configured.draw(in: iconRect)
        }

        let textRect = NSRect(
            x: 28,
            y: (height - textSize.height) / 2,
            width: width - 34,
            height: textSize.height
        )
        (item.name as NSString).draw(
            with: textRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attrs
        )

        image.unlockFocus()
        return image
    }

    // MARK: - NSDraggingSource

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        switch context {
        case .withinApplication:
            return [.move, .copy]
        case .outsideApplication:
            return []
        @unknown default:
            return [.move, .copy]
        }
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        Task { @MainActor in
            SidebarDragState.shared.clear()
        }
    }
}

final class SidebarRowTrackingNSView: NSView {
    var groupId: String = ""
    var item: QuickAccessItem? = nil

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func containsWindowPoint(_ windowPoint: NSPoint) -> Bool {
        guard let window else { return false }
        if let contentView = window.contentView {
            let contentPoint = contentView.convert(windowPoint, from: nil)
            var hit = contentView.hitTest(contentPoint)
            while let v = hit {
                if v is NSScroller { return false }
                hit = v.superview
            }
        }
        if let clipView = enclosingScrollView?.contentView {
            let clipPoint = clipView.convert(windowPoint, from: nil)
            guard clipView.bounds.contains(clipPoint) else { return false }
        }
        var cursor: NSView? = self
        while let current = cursor {
            if let rowView = current as? NSTableRowView {
                let rowPoint = rowView.convert(windowPoint, from: nil)
                return rowView.bounds.contains(rowPoint)
            }
            cursor = current.superview
        }
        let localPoint = convert(windowPoint, from: nil)
        return bounds.insetBy(dx: -8, dy: -4).contains(localPoint)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            SidebarDragState.shared.registerRowView(self)
        } else {
            SidebarDragState.shared.unregisterRowView(self)
        }
    }
}

struct SidebarRowHitTracker: NSViewRepresentable {
    let groupId: String
    let item: QuickAccessItem?
    let onSelectFolder: (String, String) -> Void
    let onSelectApps: (() -> Void)?
    let onItemMovedToGroup: (String, String) -> Void

    func makeNSView(context: Context) -> SidebarRowTrackingNSView {
        let view = SidebarRowTrackingNSView()
        view.groupId = groupId
        view.item = item
        SidebarDragState.shared.onSelectFolder = onSelectFolder
        SidebarDragState.shared.onSelectApps = onSelectApps
        SidebarDragState.shared.onItemMovedToGroup = onItemMovedToGroup
        SidebarDragState.shared.registerRowView(view)
        return view
    }

    func updateNSView(_ nsView: SidebarRowTrackingNSView, context: Context) {
        nsView.groupId = groupId
        nsView.item = item
        SidebarDragState.shared.onSelectFolder = onSelectFolder
        SidebarDragState.shared.onSelectApps = onSelectApps
        SidebarDragState.shared.onItemMovedToGroup = onItemMovedToGroup
        SidebarDragState.shared.registerRowView(nsView)
    }

    static func dismantleNSView(_ nsView: SidebarRowTrackingNSView, coordinator: ()) {
        SidebarDragState.shared.unregisterRowView(nsView)
    }
}

// MARK: - SidebarView

struct SidebarView: View {
    @ObservedObject var sidebarManager: SidebarManager
    let currentPath: String
    let onNavigate: (String) -> Void
    var trashCount: Int = 0
    var onOpenTrash: (() -> Void)? = nil
    var activeAppFilter: AppFilter? = nil
    var onSelectAppFilter: ((AppFilter) -> Void)? = nil
    var storageStats: [String: DeviceManager.StorageInfo] = [:]
    var onMoveFiles: (([UnifiedFile], String) -> Void)? = nil
    var onUploadToFolder: (([URL], String) -> Void)? = nil

    @State private var groupToDelete: SidebarGroup? = nil
    @State private var showDeleteGroupAlert = false
    @State private var isAddGroupHovered = false
    @State private var isQuickAccessHeaderTargeted = false
    @State private var activeSelectionGroupId: String? = nil

    enum SidebarItem: Hashable {
        case folder(groupId: String, path: String)
        case apps
    }

    private func resolvedGroupId(for path: String) -> String {
        if let preferred = activeSelectionGroupId {
            if preferred == "quick_access",
               sidebarManager.visibleQuickAccessItems.contains(where: { $0.path == path }) {
                return preferred
            }
            if let grp = sidebarManager.groups.first(where: { $0.id == preferred }),
               sidebarManager.visibleItems(in: grp).contains(where: { $0.path == path }) {
                return preferred
            }
        }
        if sidebarManager.visibleQuickAccessItems.contains(where: { $0.path == path }) {
            return "quick_access"
        }
        for grp in sidebarManager.customGroups {
            if sidebarManager.visibleItems(in: grp).contains(where: { $0.path == path }) {
                return grp.id
            }
        }
        if let def = sidebarManager.defaultGroup,
           sidebarManager.visibleItems(in: def).contains(where: { $0.path == path }) {
            return def.id
        }
        return "default"
    }

    private func selectFolder(groupId: String, path: String) {
        activeSelectionGroupId = groupId
        guard SidebarDragState.shared.currentPath != path || SidebarDragState.shared.hasActiveAppFilter else { return }
        SidebarDragState.shared.currentPath = path
        SidebarDragState.shared.hasActiveAppFilter = false
        onNavigate(path)
    }

    private func handleItemMovedToGroup(itemPath: String, targetGroupId: String) {
        if SidebarDragState.shared.currentPath == itemPath {
            activeSelectionGroupId = targetGroupId
        }
    }

    // Derived binding to map external state to List selection
    private var selectionBinding: Binding<SidebarItem?> {
        Binding {
            if onSelectAppFilter != nil && activeAppFilter != nil { return .apps }
            return .folder(groupId: resolvedGroupId(for: currentPath), path: currentPath)
        } set: { newValue in
            guard let val = newValue else { return }
            switch val {
            case .folder(let groupId, let path):
                selectFolder(groupId: groupId, path: path)
            case .apps:
                SidebarDragState.shared.hasActiveAppFilter = true
                onSelectAppFilter?(.user)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selectionBinding) {

                // ── 1. Quick Access (Add to Sidebar 전용) ──────────────────
                Section {
                    let qaItems = sidebarManager.visibleQuickAccessItems
                    if qaItems.isEmpty {
                        EmptyGroupDropPlaceholder(
                            groupId: "quick_access",
                            message: "Add folders via 'Add to Sidebar' or drop here",
                            sidebarManager: sidebarManager
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(qaItems) { item in
                            SidebarItemRowContainer(
                                item: item,
                                groupId: "quick_access",
                                sidebarManager: sidebarManager,
                                storageStats: storageStats,
                                onSelectFolder: selectFolder,
                                onSelectApps: {
                                    SidebarDragState.shared.hasActiveAppFilter = true
                                    onSelectAppFilter?(.user)
                                },
                                onItemMovedToGroup: handleItemMovedToGroup,
                                onMoveFiles: onMoveFiles,
                                onUploadToFolder: onUploadToFolder
                            )
                            .id("quick_access:\(item.path)")
                        }
                    }
                } header: {
                    HStack {
                        Text("Quick Access")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(isQuickAccessHeaderTargeted ? Color.accentColor : .secondary)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 4)

                        Spacer()

                        Button(action: createNewGroup) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(isAddGroupHovered ? Color.accentColor : Color.secondary)
                                .frame(width: 18, height: 18)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(isAddGroupHovered ? Color.secondary.opacity(0.18) : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Add New Group")
                        .onHover { isAddGroupHovered = $0 }
                    }
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isQuickAccessHeaderTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Add Group...", action: createNewGroup)
                    }
                    .onDrop(
                        of: [
                            UTType.plainText.identifier,
                            UTType.text.identifier,
                            FileDragManager.internalFileUTI
                        ],
                        delegate: GroupHeaderDropDelegate(
                            targetGroupId: "quick_access",
                            sidebarManager: sidebarManager,
                            isTargeted: $isQuickAccessHeaderTargeted
                        )
                    )
                }

                // ── 2. Custom Groups (커스텀 그룹들) ──────────────────────────
                ForEach(sidebarManager.customGroups) { group in
                    Section {
                        let items = sidebarManager.visibleItems(in: group)
                        if items.isEmpty {
                            EmptyGroupDropPlaceholder(
                                groupId: group.id,
                                message: "Drop folders here",
                                sidebarManager: sidebarManager
                            )
                            .listRowBackground(Color.clear)
                        } else {
                            ForEach(items) { item in
                                SidebarItemRowContainer(
                                    item: item,
                                    groupId: group.id,
                                    sidebarManager: sidebarManager,
                                    storageStats: storageStats,
                                    onSelectFolder: selectFolder,
                                    onSelectApps: {
                                        SidebarDragState.shared.hasActiveAppFilter = true
                                        onSelectAppFilter?(.user)
                                    },
                                    onItemMovedToGroup: handleItemMovedToGroup,
                                    onMoveFiles: onMoveFiles,
                                    onUploadToFolder: onUploadToFolder
                                )
                                .id("\(group.id):\(item.path)")
                            }
                        }
                    } header: {
                        GroupHeaderView(
                            group: group,
                            sidebarManager: sidebarManager,
                            onRenameGroup: { renameGroup(group) },
                            onDeleteGroup: { confirmDeleteGroup(group) },
                            onRestoreBuiltIns: { },
                            hasHiddenBuiltIns: false
                        )
                    }
                }

                // ── 3. 기본그룹 (Apps 바로 위에 위치, 기본 폴더 전용) ──────────────
                if let defaultGroup = sidebarManager.defaultGroup {
                    Section {
                        let items = sidebarManager.visibleItems(in: defaultGroup)
                        ForEach(items) { item in
                            SidebarItemRowContainer(
                                item: item,
                                groupId: defaultGroup.id,
                                sidebarManager: sidebarManager,
                                storageStats: storageStats,
                                onSelectFolder: selectFolder,
                                onSelectApps: {
                                    SidebarDragState.shared.hasActiveAppFilter = true
                                    onSelectAppFilter?(.user)
                                },
                                onItemMovedToGroup: handleItemMovedToGroup,
                                onMoveFiles: onMoveFiles,
                                onUploadToFolder: onUploadToFolder
                            )
                            .id("\(defaultGroup.id):\(item.path)")
                        }
                    } header: {
                        GroupHeaderView(
                            group: defaultGroup,
                            sidebarManager: sidebarManager,
                            onRenameGroup: { },
                            onDeleteGroup: { },
                            onRestoreBuiltIns: { sidebarManager.restoreBuiltIns() },
                            hasHiddenBuiltIns: sidebarManager.hasHiddenBuiltIns
                        )
                    }
                }

                // ── 4. Apps Section ────────────────────────────────────────
                if onSelectAppFilter != nil {
                    Section("Apps") {
                        Label("Apps", systemImage: "square.grid.2x2.fill")
                            .contentShape(Rectangle())
                            .background(
                                SidebarRowHitTracker(
                                    groupId: "__apps__",
                                    item: nil,
                                    onSelectFolder: selectFolder,
                                    onSelectApps: {
                                        SidebarDragState.shared.hasActiveAppFilter = true
                                        onSelectAppFilter?(.user)
                                    },
                                    onItemMovedToGroup: handleItemMovedToGroup
                                )
                            )
                            .tag(SidebarItem.apps)
                    }
                }

                // ── 5. Trash Section ───────────────────────────────────────
                if let openTrash = onOpenTrash {
                    Section("Trash") {
                        Button(action: openTrash) {
                            HStack {
                                Label("Trash", systemImage: trashCount > 0 ? "trash.fill" : "trash")
                                    .foregroundColor(trashCount > 0 ? .red : .primary)
                                Spacer()
                                if trashCount > 0 {
                                    Text("\(trashCount)")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.red)
                                        .cornerRadius(8)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.sidebar)

            // Subtle native footer
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 16) {
                    Spacer()
                    FooterLink(
                        icon: GitHubIcon(size: 16, color: .secondary),
                        title: "GitHub",
                        destination: URL(string: "https://github.com/jhchoo/AndroidFileSync")!
                    )
                    FooterLink(
                        icon: PayPalIcon(size: 16, color: .secondary),
                        title: "Donate",
                        destination: URL(string: "https://paypal.me/jhchoo")!
                    )
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
            }
        }
        .frame(minWidth: 200)
        .alert("Delete Group?", isPresented: $showDeleteGroupAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                if let grp = groupToDelete {
                    sidebarManager.deleteGroup(id: grp.id)
                }
            }
        } message: {
            Text("Are you sure you want to delete '\(groupToDelete?.name ?? "")'?")
        }
        .onChange(of: currentPath) { newValue in
            SidebarDragState.shared.currentPath = newValue
            SidebarDragState.shared.onSelectFolder = selectFolder
        }
        .onChange(of: activeAppFilter != nil) { newValue in
            SidebarDragState.shared.hasActiveAppFilter = newValue
            SidebarDragState.shared.onSelectFolder = selectFolder
        }
        .onAppear {
            SidebarDragState.shared.currentPath = currentPath
            SidebarDragState.shared.hasActiveAppFilter = (activeAppFilter != nil)
            SidebarDragState.shared.onSelectFolder = selectFolder
            SidebarDragState.shared.onSelectApps = {
                SidebarDragState.shared.hasActiveAppFilter = true
                onSelectAppFilter?(.user)
            }
            SidebarDragState.shared.onItemMovedToGroup = handleItemMovedToGroup
            SidebarDragState.shared.installMonitorIfNeeded()
            Task { await sidebarManager.checkExistence() }
        }
        .onDisappear {
            SidebarDragState.shared.removeMonitor()
        }
    }

    // MARK: - Actions

    private func createNewGroup() {
        if let name = TextInputDialog.show(
            title: "New Group",
            message: "Enter a name for the new sidebar group:",
            placeholder: "Group Name",
            confirmLabel: "Create"
        ) {
            _ = sidebarManager.addGroup(name: name)
        }
    }

    private func renameGroup(_ group: SidebarGroup) {
        if let newName = TextInputDialog.show(
            title: "Rename Group",
            message: "Enter a new name for '\(group.name)':",
            placeholder: "Group Name",
            initialValue: group.name,
            confirmLabel: "Rename"
        ) {
            sidebarManager.renameGroup(id: group.id, newName: newName)
        }
    }

    private func confirmDeleteGroup(_ group: SidebarGroup) {
        groupToDelete = group
        showDeleteGroupAlert = true
    }
}

// MARK: - Row Container (Individual Drag & Drop State)

struct SidebarItemRowContainer: View {
    let item: QuickAccessItem
    let groupId: String
    @ObservedObject var sidebarManager: SidebarManager
    let storageStats: [String: DeviceManager.StorageInfo]
    let onSelectFolder: (String, String) -> Void
    let onSelectApps: (() -> Void)?
    let onItemMovedToGroup: (String, String) -> Void
    let onMoveFiles: (([UnifiedFile], String) -> Void)?
    let onUploadToFolder: (([URL], String) -> Void)?

    @State private var dropPosition: DropPosition? = nil
    @State private var isFolderTargeted = false

    var body: some View {
        QuickAccessRow(
            item: item,
            isChecking: item.isBuiltIn && !sidebarManager.checkedPaths.contains(item.path),
            storageInfo: storageStats[item.path],
            onRemove: {
                sidebarManager.removeItem(item, fromGroupId: groupId)
            },
            onMoveToGroup: { targetGroupId in
                sidebarManager.moveItemToGroup(item, fromGroupId: groupId, toGroupId: targetGroupId)
                onItemMovedToGroup(item.path, targetGroupId)
            },
            availableGroups: sidebarManager.availableTargetGroups(currentGroupId: groupId)
        )
        .background(
            SidebarRowHitTracker(
                groupId: groupId,
                item: item,
                onSelectFolder: onSelectFolder,
                onSelectApps: onSelectApps,
                onItemMovedToGroup: onItemMovedToGroup
            )
        )
        .overlay(alignment: .top) {
            if dropPosition == .above {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
        }
        .overlay(alignment: .bottom) {
            if dropPosition == .below {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.horizontal, 4)
            }
        }
        .overlay {
            if isFolderTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                    )
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [
                UTType.plainText.identifier,
                UTType.text.identifier,
                FileDragManager.internalFileUTI,
                UTType.fileURL.identifier
            ],
            delegate: SidebarRowDropDelegate(
                targetItem: item,
                targetGroupId: groupId,
                sidebarManager: sidebarManager,
                dropPosition: $dropPosition,
                isFolderTargeted: $isFolderTargeted,
                onMoveFiles: onMoveFiles,
                onUploadToFolder: onUploadToFolder
            )
        )
        .tag(SidebarView.SidebarItem.folder(groupId: groupId, path: item.path))
    }
}

// MARK: - Row Drop Delegate

struct SidebarRowDropDelegate: DropDelegate {
    let targetItem: QuickAccessItem
    let targetGroupId: String
    let sidebarManager: SidebarManager
    @Binding var dropPosition: DropPosition?
    @Binding var isFolderTargeted: Bool
    let onMoveFiles: (([UnifiedFile], String) -> Void)?
    let onUploadToFolder: (([URL], String) -> Void)?

    private var isTargetDefaultGroup: Bool {
        sidebarManager.groups.first(where: { $0.id == targetGroupId })?.isDefault == true
    }

    private var canReorderSidebarItem: Bool {
        guard SidebarDragState.shared.draggedItem != nil else { return false }
        let fromGroupId = SidebarDragState.shared.draggedGroupId ?? targetGroupId
        let isFromDefaultGroup = sidebarManager.groups.first(where: { $0.id == fromGroupId })?.isDefault == true
        // Default group items can only be reordered within the default group;
        // Quick Access and Custom Group items can move freely within and between Quick Access and Custom Groups.
        return isFromDefaultGroup == isTargetDefaultGroup
    }

    private var hasDraggedBrowserFolders: Bool {
        !isTargetDefaultGroup && FileDragManager.shared.draggedFiles.contains(where: { $0.isDirectory })
    }

    func validateDrop(info: DropInfo) -> Bool {
        if SidebarDragState.shared.draggedItem != nil {
            return canReorderSidebarItem
        }
        if onMoveFiles == nil {
            return hasDraggedBrowserFolders
        }
        return info.hasItemsConforming(to: [
            UTType.fileURL,
            UTType(exportedAs: FileDragManager.internalFileUTI, conformingTo: .data)
        ])
    }

    func dropEntered(info: DropInfo) {
        updatePosition(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updatePosition(info: info)
        if SidebarDragState.shared.draggedItem != nil {
            return canReorderSidebarItem ? DropProposal(operation: .move) : DropProposal(operation: .forbidden)
        } else if onMoveFiles == nil {
            return hasDraggedBrowserFolders ? DropProposal(operation: .copy) : DropProposal(operation: .forbidden)
        } else {
            return DropProposal(operation: .copy)
        }
    }

    private func updatePosition(info: DropInfo) {
        if canReorderSidebarItem || (onMoveFiles == nil && hasDraggedBrowserFolders) {
            isFolderTargeted = false
            let y = info.location.y
            dropPosition = (y < 14) ? .above : .below
        } else if onMoveFiles != nil {
            dropPosition = nil
            isFolderTargeted = FileDragManager.shared.canDrop(onto: targetItem.path)
        } else {
            dropPosition = nil
            isFolderTargeted = false
        }
    }

    func dropExited(info: DropInfo) {
        dropPosition = nil
        isFolderTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        let pos = dropPosition ?? .below
        dropPosition = nil
        isFolderTargeted = false

        if let dragged = SidebarDragState.shared.draggedItem {
            guard canReorderSidebarItem else {
                SidebarDragState.shared.clear()
                return false
            }
            let fromGroup = SidebarDragState.shared.draggedGroupId ?? targetGroupId
            sidebarManager.moveItem(
                dragged,
                fromGroupId: fromGroup,
                toGroupId: targetGroupId,
                relativeTo: targetItem.path,
                position: pos
            )
            SidebarDragState.shared.onItemMovedToGroup?(dragged.path, targetGroupId)
            SidebarDragState.shared.clear()
            return true
        }

        // Handle internal files drop from FileBrowserView
        let internalFiles = FileDragManager.shared.draggedFiles
        if !internalFiles.isEmpty {
            if let onMoveFiles {
                guard FileDragManager.shared.canDrop(onto: targetItem.path) else { return false }
                onMoveFiles(internalFiles, targetItem.path)
                return true
            } else {
                guard !isTargetDefaultGroup else { return false }
                let folders = internalFiles.filter { $0.isDirectory }
                guard !folders.isEmpty else { return false }
                for folder in folders {
                    sidebarManager.addItem(
                        name: folder.name,
                        path: folder.path,
                        icon: "folder.fill",
                        color: "blue",
                        toGroupId: targetGroupId,
                        relativeTo: targetItem.path,
                        position: pos
                    )
                }
                return true
            }
        }

        // Handle Finder files drop
        if let onUploadToFolder {
            Task {
                var urls: [URL] = []
                for provider in info.itemProviders(for: [.fileURL]) {
                    if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                if !urls.isEmpty {
                    await MainActor.run {
                        onUploadToFolder(urls, targetItem.path)
                    }
                }
            }
            return true
        }
        return false
    }
}

// MARK: - Group Header Drop Delegate

struct GroupHeaderDropDelegate: DropDelegate {
    let targetGroupId: String
    let sidebarManager: SidebarManager
    @Binding var isTargeted: Bool

    private var isTargetDefaultGroup: Bool {
        sidebarManager.groups.first(where: { $0.id == targetGroupId })?.isDefault == true
    }

    private var canAcceptSidebarItem: Bool {
        guard !isTargetDefaultGroup, SidebarDragState.shared.draggedItem != nil else { return false }
        let fromGroupId = SidebarDragState.shared.draggedGroupId ?? targetGroupId
        let isFromDefaultGroup = sidebarManager.groups.first(where: { $0.id == fromGroupId })?.isDefault == true
        return !isFromDefaultGroup
    }

    private var canAcceptBrowserFolders: Bool {
        !isTargetDefaultGroup && FileDragManager.shared.draggedFiles.contains(where: { $0.isDirectory })
    }

    private var canAcceptDrop: Bool {
        canAcceptSidebarItem || canAcceptBrowserFolders
    }

    func validateDrop(info: DropInfo) -> Bool {
        return canAcceptDrop
    }

    func dropEntered(info: DropInfo) {
        isTargeted = canAcceptDrop
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isTargeted = canAcceptDrop
        if canAcceptSidebarItem {
            return DropProposal(operation: .move)
        }
        if canAcceptBrowserFolders {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard !isTargetDefaultGroup else { return false }

        if let dragged = SidebarDragState.shared.draggedItem {
            guard canAcceptSidebarItem else {
                SidebarDragState.shared.clear()
                return false
            }
            let fromGroup = SidebarDragState.shared.draggedGroupId ?? targetGroupId
            sidebarManager.moveItem(
                dragged,
                fromGroupId: fromGroup,
                toGroupId: targetGroupId,
                relativeTo: nil,
                position: .below
            )
            SidebarDragState.shared.onItemMovedToGroup?(dragged.path, targetGroupId)
            SidebarDragState.shared.clear()
            return true
        }

        let draggedFolders = FileDragManager.shared.draggedFiles.filter { $0.isDirectory }
        if !draggedFolders.isEmpty {
            for folder in draggedFolders {
                sidebarManager.addItem(
                    name: folder.name,
                    path: folder.path,
                    icon: "folder.fill",
                    color: "blue",
                    toGroupId: targetGroupId
                )
            }
            return true
        }

        return false
    }
}

// MARK: - Empty Group Drop Placeholder

struct EmptyGroupDropDelegate: DropDelegate {
    let groupId: String
    let sidebarManager: SidebarManager
    @Binding var isTargeted: Bool

    private var isTargetDefaultGroup: Bool {
        sidebarManager.groups.first(where: { $0.id == groupId })?.isDefault == true
    }

    private var canAcceptSidebarItem: Bool {
        guard !isTargetDefaultGroup, SidebarDragState.shared.draggedItem != nil else { return false }
        let fromGroupId = SidebarDragState.shared.draggedGroupId ?? groupId
        let isFromDefaultGroup = sidebarManager.groups.first(where: { $0.id == fromGroupId })?.isDefault == true
        return !isFromDefaultGroup
    }

    private var canAcceptBrowserFolders: Bool {
        !isTargetDefaultGroup && FileDragManager.shared.draggedFiles.contains(where: { $0.isDirectory })
    }

    private var canAcceptDrop: Bool {
        canAcceptSidebarItem || canAcceptBrowserFolders
    }

    func validateDrop(info: DropInfo) -> Bool {
        return canAcceptDrop
    }

    func dropEntered(info: DropInfo) {
        isTargeted = canAcceptDrop
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isTargeted = canAcceptDrop
        if canAcceptSidebarItem {
            return DropProposal(operation: .move)
        }
        if canAcceptBrowserFolders {
            return DropProposal(operation: .copy)
        }
        return DropProposal(operation: .forbidden)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard !isTargetDefaultGroup else { return false }

        if let dragged = SidebarDragState.shared.draggedItem {
            guard canAcceptSidebarItem else {
                SidebarDragState.shared.clear()
                return false
            }
            let fromGroup = SidebarDragState.shared.draggedGroupId ?? groupId
            sidebarManager.moveItem(
                dragged,
                fromGroupId: fromGroup,
                toGroupId: groupId,
                relativeTo: nil,
                position: .below
            )
            SidebarDragState.shared.onItemMovedToGroup?(dragged.path, groupId)
            SidebarDragState.shared.clear()
            return true
        }

        let draggedFolders = FileDragManager.shared.draggedFiles.filter { $0.isDirectory }
        if !draggedFolders.isEmpty {
            for folder in draggedFolders {
                sidebarManager.addItem(
                    name: folder.name,
                    path: folder.path,
                    icon: "folder.fill",
                    color: "blue",
                    toGroupId: groupId
                )
            }
            return true
        }

        return false
    }
}

struct EmptyGroupDropPlaceholder: View {
    let groupId: String
    let message: String
    let sidebarManager: SidebarManager
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Spacer()
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(isTargeted ? Color.accentColor : Color.secondary.opacity(0.6))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [4])
                )
                .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .onDrop(
            of: [
                UTType.plainText.identifier,
                UTType.text.identifier,
                FileDragManager.internalFileUTI
            ],
            delegate: EmptyGroupDropDelegate(
                groupId: groupId,
                sidebarManager: sidebarManager,
                isTargeted: $isTargeted
            )
        )
    }
}

// MARK: - Group Header View

struct GroupHeaderView: View {
    let group: SidebarGroup
    let sidebarManager: SidebarManager
    let onRenameGroup: () -> Void
    let onDeleteGroup: () -> Void
    let onRestoreBuiltIns: () -> Void
    let hasHiddenBuiltIns: Bool

    @State private var isRenameHovered = false
    @State private var isDeleteHovered = false
    @State private var isRestoreHovered = false
    @State private var isDropTargeted = false

    var body: some View {
        HStack {
            Text(group.name)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(isDropTargeted ? Color.accentColor : .secondary)
                .padding(.vertical, 2)
                .padding(.horizontal, 4)

            Spacer()

            if group.isDefault {
                if hasHiddenBuiltIns {
                    Button(action: onRestoreBuiltIns) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isRestoreHovered ? .primary : .secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isRestoreHovered ? Color.secondary.opacity(0.18) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Restore hidden default folders")
                    .onHover { isRestoreHovered = $0 }
                }
            } else {
                HStack(spacing: 4) {
                    // Group Rename Button
                    Button(action: onRenameGroup) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isRenameHovered ? Color.accentColor : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isRenameHovered ? Color.secondary.opacity(0.18) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Rename Group")
                    .onHover { isRenameHovered = $0 }

                    // Group Delete Button
                    Button(action: onDeleteGroup) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isDeleteHovered ? Color.red : Color.secondary)
                            .frame(width: 18, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isDeleteHovered ? Color.red.opacity(0.15) : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Delete Group")
                    .onHover { isDeleteHovered = $0 }
                }
            }
        }
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .contextMenu {
            if group.isDefault {
                if hasHiddenBuiltIns {
                    Button("Restore Hidden Default Folders", action: onRestoreBuiltIns)
                }
            } else {
                Button("Rename Group...", action: onRenameGroup)
                Divider()
                Button("Delete Group", role: .destructive, action: onDeleteGroup)
            }
        }
        .onDrop(
            of: [
                UTType.plainText.identifier,
                UTType.text.identifier,
                FileDragManager.internalFileUTI
            ],
            delegate: GroupHeaderDropDelegate(
                targetGroupId: group.id,
                sidebarManager: sidebarManager,
                isTargeted: $isDropTargeted
            )
        )
    }
}

// MARK: - Row

struct QuickAccessRow: View {
    let item: QuickAccessItem
    /// True while the ADB existence check is still in flight for this item
    let isChecking: Bool
    var storageInfo: DeviceManager.StorageInfo? = nil
    var onRemove: (() -> Void)? = nil
    var onMoveToGroup: ((String) -> Void)? = nil
    var availableGroups: [TargetGroupOption] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: item.icon)
                    .foregroundColor(Color(item.color.color))

                Text(item.name)
                    .lineLimit(1)

                Spacer()

                if isChecking {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                }
            }

            // Storage gauge — only shown when stats are available
            if let storage = storageInfo {
                VStack(alignment: .leading, spacing: 2) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.secondary.opacity(0.2))
                                .frame(height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(storageBarColor(fraction: storage.usedFraction))
                                .frame(width: geo.size.width * storage.usedFraction, height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.leading, 30)

                    Text(storage.usedText)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.leading, 30)
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !item.isBuiltIn && !availableGroups.isEmpty {
                Menu("Move to Group") {
                    ForEach(availableGroups) { grp in
                        Button(grp.name) {
                            onMoveToGroup?(grp.id)
                        }
                    }
                }

                Divider()
            }

            if item.isBuiltIn {
                Button(role: .destructive) {
                    onRemove?()
                } label: {
                    Label("Hide from Sidebar", systemImage: "eye.slash")
                }
            } else {
                Button(role: .destructive) {
                    onRemove?()
                } label: {
                    Label("Remove from Sidebar", systemImage: "minus.circle")
                }
            }
        }
    }

    private func storageBarColor(fraction: Double) -> Color {
        if fraction > 0.9 { return .red }
        if fraction > 0.8 { return .orange }
        return .blue
    }
}

// MARK: - Footer Link

struct FooterLink<Icon: View>: View {
    let icon: Icon
    let title: String
    let destination: URL

    @State private var isHovered = false

    var body: some View {
        Link(destination: destination) {
            HStack(spacing: 5) {
                icon
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isHovered ? .primary : .secondary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? Color.secondary.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - GitHub Icon Drawing

struct GitHubIcon: View {
    var size: CGFloat = 16
    var color: Color = .secondary

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 16, y: size.height / 16)
            var path = Path()

            path.move(to: CGPoint(x: 8, y: 0))
            path.addCurve(to: CGPoint(x: 16, y: 8), control1: CGPoint(x: 12.42, y: 0), control2: CGPoint(x: 16, y: 3.58))
            path.addCurve(to: CGPoint(x: 10.55, y: 15.59), control1: CGPoint(x: 16, y: 11.54), control2: CGPoint(x: 13.71, y: 14.53))
            path.addCurve(to: CGPoint(x: 10, y: 15.21), control1: CGPoint(x: 10.15, y: 15.67), control2: CGPoint(x: 10, y: 15.42))
            path.addCurve(to: CGPoint(x: 10.01, y: 13.01), control1: CGPoint(x: 10, y: 14.94), control2: CGPoint(x: 10.01, y: 14.08))
            path.addCurve(to: CGPoint(x: 9.47, y: 11.53), control1: CGPoint(x: 10.01, y: 12.26), control2: CGPoint(x: 9.76, y: 11.78))
            path.addCurve(to: CGPoint(x: 13.12, y: 7.58), control1: CGPoint(x: 11.25, y: 11.33), control2: CGPoint(x: 13.12, y: 10.65))
            path.addCurve(to: CGPoint(x: 12.3, y: 5.43), control1: CGPoint(x: 13.12, y: 6.7), control2: CGPoint(x: 12.81, y: 5.99))
            path.addCurve(to: CGPoint(x: 12.38, y: 3.31), control1: CGPoint(x: 12.38, y: 5.23), control2: CGPoint(x: 12.66, y: 4.41))
            path.addCurve(to: CGPoint(x: 10.18, y: 4.13), control1: CGPoint(x: 12.38, y: 3.31), control2: CGPoint(x: 11.71, y: 3.09))
            path.addCurve(to: CGPoint(x: 8.18, y: 3.86), control1: CGPoint(x: 9.54, y: 3.95), control2: CGPoint(x: 8.86, y: 3.86))
            path.addCurve(to: CGPoint(x: 6.18, y: 4.13), control1: CGPoint(x: 7.5, y: 3.86), control2: CGPoint(x: 6.82, y: 3.95))
            path.addCurve(to: CGPoint(x: 3.98, y: 3.31), control1: CGPoint(x: 4.65, y: 3.09), control2: CGPoint(x: 3.98, y: 3.31))
            path.addCurve(to: CGPoint(x: 4.06, y: 5.43), control1: CGPoint(x: 3.82, y: 4.41), control2: CGPoint(x: 4.1, y: 5.23))
            path.addCurve(to: CGPoint(x: 3.24, y: 7.58), control1: CGPoint(x: 3.55, y: 5.99), control2: CGPoint(x: 3.24, y: 6.7))
            path.addCurve(to: CGPoint(x: 6.88, y: 11.53), control1: CGPoint(x: 3.24, y: 10.65), control2: CGPoint(x: 5.1, y: 11.33))
            path.addCurve(to: CGPoint(x: 6.37, y: 12.6), control1: CGPoint(x: 6.65, y: 11.73), control2: CGPoint(x: 6.44, y: 12.08))
            path.addCurve(to: CGPoint(x: 4.04, y: 12.1), control1: CGPoint(x: 5.91, y: 12.81), control2: CGPoint(x: 4.76, y: 12.45))
            path.addCurve(to: CGPoint(x: 2.81, y: 11.28), control1: CGPoint(x: 3.89, y: 11.86), control2: CGPoint(x: 3.44, y: 11.27))
            path.addCurve(to: CGPoint(x: 1.58, y: 10.46), control1: CGPoint(x: 2.21, y: 11.04), control2: CGPoint(x: 1.76, y: 10.47))
            path.addCurve(to: CGPoint(x: 1.59, y: 10.99), control1: CGPoint(x: 0.91, y: 10.47), control2: CGPoint(x: 1.31, y: 10.84))
            path.addCurve(to: CGPoint(x: 2.41, y: 12.12), control1: CGPoint(x: 1.93, y: 11.18), control2: CGPoint(x: 2.32, y: 11.89))
            path.addCurve(to: CGPoint(x: 5.1, y: 12.62), control1: CGPoint(x: 2.57, y: 12.57), control2: CGPoint(x: 3.09, y: 12.97))
            path.addCurve(to: CGPoint(x: 5.11, y: 14.11), control1: CGPoint(x: 5.1, y: 13.28), control2: CGPoint(x: 5.11, y: 13.92))
            path.addCurve(to: CGPoint(x: 4.56, y: 14.49), control1: CGPoint(x: 5.11, y: 14.3), control2: CGPoint(x: 4.96, y: 14.55))
            path.addCurve(to: CGPoint(x: 0, y: 8), control1: CGPoint(x: 1.91, y: 13.74), control2: CGPoint(x: 0, y: 11.54))
            path.addCurve(to: CGPoint(x: 8, y: 0), control1: CGPoint(x: 0, y: 3.58), control2: CGPoint(x: 3.58, y: 0))
            path.closeSubpath()

            context.fill(path, with: .color(color))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - PayPal Icon Drawing

struct PayPalIcon: View {
    var size: CGFloat = 16
    var color: Color = .secondary

    private let darkBlue  = Color(red: 0.0,   green: 0.19,  blue: 0.53)   // #003087
    private let lightBlue = Color(red: 0.0,   green: 0.612, blue: 0.87)   // #009CDE

    var body: some View {
        Canvas { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 24, y: canvasSize.height / 24)

            context.translateBy(x: 2.0, y: 1.5)
            drawP(in: &context, fillColor: lightBlue)
            context.translateBy(x: -2.0, y: -1.5)

            drawP(in: &context, fillColor: darkBlue)
        }
        .frame(width: size, height: size)
        .compositingGroup()
    }

    private func drawP(in context: inout GraphicsContext, fillColor: Color) {
        context.drawLayer { layerCtx in
            var outer = Path()
            outer.move(to: CGPoint(x: 7.076, y: 21.337))
            outer.addLine(to: CGPoint(x: 4.162, y: 21.337))
            outer.addCurve(to: CGPoint(x: 3.678, y: 20.877),
                           control1: CGPoint(x: 3.872, y: 21.337),
                           control2: CGPoint(x: 3.639, y: 21.143))
            outer.addLine(to: CGPoint(x: 5.958, y: 3.613))
            outer.addCurve(to: CGPoint(x: 6.558, y: 3.003),
                           control1: CGPoint(x: 6.018, y: 3.253),
                           control2: CGPoint(x: 6.258, y: 3.003))
            outer.addLine(to: CGPoint(x: 12.578, y: 3.003))
            outer.addCurve(to: CGPoint(x: 17.898, y: 7.483),
                           control1: CGPoint(x: 15.578, y: 3.003),
                           control2: CGPoint(x: 17.898, y: 4.583))
            outer.addCurve(to: CGPoint(x: 13.798, y: 12.503),
                           control1: CGPoint(x: 17.898, y: 10.103),
                           control2: CGPoint(x: 16.198, y: 12.503))
            outer.addLine(to: CGPoint(x: 10.298, y: 12.503))
            outer.addCurve(to: CGPoint(x: 9.698, y: 13.113),
                           control1: CGPoint(x: 9.998, y: 12.503),
                           control2: CGPoint(x: 9.738, y: 12.753))
            outer.addLine(to: CGPoint(x: 7.076, y: 21.337))
            outer.closeSubpath()

            layerCtx.fill(outer, with: .color(fillColor))

            var inner = Path()
            inner.move(to: CGPoint(x: 9.498, y: 6.003))
            inner.addLine(to: CGPoint(x: 8.298, y: 6.003))
            inner.addCurve(to: CGPoint(x: 7.698, y: 6.613),
                           control1: CGPoint(x: 7.998, y: 6.003),
                           control2: CGPoint(x: 7.738, y: 6.253))
            inner.addLine(to: CGPoint(x: 7.098, y: 10.003))
            inner.addCurve(to: CGPoint(x: 7.578, y: 10.503),
                           control1: CGPoint(x: 7.058, y: 10.283),
                           control2: CGPoint(x: 7.278, y: 10.503))
            inner.addLine(to: CGPoint(x: 12.258, y: 10.503))
            inner.addCurve(to: CGPoint(x: 14.378, y: 8.003),
                           control1: CGPoint(x: 13.578, y: 10.503),
                           control2: CGPoint(x: 14.378, y: 9.403))
            inner.addCurve(to: CGPoint(x: 12.258, y: 6.003),
                           control1: CGPoint(x: 14.378, y: 6.803),
                           control2: CGPoint(x: 13.458, y: 6.003))
            inner.addLine(to: CGPoint(x: 9.498, y: 6.003))
            inner.closeSubpath()

            layerCtx.blendMode = .destinationOut
            layerCtx.fill(inner, with: .color(.white))
        }
    }
}
