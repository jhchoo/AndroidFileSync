import SwiftUI

struct StorageAccessErrorView: View {
    let message: String
    let canRepair: Bool
    let isRepairing: Bool
    let isLoading: Bool
    let onRepair: () -> Void
    let onRetry: () -> Void
    let onSaveDiagnostics: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(canRepair ? "storage_access_blocked" : "storage_access_couldnt_open")
                .font(.title2.weight(.semibold))
            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            if canRepair {
                Text("storage_access_notice")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            HStack(spacing: 12) {
                if canRepair {
                    Button(action: onRepair) {
                        HStack {
                            if isRepairing { ProgressView().controlSize(.small) }
                            Text(isRepairing ? "storage_access_fixing" : "storage_access_fix_btn")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(isLoading ? "common_checking_files" : "common_try_again", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .disabled(isRepairing || isLoading)
            Button("storage_access_save_diagnostics", action: onSaveDiagnostics)
                .buttonStyle(.link)
                .disabled(isRepairing || isLoading)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
