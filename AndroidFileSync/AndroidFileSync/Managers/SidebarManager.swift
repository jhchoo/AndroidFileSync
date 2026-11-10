//
//  SidebarManager.swift
//  AndroidFileSync
//
//  Manages sidebar groups and items — Quick Access ("Add to Sidebar" dedicated),
//  Default Group ("기본그룹", containing built-ins), and Custom Groups.
//  Items and groups are persisted to UserDefaults.
//

import Foundation
import SwiftUI
internal import Combine

enum DropPosition: String, Codable {
    case above
    case below
}

struct TargetGroupOption: Identifiable {
    let id: String
    let name: String
}

class SidebarManager: ObservableObject {

    // MARK: - Published State

    /// Pinned items specifically added via "Add to Sidebar"
    @Published var quickAccessItems: [QuickAccessItem] = []

    /// Sidebar groups (Default group "기본그룹" + user custom groups)
    @Published var groups: [SidebarGroup] = []

    /// Currently selected group ID for targeting operations like "Add to Sidebar"
    @Published var selectedGroupId: String? = nil

    /// Paths of built-in items the user has hidden
    @Published var hiddenBuiltInPaths: Set<String> = []

    /// Paths confirmed to exist on the connected device
    @Published var existingPaths: Set<String> = []

    /// Paths that have been checked at least once
    @Published var checkedPaths: Set<String> = []

    /// Dynamically injected SD card item (nil when no card detected)
    @Published var sdCardItem: QuickAccessItem? = nil
    @Published private(set) var internalStoragePath = "/storage/emulated/0"

    // MARK: - Computed Properties (Compatibility)

    /// Custom items across Quick Access and all groups
    var customItems: [QuickAccessItem] {
        quickAccessItems + groups.flatMap { $0.items.filter { !$0.isBuiltIn } }
    }

    /// Visible items specifically in Quick Access (user-added items are always visible)
    var visibleQuickAccessItems: [QuickAccessItem] {
        quickAccessItems.filter { item in
            !item.isBuiltIn || !checkedPaths.contains(item.path) || existingPaths.contains(item.path)
        }
    }

    /// All currently visible sidebar items across Quick Access and groups
    var visibleItems: [QuickAccessItem] {
        visibleQuickAccessItems + groups.flatMap { visibleItems(in: $0) }
    }

    /// Default group ("기본그룹")
    var defaultGroup: SidebarGroup? {
        groups.first(where: { $0.isDefault })
    }

    /// User created custom groups, sorted in ascending order by name
    var customGroups: [SidebarGroup] {
        groups.filter { !$0.isDefault }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// True when at least one built-in item is hidden (so user can restore)
    var hasHiddenBuiltIns: Bool { !hiddenBuiltInPaths.isEmpty }

    // MARK: - Init

    init() {
        load()
    }

    // MARK: - Default Built-in Generator

    private func defaultBuiltInItems() -> [QuickAccessItem] {
        QuickAccessItem.commonFolders.filter { !hiddenBuiltInPaths.contains($0.path) }.map { item in
            QuickAccessItem(
                name: item.name,
                icon: item.icon,
                path: internalStoragePath + item.path.dropFirst("/storage/emulated/0".count),
                color: item.color,
                isBuiltIn: true
            )
        }
    }

    // MARK: - Group Management

    /// Returns visible items in a specific group (hides non-existent built-ins once checked; user-added items stay visible)
    func visibleItems(in group: SidebarGroup) -> [QuickAccessItem] {
        group.items.filter { item in
            !item.isBuiltIn || !checkedPaths.contains(item.path) || existingPaths.contains(item.path)
        }
    }

    /// Sorts custom groups in ascending order by group name (maintaining default group at index 0)
    private func sortCustomGroups() {
        let defaultGroups = groups.filter { $0.isDefault }
        let sortedCustom = groups.filter { !$0.isDefault }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        groups = defaultGroups + sortedCustom
    }

    @discardableResult
    func addGroup(name: String) -> SidebarGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "New Group" : trimmed
        let newGroup = SidebarGroup(name: finalName, isDefault: false, items: [])
        groups.append(newGroup)
        sortCustomGroups()
        save()
        return newGroup
    }

    func deleteGroup(id: String) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        guard !groups[idx].isDefault else { return } // Default group cannot be deleted

        let itemsToKeep = groups[idx].items
        groups.remove(at: idx)

        // Move remaining items into default group so they aren't lost
        if !itemsToKeep.isEmpty, let defIdx = groups.firstIndex(where: { $0.isDefault }) {
            for item in itemsToKeep {
                if !groups[defIdx].items.contains(where: { $0.path == item.path }) {
                    groups[defIdx].items.append(item)
                }
            }
        }
        if selectedGroupId == id {
            selectedGroupId = nil
        }
        sortCustomGroups()
        save()
    }

    func renameGroup(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        guard !groups[idx].isDefault else { return } // Keep "기본그룹" name fixed
        groups[idx].name = trimmed
        sortCustomGroups()
        save()
    }

    // MARK: - Target Groups Options for Context Menu

    func availableTargetGroups(currentGroupId: String) -> [TargetGroupOption] {
        var options: [TargetGroupOption] = []
        if currentGroupId != "quick_access" {
            options.append(TargetGroupOption(id: "quick_access", name: "Quick Access"))
        }
        if let def = defaultGroup, def.id != currentGroupId {
            options.append(TargetGroupOption(id: def.id, name: def.name))
        }
        for grp in customGroups where grp.id != currentGroupId {
            options.append(TargetGroupOption(id: grp.id, name: grp.name))
        }
        return options
    }

    // MARK: - Item Reordering & Moving

    func moveQuickAccessItems(fromOffsets: IndexSet, toOffset: Int) {
        quickAccessItems.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func moveItems(inGroupId groupId: String, fromOffsets: IndexSet, toOffset: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        groups[idx].items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        save()
    }

    func moveItem(
        _ item: QuickAccessItem,
        fromGroupId: String,
        toGroupId: String,
        relativeTo targetItemPath: String?,
        position: DropPosition
    ) {
        // If moving within the exact same position, do nothing
        if fromGroupId == toGroupId && targetItemPath == item.path {
            return
        }

        // 1. Remove from source
        let removedItem: QuickAccessItem
        if fromGroupId == "quick_access" {
            guard let srcIdx = quickAccessItems.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = quickAccessItems.remove(at: srcIdx)
        } else {
            guard let srcGIdx = groups.firstIndex(where: { $0.id == fromGroupId }),
                  let srcIdx = groups[srcGIdx].items.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = groups[srcGIdx].items.remove(at: srcIdx)
        }

        // 2. Insert into destination (avoiding duplicate path in the same target group)
        if toGroupId == "quick_access" {
            quickAccessItems.removeAll { $0.path == removedItem.path }
            let destIndex: Int
            if let targetPath = targetItemPath,
               let targetIdx = quickAccessItems.firstIndex(where: { $0.path == targetPath }) {
                destIndex = (position == .above) ? targetIdx : targetIdx + 1
            } else {
                destIndex = quickAccessItems.count
            }
            let safeIndex = max(0, min(destIndex, quickAccessItems.count))
            quickAccessItems.insert(removedItem, at: safeIndex)
        } else {
            guard let dstGIdx = groups.firstIndex(where: { $0.id == toGroupId }) else {
                // Fallback to quick access if destination group not found
                if !quickAccessItems.contains(where: { $0.path == removedItem.path }) {
                    quickAccessItems.append(removedItem)
                }
                save()
                return
            }
            groups[dstGIdx].items.removeAll { $0.path == removedItem.path }
            let destIndex: Int
            if let targetPath = targetItemPath,
               let targetIdx = groups[dstGIdx].items.firstIndex(where: { $0.path == targetPath }) {
                destIndex = (position == .above) ? targetIdx : targetIdx + 1
            } else {
                destIndex = groups[dstGIdx].items.count
            }
            let safeIndex = max(0, min(destIndex, groups[dstGIdx].items.count))
            groups[dstGIdx].items.insert(removedItem, at: safeIndex)
        }

        save()
    }

    func moveItemToGroup(_ item: QuickAccessItem, fromGroupId: String, toGroupId: String) {
        guard fromGroupId != toGroupId else { return }

        // Remove from source
        let removedItem: QuickAccessItem
        if fromGroupId == "quick_access" {
            guard let idx = quickAccessItems.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = quickAccessItems.remove(at: idx)
        } else {
            guard let gIdx = groups.firstIndex(where: { $0.id == fromGroupId }),
                  let idx = groups[gIdx].items.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = groups[gIdx].items.remove(at: idx)
        }

        // Add to destination (avoiding duplicate path in the same target group)
        if toGroupId == "quick_access" {
            if !quickAccessItems.contains(where: { $0.path == removedItem.path }) {
                quickAccessItems.append(removedItem)
            }
        } else if let dstGIdx = groups.firstIndex(where: { $0.id == toGroupId }) {
            if !groups[dstGIdx].items.contains(where: { $0.path == removedItem.path }) {
                groups[dstGIdx].items.append(removedItem)
            }
        }
        save()
    }

    // MARK: - Item Mutations

    /// Adds a folder shortcut to the target group (or to `selectedGroupId` if selected, or `Quick Access` if no group is selected).
    func addItem(
        name: String,
        path: String,
        icon: String = "folder.fill",
        color: String = "blue",
        toGroupId: String? = nil,
        relativeTo targetItemPath: String? = nil,
        position: DropPosition = .below
    ) {
        let item = QuickAccessItem(name: name, icon: icon, path: path, color: color, isBuiltIn: false)
        let targetGid = toGroupId ?? selectedGroupId

        if let gid = targetGid, gid != "quick_access", let targetIdx = groups.firstIndex(where: { $0.id == gid }) {
            guard !groups[targetIdx].items.contains(where: { $0.path == path }) else { return }
            if let targetPath = targetItemPath,
               let relIdx = groups[targetIdx].items.firstIndex(where: { $0.path == targetPath }) {
                let insertIdx = (position == .above) ? relIdx : relIdx + 1
                let safeIdx = max(0, min(insertIdx, groups[targetIdx].items.count))
                groups[targetIdx].items.insert(item, at: safeIdx)
            } else {
                groups[targetIdx].items.append(item)
            }
        } else {
            // QuickAccess is dedicated for "Add to Sidebar" when no group is selected
            guard !quickAccessItems.contains(where: { $0.path == path }) else { return }
            if let targetPath = targetItemPath,
               let relIdx = quickAccessItems.firstIndex(where: { $0.path == targetPath }) {
                let insertIdx = (position == .above) ? relIdx : relIdx + 1
                let safeIdx = max(0, min(insertIdx, quickAccessItems.count))
                quickAccessItems.insert(item, at: safeIdx)
            } else {
                quickAccessItems.append(item)
            }
        }

        existingPaths.insert(path)
        checkedPaths.insert(path)
        save()
    }

    func removeItem(_ item: QuickAccessItem, fromGroupId: String? = nil) {
        if item.isBuiltIn {
            let canonical = "/storage/emulated/0" + item.path.dropFirst(internalStoragePath.count)
            hiddenBuiltInPaths.insert(canonical)
            if let gid = fromGroupId {
                if gid == "quick_access" {
                    quickAccessItems.removeAll { $0.path == item.path }
                } else if let gIdx = groups.firstIndex(where: { $0.id == gid }) {
                    groups[gIdx].items.removeAll { $0.path == item.path }
                }
            } else {
                for gIdx in groups.indices {
                    groups[gIdx].items.removeAll { $0.path == item.path && $0.isBuiltIn }
                }
            }
        } else {
            if let gid = fromGroupId {
                if gid == "quick_access" {
                    quickAccessItems.removeAll { $0.path == item.path }
                } else if let gIdx = groups.firstIndex(where: { $0.id == gid }) {
                    groups[gIdx].items.removeAll { $0.path == item.path }
                }
            } else {
                quickAccessItems.removeAll { $0.path == item.path }
                for gIdx in groups.indices {
                    groups[gIdx].items.removeAll { $0.path == item.path }
                }
            }
            let stillExistsSomewhere = quickAccessItems.contains(where: { $0.path == item.path })
                || groups.contains(where: { $0.items.contains(where: { $0.path == item.path }) })
            if !stillExistsSomewhere {
                existingPaths.remove(item.path)
                checkedPaths.remove(item.path)
            }
        }
        save()
    }

    func restoreBuiltIns() {
        hiddenBuiltInPaths.removeAll()
        if let defIdx = groups.firstIndex(where: { $0.isDefault }) {
            let existingPathsInDefault = Set(groups[defIdx].items.map(\.path))
            for builtIn in defaultBuiltInItems() {
                if !existingPathsInDefault.contains(builtIn.path) {
                    groups[defIdx].items.append(builtIn)
                }
            }
        }
        save()
        Task { await checkExistence() }
    }

    // MARK: - Storage & SD Card

    func updateInternalStorage(path: String) {
        let oldBase = internalStoragePath
        internalStoragePath = path
        guard oldBase != path else { return }

        for gIdx in groups.indices {
            for iIdx in groups[gIdx].items.indices {
                let item = groups[gIdx].items[iIdx]
                if item.isBuiltIn && item.path.hasPrefix(oldBase) {
                    let suffix = item.path.dropFirst(oldBase.count)
                    groups[gIdx].items[iIdx] = QuickAccessItem(
                        name: item.name,
                        icon: item.icon,
                        path: path + suffix,
                        color: item.color,
                        isBuiltIn: true
                    )
                }
            }
        }
        save()
        existingPaths.removeAll()
        checkedPaths.removeAll()
        Task { await checkExistence() }
    }

    func updateSDCard(path: String?) {
        for gIdx in groups.indices {
            groups[gIdx].items.removeAll { $0.icon == "sdcard.fill" || $0.name == "SD Card" }
        }
        quickAccessItems.removeAll { $0.icon == "sdcard.fill" || $0.name == "SD Card" }

        if let oldPath = sdCardItem?.path {
            existingPaths.remove(oldPath)
            checkedPaths.remove(oldPath)
        }

        guard let path else {
            sdCardItem = nil
            save()
            return
        }

        let item = QuickAccessItem(
            name: "SD Card",
            icon: "sdcard.fill",
            path: path,
            color: "orange",
            isBuiltIn: false
        )
        sdCardItem = item

        if let defIdx = groups.firstIndex(where: { $0.isDefault }) {
            let insertIndex = groups[defIdx].items.firstIndex(where: { $0.name == "Internal Storage" }).map { $0 + 1 } ?? 1
            groups[defIdx].items.insert(item, at: min(insertIndex, groups[defIdx].items.count))
        }

        existingPaths.insert(path)
        checkedPaths.insert(path)
        save()
    }

    // MARK: - Existence Checking

    func checkExistence() async {
        let allItems = quickAccessItems + groups.flatMap(\.items)
        let paths = Array(Set(allItems.map(\.path)))
        let storageSnapshot = internalStoragePath
        guard !paths.isEmpty, let serial = ADBManager.activeDeviceSerial else { return }

        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return }

        var newExisting: Set<String> = []
        var newChecked: Set<String> = []

        await withTaskGroup(of: (String, Bool?).self) { group in
            for path in paths {
                group.addTask {
                    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                    let (code, output, _) = await Shell.runAsync(
                        adbPath,
                        args: ["-s", serial, "shell", "[ -d '\(escaped)' ] && echo 1 || echo 0"]
                    )
                    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard code == 0, (trimmed == "1" || trimmed == "0") else {
                        return (path, nil)
                    }
                    return (path, trimmed == "1")
                }
            }

            for await (path, exists) in group {
                guard let exists else { continue }
                newChecked.insert(path)
                if exists { newExisting.insert(path) }
            }
        }

        await MainActor.run {
            guard ADBManager.activeDeviceSerial == serial, self.internalStoragePath == storageSnapshot else { return }
            newExisting.insert(storageSnapshot)
            self.existingPaths.formUnion(newExisting)
            self.checkedPaths.formUnion(newChecked)
        }
    }

    // MARK: - Persistence

    private let quickAccessKey = "sidebar_quickAccessItems_v4"
    private let groupsKey      = "sidebar_groups_v4"
    private let hiddenKey      = "sidebar_hiddenPaths_v2"
    private let groupsV3Key    = "sidebar_groups_v3"
    private let legacyCustomKey = "sidebar_customItems_v2"

    private func save() {
        if let qaData = try? JSONEncoder().encode(quickAccessItems) {
            UserDefaults.standard.set(qaData, forKey: quickAccessKey)
        }
        if let gData = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(gData, forKey: groupsKey)
        }
        UserDefaults.standard.set(Array(hiddenBuiltInPaths), forKey: hiddenKey)
    }

    private func load() {
        let hidden = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        hiddenBuiltInPaths = Set(hidden)

        // Try loading v4 state
        if let gData = UserDefaults.standard.data(forKey: groupsKey),
           let decodedGroups = try? JSONDecoder().decode([SidebarGroup].self, from: gData),
           !decodedGroups.isEmpty {
            groups = decodedGroups
            if let qaData = UserDefaults.standard.data(forKey: quickAccessKey),
               let decodedQA = try? JSONDecoder().decode([QuickAccessItem].self, from: qaData) {
                quickAccessItems = decodedQA
            }
        } else if let v3Data = UserDefaults.standard.data(forKey: groupsV3Key),
                  let decodedV3 = try? JSONDecoder().decode([SidebarGroup].self, from: v3Data),
                  !decodedV3.isEmpty {
            // Migrate from v3:
            // "QuickAccess 는 'Add to Sidebar' 전용으로 남겨두고 안에 있는 내용은 전부 '기본그룹' 이라는것으로 아래쪽에 만들어서 옮겨"
            var migratedCustomItems: [QuickAccessItem] = []
            var migratedGroups: [SidebarGroup] = []

            for group in decodedV3 {
                if group.isDefault || group.id == "default" || group.name == "Quick Access" {
                    // Extract custom items into quickAccessItems
                    migratedCustomItems.append(contentsOf: group.items.filter { !$0.isBuiltIn })
                } else {
                    migratedGroups.append(group)
                }
            }

            let defaultGroup = SidebarGroup(
                id: "default",
                name: "기본그룹",
                isDefault: true,
                items: defaultBuiltInItems()
            )
            migratedGroups.insert(defaultGroup, at: 0)

            quickAccessItems = migratedCustomItems
            groups = migratedGroups
        } else {
            // Migrate legacy custom items or create default group
            var legacyCustom: [QuickAccessItem] = []
            if let data = UserDefaults.standard.data(forKey: legacyCustomKey),
               let items = try? JSONDecoder().decode([QuickAccessItem].self, from: data) {
                legacyCustom = items
            }
            quickAccessItems = legacyCustom

            let defaultGroup = SidebarGroup(
                id: "default",
                name: "기본그룹",
                isDefault: true,
                items: defaultBuiltInItems()
            )
            groups = [defaultGroup]
        }

        // Guarantee that a default group named "기본그룹" always exists
        if let defIdx = groups.firstIndex(where: { $0.isDefault }) {
            groups[defIdx].name = "기본그룹"
        } else {
            let def = SidebarGroup(id: "default", name: "기본그룹", isDefault: true, items: defaultBuiltInItems())
            groups.insert(def, at: 0)
        }

        sortCustomGroups()
    }
}
