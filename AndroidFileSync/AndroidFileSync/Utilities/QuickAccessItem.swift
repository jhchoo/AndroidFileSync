import Foundation
import AppKit

struct QuickAccessItem: Identifiable, Codable, Equatable {
    /// Stable ID — use the path so items survive app restarts
    var id: String { path }
    let name: String
    let icon: String
    let path: String
    let color: String
    /// true = ships with the app (can be hidden but not deleted)
    let isBuiltIn: Bool

    init(name: String, icon: String, path: String, color: String, isBuiltIn: Bool = false) {
        self.name = name
        self.icon = icon
        self.path = path
        self.color = color
        self.isBuiltIn = isBuiltIn
    }

    static let commonFolders: [QuickAccessItem] = [
        QuickAccessItem(name: "Internal Storage", icon: "internaldrive.fill",    path: "/storage/emulated/0",           color: "blue",   isBuiltIn: true),
        QuickAccessItem(name: "Camera",           icon: "camera.fill",           path: "/storage/emulated/0/DCIM",      color: "purple", isBuiltIn: true),
        QuickAccessItem(name: "Downloads",        icon: "arrow.down.circle.fill",path: "/storage/emulated/0/Download",  color: "green",  isBuiltIn: true),
        QuickAccessItem(name: "Pictures",         icon: "photo.fill",            path: "/storage/emulated/0/Pictures",  color: "pink",   isBuiltIn: true),
        QuickAccessItem(name: "Music",            icon: "music.note",            path: "/storage/emulated/0/Music",     color: "red",    isBuiltIn: true),
        QuickAccessItem(name: "Movies",           icon: "film.fill",             path: "/storage/emulated/0/Movies",    color: "cyan",   isBuiltIn: true),
        QuickAccessItem(name: "Documents",        icon: "doc.fill",              path: "/storage/emulated/0/Documents", color: "yellow", isBuiltIn: true),
    ]
}

struct SidebarGroup: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    /// true = default group that cannot be deleted
    var isDefault: Bool
    var items: [QuickAccessItem]

    init(id: String = UUID().uuidString, name: String, isDefault: Bool = false, items: [QuickAccessItem] = []) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
        self.items = items
    }
}

extension String {
    var color: NSColor {
        switch self {
        case "blue":   return .systemBlue
        case "purple": return .systemPurple
        case "orange": return .systemOrange
        case "green":  return .systemGreen
        case "pink":   return .systemPink
        case "red":    return .systemRed
        case "cyan":   return .systemCyan
        case "yellow": return .systemYellow
        default:       return .systemGray
        }
    }
}
