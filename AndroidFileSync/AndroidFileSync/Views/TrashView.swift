//
//  TrashView.swift
//  AndroidFileSync
//
//  View for managing deleted files (Trash)
//

import SwiftUI

struct TrashView: View {
    @ObservedObject var fileActionManager: FileActionManager
    var onStorageChanged: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showEmptyTrashConfirmation = false
    @State private var showPermanentDeleteConfirmation = false
    @State private var itemToDelete: TrashedItem? = nil

    private var actionBanner: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.65)
                .frame(width: 14, height: 14)
            Text(fileActionManager.currentAction)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
        .overlay(
            Rectangle()
                .fill(Color.orange.opacity(0.25))
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("trash_title", systemImage: "trash")
                    .font(.headline)
                
                Spacer()
                
                Text(String.localized("common_items_count_format", fileActionManager.trashedItems.count))
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                if !fileActionManager.trashedItems.isEmpty {
                    Button("trash_btn_restore_all") {
                        Task {
                            try? await fileActionManager.restoreAllFromTrash()
                            onStorageChanged?()
                        }
                    }
                    .font(.caption)

                    Button("trash_btn_empty_trash") {
                        showEmptyTrashConfirmation = true
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                }
                
                // Close button
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(.ultraThinMaterial)
            
            Divider()

            if fileActionManager.isPerformingAction {
                actionBanner
            }
            
            // Trash content
            if fileActionManager.trashedItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trash.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("trash_empty_message")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(fileActionManager.trashedItems) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(item.isDirectory ? .blue : .gray)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .lineLimit(1)
                            Text("Deleted \(item.deletedAt, style: .relative) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Restore button
                        Button {
                            Task {
                                try? await fileActionManager.restoreFile(item)
                                onStorageChanged?()
                            }
                        } label: {
                            Label("common_restore", systemImage: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        
                        // Permanent delete button
                        Button {
                            itemToDelete = item
                            showPermanentDeleteConfirmation = true
                        } label: {
                            Label("common_delete", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // Empty Trash confirmation
        .alert(String.localized("trash_alert_empty_title"), isPresented: $showEmptyTrashConfirmation) {
            Button("common_cancel", role: .cancel) { }
            Button("trash_btn_empty_trash", role: .destructive) {
                Task {
                    try? await fileActionManager.emptyTrash()
                    onStorageChanged?()
                }
            }
        } message: {
            Text(String.localized("trash_alert_empty_message_format", fileActionManager.trashedItems.count))
        }
        // Permanent delete confirmation
        .alert(String.localized("trash_alert_delete_title"), isPresented: $showPermanentDeleteConfirmation) {
            Button("common_cancel", role: .cancel) {
                itemToDelete = nil
            }
            Button("common_delete_permanently", role: .destructive) {
                if let item = itemToDelete {
                    Task {
                        try? await fileActionManager.permanentlyDeleteFromTrash(item)
                        onStorageChanged?()
                    }
                }
                itemToDelete = nil
            }
        } message: {
            Text(String.localized("trash_alert_delete_message_format", itemToDelete?.name ?? "This item"))
        }
    }
}

// Undo notification bar that appears after deletion
struct UndoDeleteBar: View {
    let deletedItemName: String
    let onUndo: () -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill")
                .foregroundColor(.white)
            
            Text(String.localized("trash_undo_moved_to_trash_format", deletedItemName))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
            
            Button("common_undo") {
                onUndo()
            }
            .buttonStyle(.bordered)
            .tint(.white)
            
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.9))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

#Preview {
    TrashView(fileActionManager: FileActionManager())
        .frame(width: 400, height: 300)
}
