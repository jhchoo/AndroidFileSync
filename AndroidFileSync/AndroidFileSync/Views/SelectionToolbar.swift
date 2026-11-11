//
//  SelectionToolbar.swift
//  AndroidFileSync
//
//  Toolbar for batch operations on selected files
//

import SwiftUI

struct SelectionToolbar: View {
    let selectedFiles: [UnifiedFile]
    let onClearSelection: () -> Void
    let onDelete: () -> Void
    let onDownload: () -> Void
    let onRename: ((UnifiedFile, String) -> Void)?
    let onChangeExtension: ((String) -> Void)?
    var onPermanentDelete: (() -> Void)? = nil
    
    @State private var showingDeleteConfirmation = false
    @State private var showingPermanentDeleteConfirmation = false
    @State private var showingRenameDialog = false
    @State private var showingExtensionDialog = false
    @State private var newFileName = ""
    @State private var newExtension = ""
    
    private var selectedCount: Int { selectedFiles.count }
    private var isSingleSelection: Bool { selectedCount == 1 }
    private var singleItem: UnifiedFile? { isSingleSelection ? selectedFiles.first : nil }
    
    // Check if ALL selected items are files (no folders)
    private var hasOnlyFiles: Bool { 
        !selectedFiles.isEmpty && selectedFiles.allSatisfy { !$0.isDirectory } 
    }
    
    // Show rename for single selection (file OR folder)
    private var showRename: Bool {
        isSingleSelection && onRename != nil
    }
    
    // Show change extension for multiple files only (no folders)
    private var showChangeExtension: Bool {
        selectedCount > 1 && hasOnlyFiles && onChangeExtension != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 12) {
                // Selection count
                Label(String.localized("common_selected_count_format", selectedCount), systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.blue)
                
                Spacer()
                
                // Clear selection
                Button {
                    onClearSelection()
                } label: {
                    Label("common_clear", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                
                Divider()
                    .frame(height: 20)
                
                // Rename (only for single selection - file or folder)
                if showRename {
                    Button {
                        if let item = singleItem {
                            newFileName = item.name
                            showingRenameDialog = true
                        }
                    } label: {
                        Label("common_rename", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                
                // Change Extension (only for multiple files, no folders)
                if showChangeExtension {
                    Button {
                        showingExtensionDialog = true
                    } label: {
                        Label("file_browser_btn_change_ext", systemImage: "doc.badge.gearshape")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                
                // Download - only show if there are files (not just folders)
                if hasOnlyFiles {
                    Button {
                        onDownload()
                    } label: {
                        Label(isSingleSelection ? "file_browser_btn_download_to_mac" : "file_browser_btn_download_all_to_mac", systemImage: "arrow.down.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                
                // Move to Trash
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Label(isSingleSelection ? "file_browser_btn_move_to_trash" : "file_browser_btn_move_all_to_trash", systemImage: "trash.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)

                // Delete Permanently
                if onPermanentDelete != nil {
                    Button {
                        showingPermanentDeleteConfirmation = true
                    } label: {
                        Label(isSingleSelection ? "file_browser_btn_delete_permanently" : "file_browser_btn_delete_all_permanently", systemImage: "trash.slash.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(Color(hue: 0.0, saturation: 0.9, brightness: 0.7))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        // Move to Trash confirmation
        .alert(isSingleSelection ? String.localized("file_browser_alert_move_item_to_trash_format", singleItem?.name ?? "") : String.localized("file_browser_alert_move_items_to_trash_format", selectedCount),
               isPresented: $showingDeleteConfirmation) {
            Button("common_cancel", role: .cancel) { }
            Button("file_browser_btn_move_to_trash", role: .destructive) {
                onDelete()
            }
        } message: {
            Text(isSingleSelection ? "file_browser_alert_restore_single_message" : "file_browser_alert_restore_multiple_message")
        }
        // Permanent delete confirmation
        .alert(isSingleSelection ? String.localized("file_browser_alert_delete_item_permanently_format", singleItem?.name ?? "") : String.localized("file_browser_alert_delete_items_permanently_format", selectedCount),
               isPresented: $showingPermanentDeleteConfirmation) {
            Button("common_cancel", role: .cancel) { }
            Button("file_browser_btn_delete_permanently", role: .destructive) {
                onPermanentDelete?()
            }
        } message: {
            Text(isSingleSelection ? "file_browser_alert_permanent_single_message" : "file_browser_alert_permanent_multiple_message")
        }
        // Rename dialog
        .alert(singleItem?.isDirectory == true ? String.localized("file_browser_dialog_rename_folder_title") : String.localized("file_browser_dialog_rename_file_title"), isPresented: $showingRenameDialog) {
            TextField("file_browser_dialog_new_name_placeholder", text: $newFileName)
            Button("common_cancel", role: .cancel) {
                newFileName = ""
            }
            Button("common_rename") {
                if let item = singleItem, !newFileName.isEmpty && newFileName != item.name {
                    onRename?(item, newFileName)
                }
                newFileName = ""
            }
        } message: {
            Text(String.localized("file_browser_dialog_rename_message_format", singleItem?.name ?? ""))
        }
        // Change extension dialog
        .alert(String.localized("file_browser_dialog_change_extension_title"), isPresented: $showingExtensionDialog) {
            TextField("file_browser_dialog_new_extension_placeholder", text: $newExtension)
            Button("common_cancel", role: .cancel) {
                newExtension = ""
            }
            Button(String.localized("file_browser_dialog_apply_files_format", selectedCount)) {
                if !newExtension.isEmpty {
                    let ext = newExtension.hasPrefix(".") ? String(newExtension.dropFirst()) : newExtension
                    onChangeExtension?(ext)
                }
                newExtension = ""
            }
        } message: {
            Text(String.localized("file_browser_dialog_change_extension_message_format", selectedCount))
        }
    }
}

#Preview {
    VStack {
        Spacer()
        SelectionToolbar(
            selectedFiles: [
                UnifiedFile(name: "test.jpg", path: "/test.jpg", isDirectory: false, size: 1024)
            ],
            onClearSelection: {},
            onDelete: {},
            onDownload: {},
            onRename: { _, _ in },
            onChangeExtension: nil
        )
    }
}
