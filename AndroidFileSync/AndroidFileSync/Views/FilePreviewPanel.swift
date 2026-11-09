//
//  FilePreviewPanel.swift
//  AndroidFileSync
//
//  In-app QuickLook-style preview panel — shows instant thumbnails for images/videos
//  without pulling the entire file. Styled after macOS QuickLook with vibrancy,
//  spring animations, and native material effects.
//

import SwiftUI
import AVKit
import PDFKit
internal import Combine

// MARK: - Preview Panel

struct FilePreviewPanel: View {
    @ObservedObject var previewManager: FilePreviewManager
    @StateObject private var pdfCoordinator = PDFPreviewCoordinator()
    
    @State private var appeared = false
    @State private var imageScale: CGFloat = 1.0
    
    var body: some View {
        ZStack {
            // Dimmed backdrop — click to dismiss
            Color.black
                .opacity(appeared ? 0.55 : 0)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Close preview")
            
            // Full content area panel
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(20)
                .scaleEffect(appeared ? 1.0 : 0.94)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                appeared = true
            }
        }
        .onExitCommand { dismiss() }
    }
    
    // MARK: - Panel Layout
    
    private var panelContent: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            contentArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            bottomToolbar
        }
    }
    
    // MARK: - Title Bar
    
    private var titleBar: some View {
        HStack(spacing: 8) {
            // Category icon
            categoryIcon
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            
            // File name
            Text(previewManager.previewFile?.name ?? "Preview")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // File size badge
            if let file = previewManager.previewFile, file.size > 0 {
                Text(formatBytes(file.size))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            
            // Close
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Close preview")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    // MARK: - Category Icon
    
    @ViewBuilder
    private var categoryIcon: some View {
        let category = previewManager.previewFile.map {
            PreviewFileCategory(extension: $0.pathExtension)
        } ?? .unknown
        
        Image(systemName: category.symbolName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor(for: category))
    }
    
    private func iconColor(for category: PreviewFileCategory) -> Color {
        switch category {
        case .image: return .blue
        case .video: return .purple
        case .audio: return .pink
        case .pdf: return .red
        case .document: return .orange
        case .unknown: return .gray
        }
    }
    
    // MARK: - Content Area
    
    @ViewBuilder
    private var contentArea: some View {
        switch previewManager.previewContent {
        case .loading:
            loadingView
        case .image(let nsImage):
            imagePreview(nsImage)
        case .videoThumbnail(let nsImage):
            videoThumbnailPreview(nsImage)
        case .videoReady(let url):
            inlineVideoPlayer(url: url)
        case .pdfReady(let url):
            pdfPreview(url: url)
        case .audioIcon:
            audioPreview
        case .documentIcon(let ext):
            documentPreview(ext)
        case .error(let message):
            errorView(message)
        }
    }
    
    // MARK: - Loading
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            LoadingSpinner(size: 28)
            
            Text("Loading preview…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Image Preview
    
    private func imagePreview(_ nsImage: NSImage) -> some View {
        GeometryReader { geo in
            let fitted = fittedSize(image: nsImage.size, container: geo.size)
            
            ScrollView([.horizontal, .vertical], showsIndicators: false) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        width: fitted.width * imageScale,
                        height: fitted.height * imageScale
                    )
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    imageScale = imageScale > 1.0 ? 1.0 : 2.5
                }
            }
            .accessibilityLabel("Image preview. Double-click to zoom.")
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.3))
    }
    
    /// Calculate the largest size that fits the image inside the container without upscaling.
    private func fittedSize(image: NSSize, container: CGSize) -> CGSize {
        let scale = min(
            container.width / image.width,
            container.height / image.height,
            1.0
        )
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
    
    // MARK: - Video Thumbnail Preview (while pulling)
    
    private func videoThumbnailPreview(_ thumbnail: NSImage) -> some View {
        ZStack {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            VStack(spacing: 12) {
                if previewManager.isLoadingFullFile {
                    // Downloading state
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.25), radius: 10)
                        
                        ProgressView()
                            .controlSize(.regular)
                    }
                    
                    VStack(spacing: 8) {
                        Text(previewManager.fullFilePullProgress.isEmpty ? "Downloading…" : previewManager.fullFilePullProgress)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                        
                        Button {
                            previewManager.cancelPreview()
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                                .background(.red.opacity(0.6), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    // Idle state — tappable play button
                    Button {
                        previewManager.openInExternalApp()
                    } label: {
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(.ultraThinMaterial)
                                    .frame(width: 64, height: 64)
                                    .shadow(color: .black.opacity(0.25), radius: 10)
                                
                                Image(systemName: "play.fill")
                                    .font(.system(size: 24, weight: .medium))
                                    .foregroundStyle(.white)
                                    .offset(x: 2)
                            }
                            
                            Text("Open in App to play")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.black.opacity(0.5), in: Capsule())
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color.black.opacity(0.05))
        .accessibilityLabel("Video preview")
    }
    
    // MARK: - Inline Video Player
    
    private func inlineVideoPlayer(url: URL) -> some View {
        VideoPlayerView(url: url)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .transition(.opacity)
    }

    // MARK: - PDF Preview

    private func pdfPreview(url: URL) -> some View {
        ZStack(alignment: .trailing) {
            PDFKitRepresentable(url: url, coordinator: pdfCoordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(NSColor.windowBackgroundColor))

            PDFRightNavigationRail(coordinator: pdfCoordinator)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .accessibilityLabel("PDF Document Preview")
    }
    
    // MARK: - Audio Preview
    
    private var audioPreview: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 80))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.pink)
            
            fileInfoStack
            
            Text("Open in App to play audio")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Audio file preview")
    }
    
    // MARK: - Document Preview
    
    private func documentPreview(_ ext: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: documentSymbol(for: ext))
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.blue)
            
            fileInfoStack
            
            if !ext.isEmpty {
                Text(ext.uppercased())
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// Shared file name + size + date stack
    @ViewBuilder
    private var fileInfoStack: some View {
        if let file = previewManager.previewFile {
            VStack(spacing: 4) {
                Text(file.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                
                Text(formatBytes(file.size))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                
                if let date = file.modificationDate {
                    Text(date, style: .date)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
    
    private func documentSymbol(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":                              return "doc.richtext"
        case "txt", "md", "rtf":                 return "doc.text"
        case "html", "htm":                      return "globe"
        case "json", "xml", "csv":               return "tablecells"
        case "xls", "xlsx":                      return "tablecells"
        case "ppt", "pptx":                      return "rectangle.on.rectangle"
        case "swift", "java", "py", "js", "ts",
             "c", "cpp", "h", "css":             return "chevron.left.forwardslash.chevron.right"
        default:                                 return "doc"
        }
    }
    
    // MARK: - Error View
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.yellow)
            
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Bottom Toolbar
    
    private var bottomToolbar: some View {
        HStack(spacing: 12) {
            // Category badge
            if let file = previewManager.previewFile {
                let category = PreviewFileCategory(extension: file.pathExtension)
                Text(category.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            
            Spacer()
            
            // Full pull progress indicator
            if previewManager.isLoadingFullFile {
                HStack(spacing: 6) {
                    LoadingSpinner(size: 13)
                    Text(previewManager.fullFilePullProgress)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
            
            // Open in external app
            Button {
                previewManager.openInExternalApp()
            } label: {
                Label("Open in App", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.accentColor)
            .disabled(previewManager.isLoadingFullFile)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    // MARK: - Dismiss
    
    private func dismiss() {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.9)) {
            appeared = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            previewManager.dismissPreview()
        }
    }
}

// MARK: - PDF Coordinator

@MainActor
final class PDFPreviewCoordinator: ObservableObject {
    @Published var pageCount: Int = 1
    @Published var currentPageIndex: Int = 0
    private weak var currentPDFView: PDFView?

    func attach(pdfView: PDFView) {
        self.currentPDFView = pdfView
        updatePages()

        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )
    }

    func updatePages() {
        guard let doc = currentPDFView?.document else { return }
        self.pageCount = max(doc.pageCount, 1)
        if let current = currentPDFView?.currentPage {
            let idx = doc.index(for: current)
            if idx >= 0 && idx < doc.pageCount {
                self.currentPageIndex = idx
            }
        }
    }

    @objc private func handlePageChanged(_ note: Notification) {
        guard let doc = currentPDFView?.document, let current = currentPDFView?.currentPage else { return }
        let idx = doc.index(for: current)
        if idx >= 0 && idx < doc.pageCount && self.currentPageIndex != idx {
            self.currentPageIndex = idx
        }
        if self.pageCount != doc.pageCount {
            self.pageCount = max(doc.pageCount, 1)
        }
    }

    func goToPage(_ index: Int) {
        guard let doc = currentPDFView?.document,
              index >= 0 && index < doc.pageCount,
              let targetPage = doc.page(at: index) else { return }
        currentPDFView?.go(to: targetPage)
        self.currentPageIndex = index
    }
}

// MARK: - Native PDFKit View

struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL
    let coordinator: PDFPreviewCoordinator

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.autoresizingMask = [.width, .height]
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = NSColor.windowBackgroundColor
        pdfView.enableDataDetectors = false // Prevents E5 TextRecognition errors & stall

        loadDocument(into: pdfView)
        coordinator.attach(pdfView: pdfView)

        DispatchQueue.main.async {
            pdfView.layoutDocumentView()
            pdfView.autoScales = true
            coordinator.updatePages()
        }

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            loadDocument(into: pdfView)
            coordinator.attach(pdfView: pdfView)
            DispatchQueue.main.async {
                pdfView.layoutDocumentView()
                pdfView.autoScales = true
                coordinator.updatePages()
            }
        }
    }

    private func loadDocument(into pdfView: PDFView) {
        if let doc = PDFDocument(url: url) {
            pdfView.document = doc
        } else if let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data) {
            pdfView.document = doc
        }
    }
}

// MARK: - PDF Right Navigation Rail

struct PDFRightNavigationRail: View {
    @ObservedObject var coordinator: PDFPreviewCoordinator

    private var progress: Double {
        guard coordinator.pageCount > 1 else { return 1.0 }
        return Double(coordinator.currentPageIndex) / Double(coordinator.pageCount - 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Page badge (e.g. 3 / 12)
            VStack(spacing: 1) {
                Text("\(coordinator.currentPageIndex + 1)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.primary)
                Text("/ \(coordinator.pageCount)")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)

            // Vertical navigation track
            GeometryReader { geo in
                let trackHeight = geo.size.height
                ZStack(alignment: .top) {
                    // Clickable track background
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                        .frame(width: 6)
                        .frame(maxWidth: .infinity)

                    // Progress fill down to current page
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: max(trackHeight * CGFloat(progress), 6))
                        .frame(maxWidth: .infinity, alignment: .top)

                    // Current page thumb handle
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .overlay(
                            Circle()
                                .stroke(Color.accentColor, lineWidth: 1.5)
                        )
                        .frame(width: 14, height: 14)
                        .offset(y: max(0, min(trackHeight - 14, (trackHeight - 14) * CGFloat(progress))))
                        .frame(maxWidth: .infinity)

                    // Page tick marks if manageable page count
                    if coordinator.pageCount > 1 && coordinator.pageCount <= 30 {
                        ForEach(0..<coordinator.pageCount, id: \.self) { idx in
                            let y = (trackHeight - 14) * (CGFloat(idx) / CGFloat(coordinator.pageCount - 1)) + 7
                            Circle()
                                .fill(idx == coordinator.currentPageIndex ? Color.accentColor : Color.primary.opacity(0.3))
                                .frame(width: idx == coordinator.currentPageIndex ? 4 : 2, height: idx == coordinator.currentPageIndex ? 4 : 2)
                                .offset(y: y - (idx == coordinator.currentPageIndex ? 2 : 1))
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard trackHeight > 0 else { return }
                            let clampedY = max(0, min(value.location.y, trackHeight))
                            let fraction = clampedY / trackHeight
                            let targetPage = Int(round(fraction * Double(coordinator.pageCount - 1)))
                            coordinator.goToPage(targetPage)
                        }
                )
            }
            .padding(.vertical, 4)

            // Progress percentage
            Text("\(Int(round(progress * 100)))%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(width: 44)
        .padding(.vertical, 10)
        .padding(.horizontal, 3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        )
        .padding(.trailing, 12)
        .padding(.vertical, 12)
    }
}
