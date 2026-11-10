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

struct SidebarDropSlot: Equatable {
    let groupId: String
    let index: Int
}

class SidebarManager: ObservableObject {

    // MARK: - Published State

    /// Pinned items specifically added via "Add to Sidebar"
    @Published var quickAccessItems: [QuickAccessItem] = []

    /// Sidebar groups (Default group "기본그룹" + user custom groups)
    @Published var groups: [SidebarGroup] = []

    /// Paths of built-in items the user has hidden
    @Published var hiddenBuiltInPaths: Set<String> = []

    /// Paths confirmed to exist on the connected device
    @Published var existingPaths: Set<String> = []

    /// Paths that have been checked at least once
    @Published var checkedPaths: Set<String> = []

    /// Dynamically injected SD card item (nil when no card detected)
    @Published var sdCardItem: QuickAccessItem? = nil
    @Published private(set) var internalStoragePath = "/storage/emulated/0"

    /// Current drop slot target in sidebar: (groupId, index)
    @Published var activeDropSlot: SidebarDropSlot? = nil
    private var dropSessionToken = UUID()

    func setActiveDropSlot(_ slot: SidebarDropSlot?) {
        dropSessionToken = UUID()
        activeDropSlot = slot
    }

    func clearDropSlotDelayed() {
        let token = UUID()
        dropSessionToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.dropSessionToken == token else { return }
            self.activeDropSlot = nil
        }
    }

    func clearDropSlotImmediately() {
        dropSessionToken = UUID()
        activeDropSlot = nil
    }

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

        NotificationCenter.default.addObserver(
            forName: .afsFolderRenamed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let userInfo = note.userInfo,
                  let oldPath = userInfo["oldPath"] as? String,
                  let newPath = userInfo["newPath"] as? String,
                  let newName = userInfo["newName"] as? String else { return }
            self.handleItemRenamed(oldPath: oldPath, newPath: newPath, newName: newName)
        }

        NotificationCenter.default.addObserver(
            forName: .afsItemsDeleted,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let userInfo = note.userInfo,
                  let paths = userInfo["paths"] as? [String] else { return }
            self.handleItemsDeleted(paths: paths)
        }
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

        groups.remove(at: idx)
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
        // Default group ("기본그룹") does not accept user custom folders
        if let def = defaultGroup, def.id == currentGroupId {
            return []
        }
        var options: [TargetGroupOption] = []
        if currentGroupId != "quick_access" {
            options.append(TargetGroupOption(id: "quick_access", name: "Quick Access"))
        }
        for grp in customGroups where grp.id != currentGroupId {
            options.append(TargetGroupOption(id: grp.id, name: grp.name))
        }
        return options
    }

    // MARK: - Item Reordering & Moving

    func moveQuickAccessItems(fromOffsets: IndexSet, toOffset: Int) {
        var updated = quickAccessItems
        updated.move(fromOffsets: fromOffsets, toOffset: toOffset)
        quickAccessItems = updated
        save()
    }

    func moveItems(inGroupId groupId: String, fromOffsets: IndexSet, toOffset: Int) {
        guard let idx = groups.firstIndex(where: { $0.id == groupId }) else { return }
        var updatedGroups = groups
        updatedGroups[idx].items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        groups = updatedGroups
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

        // Prevent moving built-in items out of 기본그룹, or moving custom items into 기본그룹
        let isFromDefault = groups.first(where: { $0.id == fromGroupId })?.isDefault == true
        let isToDefault = groups.first(where: { $0.id == toGroupId })?.isDefault == true
        if isFromDefault != isToDefault {
            return
        }
        if isToDefault && !item.isBuiltIn && item.icon != "sdcard.fill" {
            return
        }

        var updatedQA = quickAccessItems
        var updatedGroups = groups

        // 1. Remove from source
        let removedItem: QuickAccessItem
        if fromGroupId == "quick_access" {
            guard let srcIdx = updatedQA.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = updatedQA.remove(at: srcIdx)
        } else {
            guard let srcGIdx = updatedGroups.firstIndex(where: { $0.id == fromGroupId }),
                  let srcIdx = updatedGroups[srcGIdx].items.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = updatedGroups[srcGIdx].items.remove(at: srcIdx)
        }

        // 2. Insert into destination (avoiding duplicate path in the same target group)
        if toGroupId == "quick_access" {
            updatedQA.removeAll { $0.path == removedItem.path }
            let destIndex: Int
            if let targetPath = targetItemPath,
               let targetIdx = updatedQA.firstIndex(where: { $0.path == targetPath }) {
                destIndex = (position == .above) ? targetIdx : targetIdx + 1
            } else {
                destIndex = updatedQA.count
            }
            let safeIndex = max(0, min(destIndex, updatedQA.count))
            updatedQA.insert(removedItem, at: safeIndex)
        } else {
            guard let dstGIdx = updatedGroups.firstIndex(where: { $0.id == toGroupId }) else {
                if !updatedQA.contains(where: { $0.path == removedItem.path }) {
                    updatedQA.append(removedItem)
                }
                quickAccessItems = updatedQA
                groups = updatedGroups
                save()
                return
            }
            updatedGroups[dstGIdx].items.removeAll { $0.path == removedItem.path }
            let destIndex: Int
            if let targetPath = targetItemPath,
               let targetIdx = updatedGroups[dstGIdx].items.firstIndex(where: { $0.path == targetPath }) {
                destIndex = (position == .above) ? targetIdx : targetIdx + 1
            } else {
                destIndex = updatedGroups[dstGIdx].items.count
            }
            let safeIndex = max(0, min(destIndex, updatedGroups[dstGIdx].items.count))
            updatedGroups[dstGIdx].items.insert(removedItem, at: safeIndex)
        }

        // Assign atomically so SwiftUI processes a single move update instead of delete + insert
        if updatedQA != quickAccessItems {
            quickAccessItems = updatedQA
        }
        if updatedGroups != groups {
            groups = updatedGroups
        }
        save()
    }

    func moveItemToGroup(_ item: QuickAccessItem, fromGroupId: String, toGroupId: String) {
        guard fromGroupId != toGroupId else { return }
        guard !item.isBuiltIn else { return }
        // Prevent moving custom items into 기본그룹
        if let dstGroup = groups.first(where: { $0.id == toGroupId }), dstGroup.isDefault {
            return
        }

        var updatedQA = quickAccessItems
        var updatedGroups = groups

        // Remove from source
        let removedItem: QuickAccessItem
        if fromGroupId == "quick_access" {
            guard let idx = updatedQA.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = updatedQA.remove(at: idx)
        } else {
            guard let gIdx = updatedGroups.firstIndex(where: { $0.id == fromGroupId }),
                  !updatedGroups[gIdx].isDefault,
                  let idx = updatedGroups[gIdx].items.firstIndex(where: { $0.path == item.path }) else { return }
            removedItem = updatedGroups[gIdx].items.remove(at: idx)
        }

        // Add to destination (avoiding duplicate path in the same target group)
        if toGroupId == "quick_access" {
            if !updatedQA.contains(where: { $0.path == removedItem.path }) {
                updatedQA.append(removedItem)
            }
        } else if let dstGIdx = updatedGroups.firstIndex(where: { $0.id == toGroupId }), !updatedGroups[dstGIdx].isDefault {
            if !updatedGroups[dstGIdx].items.contains(where: { $0.path == removedItem.path }) {
                updatedGroups[dstGIdx].items.append(removedItem)
            }
        }

        if updatedQA != quickAccessItems {
            quickAccessItems = updatedQA
        }
        if updatedGroups != groups {
            groups = updatedGroups
        }
        save()
    }

    // MARK: - Item Mutations

    /// Adds a folder shortcut to `Quick Access` by default, or to a custom group when `toGroupId` is specified.
    /// Custom folders cannot be added to `기본그룹` (`isDefault == true`).
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

        if let gid = toGroupId, gid != "quick_access" {
            guard let targetIdx = groups.firstIndex(where: { $0.id == gid }),
                  !groups[targetIdx].isDefault else { return }
            guard !groups[targetIdx].items.contains(where: { $0.path == path }) else { return }
            var updatedGroups = groups
            if let targetPath = targetItemPath,
               let relIdx = updatedGroups[targetIdx].items.firstIndex(where: { $0.path == targetPath }) {
                let insertIdx = (position == .above) ? relIdx : relIdx + 1
                let safeIdx = max(0, min(insertIdx, updatedGroups[targetIdx].items.count))
                updatedGroups[targetIdx].items.insert(item, at: safeIdx)
            } else {
                updatedGroups[targetIdx].items.append(item)
            }
            groups = updatedGroups
        } else {
            // QuickAccess is dedicated for "Add to Sidebar"
            guard !quickAccessItems.contains(where: { $0.path == path }) else { return }
            var updatedQA = quickAccessItems
            if let targetPath = targetItemPath,
               let relIdx = updatedQA.firstIndex(where: { $0.path == targetPath }) {
                let insertIdx = (position == .above) ? relIdx : relIdx + 1
                let safeIdx = max(0, min(insertIdx, updatedQA.count))
                updatedQA.insert(item, at: safeIdx)
            } else {
                updatedQA.append(item)
            }
            quickAccessItems = updatedQA
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

    // MARK: - Folder Rename & Delete Synchronization

    /// Updates sidebar items when a folder is renamed or moved.
    func handleItemRenamed(oldPath: String, newPath: String, newName: String) {
        var changed = false

        func normalize(_ p: String) -> String {
            var s = p.precomposedStringWithCanonicalMapping
            while s.contains("//") {
                s = s.replacingOccurrences(of: "//", with: "/")
            }
            while s.hasSuffix("/") && s.count > 1 {
                s.removeLast()
            }
            if s.hasPrefix("/sdcard/") {
                return "/storage/emulated/0/" + s.dropFirst("/sdcard/".count)
            } else if s == "/sdcard" {
                return "/storage/emulated/0"
            }
            return s
        }

        let normOld = normalize(oldPath)
        let normNew = normalize(newPath)
        let oldLastComponent = (normOld as NSString).lastPathComponent
        let newLastComponent = (normNew as NSString).lastPathComponent
        let cleanNewName = newName.trimmingCharacters(in: .whitespacesAndNewlines)

        func updateItemIfNeeded(_ item: QuickAccessItem) -> QuickAccessItem? {
            let itemNorm = normalize(item.path)
            if itemNorm == normOld {
                let nameToUse: String
                if !cleanNewName.isEmpty && cleanNewName != oldLastComponent {
                    // Explicitly renamed
                    nameToUse = cleanNewName
                } else if item.name == oldLastComponent && !newLastComponent.isEmpty {
                    // Default folder name
                    nameToUse = newLastComponent
                } else if !cleanNewName.isEmpty {
                    nameToUse = cleanNewName
                } else {
                    nameToUse = item.name
                }
                return QuickAccessItem(
                    name: nameToUse,
                    icon: item.icon,
                    path: normNew,
                    color: item.color,
                    isBuiltIn: item.isBuiltIn
                )
            } else if itemNorm.hasPrefix(normOld + "/") {
                let suffix = itemNorm.dropFirst(normOld.count)
                let sub = normNew + suffix
                return QuickAccessItem(
                    name: item.name,
                    icon: item.icon,
                    path: sub,
                    color: item.color,
                    isBuiltIn: item.isBuiltIn
                )
            }
            return nil
        }

        // 1. Quick Access items
        for idx in quickAccessItems.indices {
            if let updated = updateItemIfNeeded(quickAccessItems[idx]) {
                quickAccessItems[idx] = updated
                changed = true
            }
        }

        // 2. Groups
        for gIdx in groups.indices {
            for iIdx in groups[gIdx].items.indices {
                if let updated = updateItemIfNeeded(groups[gIdx].items[iIdx]) {
                    groups[gIdx].items[iIdx] = updated
                    changed = true
                }
            }
        }

        if changed {
            let matchingExisting = existingPaths.filter { normalize($0) == normOld || normalize($0).hasPrefix(normOld + "/") }
            for p in matchingExisting {
                existingPaths.remove(p)
                let suffix = normalize(p).dropFirst(normOld.count)
                existingPaths.insert(normNew + suffix)
            }
            existingPaths.insert(normNew)

            let matchingChecked = checkedPaths.filter { normalize($0) == normOld || normalize($0).hasPrefix(normOld + "/") }
            for p in matchingChecked {
                checkedPaths.remove(p)
                let suffix = normalize(p).dropFirst(normOld.count)
                checkedPaths.insert(normNew + suffix)
            }
            checkedPaths.insert(normNew)
            save()
        }
    }

    /// Removes folders from sidebar when deleted.
    func handleItemsDeleted(paths: [String]) {
        guard !paths.isEmpty else { return }

        func normalize(_ p: String) -> String {
            var s = p.precomposedStringWithCanonicalMapping
            while s.contains("//") {
                s = s.replacingOccurrences(of: "//", with: "/")
            }
            while s.hasSuffix("/") && s.count > 1 {
                s.removeLast()
            }
            if s.hasPrefix("/sdcard/") {
                return "/storage/emulated/0/" + s.dropFirst("/sdcard/".count)
            } else if s == "/sdcard" {
                return "/storage/emulated/0"
            }
            return s
        }

        let normalizedDeleted = Set(paths.map { normalize($0) })
        let pathSet = Set(paths)

        func isDeleted(_ itemPath: String) -> Bool {
            let itemNorm = normalize(itemPath)
            if pathSet.contains(itemPath) || normalizedDeleted.contains(itemNorm) {
                return true
            }
            for del in pathSet {
                if itemPath.hasPrefix(del + "/") { return true }
            }
            for delNorm in normalizedDeleted {
                if itemNorm.hasPrefix(delNorm + "/") { return true }
            }
            return false
        }

        var changed = false

        // 1. Quick Access
        let origQACount = quickAccessItems.count
        quickAccessItems.removeAll { isDeleted($0.path) }
        if quickAccessItems.count != origQACount {
            changed = true
        }

        // 2. Groups
        for gIdx in groups.indices {
            let origCount = groups[gIdx].items.count
            for item in groups[gIdx].items where isDeleted(item.path) && item.isBuiltIn {
                let canonical = "/storage/emulated/0" + item.path.dropFirst(internalStoragePath.count)
                hiddenBuiltInPaths.insert(canonical)
            }
            groups[gIdx].items.removeAll { isDeleted($0.path) }
            if groups[gIdx].items.count != origCount {
                changed = true
            }
        }

        if changed {
            for p in paths {
                existingPaths.remove(p)
                checkedPaths.remove(p)
                let norm = normalize(p)
                existingPaths.remove(norm)
                checkedPaths.remove(norm)
            }
            save()
        }
    }

    // MARK: - Existence Checking

    /// Checks if a single path exists on the active device. Returns false only when ADB confirms it doesn't exist.
    func checkPathExists(_ path: String) async -> Bool {
        guard let serial = ADBManager.activeDeviceSerial else { return true }
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return true }

        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        let (code, output, _) = await Shell.runAsync(
            adbPath,
            args: ["-s", serial, "shell", "[ -d '\(escaped)' ] || [ -e '\(escaped)' ] && echo 1 || echo 0"]
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if code == 0 && trimmed == "0" {
            await MainActor.run {
                self.existingPaths.remove(path)
                self.checkedPaths.insert(path)
            }
            return false
        }
        if code == 0 && trimmed == "1" {
            await MainActor.run {
                self.existingPaths.insert(path)
                self.checkedPaths.insert(path)
            }
            return true
        }
        return true
    }

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

        // Guarantee that a default group named "기본그룹" always exists and only contains built-in items
        if let defIdx = groups.firstIndex(where: { $0.isDefault }) {
            groups[defIdx].name = "기본그룹"
            groups[defIdx].items.removeAll { !$0.isBuiltIn && $0.icon != "sdcard.fill" }
        } else {
            let def = SidebarGroup(id: "default", name: "기본그룹", isDefault: true, items: defaultBuiltInItems())
            groups.insert(def, at: 0)
        }

        sortCustomGroups()
    }
}
