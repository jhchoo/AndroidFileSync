//
//  FileInfoView.swift
//  AndroidFileSync
//
//  Finder-style "Get Info" panel for files and folders
//

import SwiftUI

struct FileInfoView: View {
    let file: UnifiedFile
    /// Extra metadata fetched from ADB (permissions, owner, group, etc.)
    let info: [String: String]
    let isLoading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────────
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.system(size: 36))
                    .foregroundColor(iconColor)
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text(kindLabel)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider().padding(.horizontal, 16)

            // ── Detail rows ─────────────────────────────────────────────
            ScrollView {
                VStack(spacing: 0) {
                    if isLoading {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("common_loading_info")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        infoRow(label: String.localized("info_label_kind"), value: kindLabel)
                        infoRow(label: String.localized("info_label_size"), value: sizeText)
                        infoRow(label: String.localized("info_label_location"), value: parentPath)
                        infoRow(label: String.localized("info_label_full_path"), value: file.path, selectable: true)

                        if let dateStr = formattedDate {
                            infoRow(label: String.localized("info_label_modified"), value: dateStr)
                        } else if let dateStr = info["modified"] {
                            infoRow(label: String.localized("info_label_modified"), value: dateStr)
                        }

                        if let perms = info["permissions"] {
                            Divider().padding(.horizontal, 16).padding(.vertical, 4)
                            infoRow(label: String.localized("info_label_permissions"), value: perms)
                        }
                        if let owner = info["owner"] {
                            infoRow(label: String.localized("info_label_owner"), value: owner)
                        }
                        if let group = info["group"] {
                            infoRow(label: String.localized("info_label_group"), value: group)
                        }
                    }
                }
                .padding(.vertical, 10)
            }

            Divider().padding(.horizontal, 16)

            // ── Footer ──────────────────────────────────────────────────
            HStack {
                Spacer()
                Button("common_done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 360, height: 420)
    }

    // MARK: - Row Builder

    private func infoRow(label: String, value: String, selectable: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)

            if selectable {
                Text(value)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(value)
                    .font(.system(size: 12))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    // MARK: - Computed Properties

    private var iconName: String {
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
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "m4a", "wav", "flac": return "music.note"
        case "pdf": return "doc.text"
        case "zip", "rar", "7z": return "doc.zipper"
        case "apk": return "app.badge"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        if file.isDirectory { return .blue }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .purple
        case "mp4", "mov", "avi", "mkv": return .red
        case "mp3", "m4a", "wav", "flac": return .pink
        case "pdf": return .orange
        case "apk": return .green
        default: return .secondary
        }
    }

    private var kindLabel: String {
        if file.isDirectory { return String.localized("info_kind_folder") }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return String.localized("info_kind_file") }
        switch ext {
        case "jpg", "jpeg": return String.localized("info_kind_jpeg")
        case "png": return String.localized("info_kind_png")
        case "gif": return String.localized("info_kind_gif")
        case "heic": return String.localized("info_kind_heic")
        case "webp": return String.localized("info_kind_webp")
        case "mp4": return String.localized("info_kind_mp4")
        case "mov": return String.localized("info_kind_mov")
        case "avi": return String.localized("info_kind_avi")
        case "mkv": return String.localized("info_kind_mkv")
        case "mp3": return String.localized("info_kind_mp3")
        case "m4a": return String.localized("info_kind_m4a")
        case "wav": return String.localized("info_kind_wav")
        case "flac": return String.localized("info_kind_flac")
        case "pdf": return String.localized("info_kind_pdf")
        case "zip": return String.localized("info_kind_zip")
        case "rar": return String.localized("info_kind_rar")
        case "7z": return String.localized("info_kind_7z")
        case "apk": return String.localized("info_kind_apk")
        case "txt": return String.localized("info_kind_txt")
        case "md": return String.localized("info_kind_md")
        case "doc", "docx": return String.localized("info_kind_doc")
        case "xls", "xlsx": return String.localized("info_kind_xls")
        case "ppt", "pptx": return String.localized("info_kind_ppt")
        default: return String.localized("info_kind_custom_format", ext.uppercased())
        }
    }

    private var sizeText: String {
        if let sizeStr = info["size"], let bytes = UInt64(sizeStr) {
            return formatBytes(bytes)
        }
        // Directory entry size is not useful for users; show only computed recursive size.
        if file.isDirectory {
            return "--"
        }
        if file.size > 0 {
            return formatBytes(file.size)
        }
        return "0 bytes"
    }

    private var parentPath: String {
        (file.path as NSString).deletingLastPathComponent
    }

    private var formattedDate: String? {
        guard let date = file.modificationDate else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}
