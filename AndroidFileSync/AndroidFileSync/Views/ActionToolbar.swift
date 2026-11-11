//
//  ActionToolbar.swift
//  AndroidFileSync
//
//  Toolbar with file action buttons (New Folder, New File, Refresh, etc.)
//

import SwiftUI

struct ActionToolbar: View {
    let currentPath: String
    @ObservedObject var fileActionManager: FileActionManager
    let onRefresh: () async -> Void
    // Dialog states
    @State private var showNewFolderDialog = false
    @State private var showNewFileDialog = false

    // Search state - bound to parent
    @Binding var searchQuery: String
    var totalFileCount: Int = 0
    var filteredFileCount: Int = 0
    
    // Sorting - passed in from parent for sync with column headers
    var selectedSort: SortOption = .name
    var onSortChanged: ((SortOption) -> Void)?
    @FocusState private var isSearchFocused: Bool
    
    enum SortOption: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case type = "Type"
        case date = "Date"

        var localizedKey: LocalizedStringKey {
            switch self {
            case .name: return "common_sort_name"
            case .size: return "common_sort_size"
            case .type: return "common_sort_type"
            case .date: return "common_sort_date"
            }
        }
    }
    
    var isSearchActive: Bool {
        !searchQuery.isEmpty
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // New Folder button
            Button {
                if let name = TextInputDialog.show(
                    title: String.localized("file_browser_dialog_new_folder_title"),
                    message: String.localized("file_browser_dialog_new_folder_message"),
                    placeholder: String.localized("file_browser_dialog_new_folder_placeholder"),
                    initialValue: String.localized("file_browser_dialog_new_folder_default_name"),
                    confirmLabel: String.localized("common_create")
                ) {
                    Task {
                        do {
                            try await fileActionManager.createFolder(at: currentPath, name: name)
                            await onRefresh()
                        } catch {
                            print("Failed to create folder: \(error.localizedDescription)")
                        }
                    }
                }
            } label: {
                Label("file_browser_btn_new_folder", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(Text("file_browser_help_new_folder"))
            .keyboardShortcut("n", modifiers: [.command, .shift])
            
            // New File button
            Button {
                if let name = TextInputDialog.show(
                    title: String.localized("file_browser_dialog_new_file_title"),
                    message: String.localized("file_browser_dialog_new_file_message"),
                    placeholder: String.localized("file_browser_dialog_new_file_placeholder"),
                    initialValue: "untitled.txt",
                    confirmLabel: String.localized("common_create")
                ) {
                    Task {
                        do {
                            try await fileActionManager.createFile(at: currentPath, name: name)
                            await onRefresh()
                        } catch {
                            print("Failed to create file: \(error.localizedDescription)")
                        }
                    }
                }
            } label: {
                Label("file_browser_btn_new_file", systemImage: "doc.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help(Text("file_browser_help_new_file"))
            
            Divider()
                .frame(height: 16)
            
            // Clipboard indicator or Loading indicator
            if fileActionManager.isPerformingAction {
                // Show loading indicator during action - flexible but won't grow infinitely
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text(fileActionManager.currentAction)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 200) // Max width, but can shrink
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(6)
                .layoutPriority(-1) // Lower priority than search field
                
                Divider()
                    .frame(height: 16)
            } else if !fileActionManager.clipboard.isEmpty {
                HStack(spacing: 6) {
                    // Operation icon + count
                    Image(systemName: fileActionManager.clipboardOperation == .cut ? "scissors" : "doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text("\(fileActionManager.clipboard.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Divider()
                        .frame(height: 12)
                    
                    // Paste button (icon + text, non-wrapping)
                    Button {
                        Task {
                            do {
                                try await fileActionManager.paste(to: currentPath)
                            } catch {
                                AppLogger.log("❌ [ActionToolbar] Paste failed: \(error.localizedDescription)", level: .error)
                            }
                            await onRefresh()
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("common_paste")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderless)
                    
                    // Clear clipboard
                    Button {
                        fileActionManager.clearClipboard()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help(Text("common_help_clear_clipboard"))
                }
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(6)
                
                Divider()
                    .frame(height: 16)
            }
            Spacer()
            
            // Search Field - Always visible, better styled
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(isSearchActive ? .accentColor : .secondary)
                
                TextField("common_search_files_placeholder", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 120, maxWidth: 200)
                    .focused($isSearchFocused)
                
                // Clear button or result count
                if isSearchActive {
                    HStack(spacing: 4) {
                        // Show filtered count
                        Text("\(filteredFileCount)/\(totalFileCount)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                        
                        // Clear button
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(Text("common_help_clear_search"))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSearchFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            )
            .layoutPriority(1) // Higher priority than action indicator
            .onTapGesture {
                isSearchFocused = true
            }
            
            // Sort menu
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button {
                        onSortChanged?(option)
                    } label: {
                        HStack {
                            Text(option.localizedKey)
                            if selectedSort == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(selectedSort.localizedKey)
                        .font(.caption)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)
            .help(Text("common_help_sort_by"))
            
            // Refresh button
            Button {
                Task { await onRefresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(Text("common_help_refresh"))
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        // Handle Escape key to clear search
        .onExitCommand {
            if isSearchActive {
                searchQuery = ""
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var search = ""
        var body: some View {
            ActionToolbar(
                currentPath: "/sdcard",
                fileActionManager: FileActionManager(),
                onRefresh: {},
                searchQuery: $search,
                totalFileCount: 50,
                filteredFileCount: 12
            )
        }
    }
    return PreviewWrapper()
}
