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
    @State private var showPDFThumbnails = true
    
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
            if isPDFPreview {
                pdfCoordinator.startKeyMonitoring()
            }
        }
        .onDisappear {
            pdfCoordinator.stopKeyMonitoring()
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
    
    private var isPDFPreview: Bool {
        if case .pdfReady = previewManager.previewContent { return true }
        return false
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            // PDF 썸네일 사이드바 토글 버튼 (맨 왼쪽)
            if isPDFPreview {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPDFThumbnails.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(showPDFThumbnails ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(
                            showPDFThumbnails ? Color.accentColor.opacity(0.15) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5)
                        )
                }
                .buttonStyle(.plain)
                .help(showPDFThumbnails ? "사이드바 숨기기" : "사이드바 보기")
            }

            // Category icon
            categoryIcon
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            
            // File name
            Text(previewManager.previewFile?.name ?? "Preview")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: isPDFPreview ? 180 : 380, alignment: .leading)
            
            // PDF 확대/축소 및 가로/세로 맞춤 컨트롤 바 (네비게이션바 좌측 영역)
            if isPDFPreview {
                PDFZoomControlBar(coordinator: pdfCoordinator)
            }

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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
        HStack(spacing: 0) {
            if showPDFThumbnails {
                PDFThumbnailSidebarView(
                    coordinator: pdfCoordinator,
                    onToggleSidebar: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPDFThumbnails.toggle()
                        }
                    }
                )
                .frame(width: 140)
                .transition(.move(edge: .leading).combined(with: .opacity))

                Rectangle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: 1)
            }

            PDFKitRepresentable(url: url, coordinator: pdfCoordinator)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.18))
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
        pdfCoordinator.stopKeyMonitoring()
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
    @Published var scaleFactor: CGFloat = 1.0
    @Published var document: PDFDocument?
    private weak var currentPDFView: PDFView?
    private var keyMonitor: Any?

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func startKeyMonitoring() {
        stopKeyMonitoring()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyDown(event)
        }
    }

    func stopKeyMonitoring() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        guard let doc = currentPDFView?.document, doc.pageCount > 1 else {
            return event
        }
        guard let window = NSApp.keyWindow, window.isKeyWindow else {
            return event
        }
        if let responder = window.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd + Up / Cmd + Down -> First / Last page
        if flags.contains(.command) && flags.intersection([.option, .control]).isEmpty {
            switch event.keyCode {
            case 126: // Cmd + Up
                goToPage(0)
                return nil
            case 125: // Cmd + Down
                goToPage(doc.pageCount - 1)
                return nil
            default:
                return event
            }
        }

        guard flags.intersection([.command, .option, .control]).isEmpty else {
            return event
        }

        switch event.keyCode {
        case 125, 124, 121: // Down Arrow (125), Right Arrow (124), Page Down (121)
            goToNextPage()
            return nil
        case 126, 123, 116: // Up Arrow (126), Left Arrow (123), Page Up (116)
            goToPreviousPage()
            return nil
        default:
            return event
        }
    }

    func attach(pdfView: PDFView) {
        self.currentPDFView = pdfView
        self.document = pdfView.document
        self.scaleFactor = pdfView.scaleFactor
        updatePages()

        NotificationCenter.default.removeObserver(self, name: .PDFViewPageChanged, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        NotificationCenter.default.removeObserver(self, name: .PDFViewScaleChanged, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )

        startKeyMonitoring()
    }

    func updatePages() {
        guard let doc = currentPDFView?.document else { return }
        self.document = doc
        self.pageCount = max(doc.pageCount, 1)
        if let current = currentPDFView?.currentPage {
            let idx = doc.index(for: current)
            if idx >= 0 && idx < doc.pageCount {
                self.currentPageIndex = idx
            }
        }
        if let pdfView = currentPDFView {
            self.scaleFactor = pdfView.scaleFactor
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

    @objc private func handleScaleChanged(_ note: Notification) {
        guard let pdfView = currentPDFView else { return }
        if abs(self.scaleFactor - pdfView.scaleFactor) > 0.001 {
            self.scaleFactor = pdfView.scaleFactor
        }
    }

    func goToPage(_ index: Int) {
        guard let doc = currentPDFView?.document,
              index >= 0 && index < doc.pageCount,
              let targetPage = doc.page(at: index) else { return }
        let pageBounds = targetPage.bounds(for: currentPDFView?.displayBox ?? .cropBox)
        let destination = PDFDestination(page: targetPage, at: CGPoint(x: 0, y: pageBounds.height))
        currentPDFView?.go(to: destination)
        self.currentPageIndex = index
    }

    func goToNextPage() {
        guard currentPageIndex + 1 < pageCount else { return }
        goToPage(currentPageIndex + 1)
    }

    func goToPreviousPage() {
        guard currentPageIndex > 0 else { return }
        goToPage(currentPageIndex - 1)
    }

    func zoomIn() {
        guard let pdfView = currentPDFView else { return }
        pdfView.autoScales = false
        pdfView.zoomIn(nil)
        self.scaleFactor = pdfView.scaleFactor
    }

    func zoomOut() {
        guard let pdfView = currentPDFView else { return }
        pdfView.autoScales = false
        pdfView.zoomOut(nil)
        self.scaleFactor = pdfView.scaleFactor
    }

    func resetZoom() {
        guard let pdfView = currentPDFView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = 1.0
        self.scaleFactor = 1.0
    }

    func fitToWidth() {
        guard let pdfView = currentPDFView, let page = pdfView.currentPage else { return }
        pdfView.autoScales = false
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let availableWidth = max(pdfView.bounds.width - 40, 100)
        if pageBounds.width > 0 {
            let targetScale = availableWidth / pageBounds.width
            let clamped = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, targetScale))
            pdfView.scaleFactor = clamped
            self.scaleFactor = clamped
        }
    }

    func fitToHeight() {
        guard let pdfView = currentPDFView, let page = pdfView.currentPage else { return }
        pdfView.autoScales = false
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let availableHeight = max(pdfView.bounds.height - 40, 100)
        if pageBounds.height > 0 {
            let targetScale = availableHeight / pageBounds.height
            let clamped = max(pdfView.minScaleFactor, min(pdfView.maxScaleFactor, targetScale))
            pdfView.scaleFactor = clamped
            self.scaleFactor = clamped
        }
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
        pdfView.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0)
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

// MARK: - PDF Zoom & Fit Control Bar

struct PDFZoomControlBar: View {
    @ObservedObject var coordinator: PDFPreviewCoordinator

    var body: some View {
        HStack(spacing: 6) {
            dividerLine

            // Zoom Out (-)
            Button {
                coordinator.zoomOut()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("축소 (Zoom Out)")

            // Percentage Display
            Text("\(Int(round(coordinator.scaleFactor * 100)))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 40)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                .help("100%로 재설정")
                .onTapGesture {
                    coordinator.resetZoom()
                }

            // Zoom In (+)
            Button {
                coordinator.zoomIn()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("확대 (Zoom In)")

            dividerLine

            // Fit to Width (가로맞춤)
            Button {
                coordinator.fitToWidth()
            } label: {
                fitWidthIcon
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("가로 맞춤")

            // Fit to Height (세로맞춤)
            Button {
                coordinator.fitToHeight()
            } label: {
                fitHeightIcon
                    .frame(width: 24, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("세로 맞춤")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            Color(red: 0.17, green: 0.17, blue: 0.18).opacity(0.95),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
        )
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.white.opacity(0.25))
            .frame(width: 1, height: 13)
    }

    /// 이미지와 동일한 가로맞춤 아이콘 (둥근 직사각형 안에 좌우 화살표)
    private var fitWidthIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(Color.white.opacity(0.85), lineWidth: 1.3)
                .frame(width: 17, height: 12)

            HStack(spacing: 3) {
                Image(systemName: "arrowtriangle.backward.fill")
                    .font(.system(size: 4))
                Image(systemName: "arrowtriangle.forward.fill")
                    .font(.system(size: 4))
            }
            .foregroundStyle(.white.opacity(0.9))
        }
    }

    /// 세로맞춤 아이콘 (둥근 직사각형 안에 상하 화살표)
    private var fitHeightIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(Color.white.opacity(0.85), lineWidth: 1.3)
                .frame(width: 12, height: 17)

            VStack(spacing: 3) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 4))
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 4))
            }
            .foregroundStyle(.white.opacity(0.9))
        }
    }
}

// MARK: - PDF Thumbnail Cache

@MainActor
final class PDFThumbnailCache {
    static let shared = PDFThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 300
    }

    func thumbnail(for doc: PDFDocument, index: Int) -> NSImage? {
        let key = "\(doc.hash)_p\(index)" as NSString
        return cache.object(forKey: key)
    }

    func setThumbnail(_ image: NSImage, for doc: PDFDocument, index: Int) {
        let key = "\(doc.hash)_p\(index)" as NSString
        cache.setObject(image, forKey: key)
    }
}

// MARK: - PDF Thumbnail Sidebar View

struct PDFThumbnailSidebarView: View {
    @ObservedObject var coordinator: PDFPreviewCoordinator
    var onToggleSidebar: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Top Header: ≡ + current page number
            HStack(spacing: 14) {
                Button {
                    onToggleSidebar?()
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle thumbnails")

                Text("\(coordinator.currentPageIndex + 1)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color(red: 0.18, green: 0.18, blue: 0.19))

            // Thumbnails List
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 20) {
                        if let doc = coordinator.document {
                            ForEach(0..<coordinator.pageCount, id: \.self) { index in
                                PDFThumbnailItemView(
                                    document: doc,
                                    pageIndex: index,
                                    isSelected: index == coordinator.currentPageIndex,
                                    onSelect: {
                                        coordinator.goToPage(index)
                                    }
                                )
                                .id(index)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 12)
                }
                .background(Color(red: 0.14, green: 0.14, blue: 0.15))
                .onChange(of: coordinator.currentPageIndex) { newIndex in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PDF Thumbnail Item View

struct PDFThumbnailItemView: View {
    let document: PDFDocument
    let pageIndex: Int
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                // Page thumbnail container
                ZStack {
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .background(Color.white)
                    } else {
                        Rectangle()
                            .fill(Color.white)
                            .aspectRatio(1 / 1.414, contentMode: .fit)
                    }
                }
                .frame(width: 82)
                .padding(isSelected ? 6 : 0)
                .background(
                    isSelected
                        ? Color(red: 0.44, green: 0.65, blue: 0.98)
                        : Color.clear
                )

                // Page Number
                Text("\(pageIndex + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .task(id: pageIndex) {
            loadThumbnail()
        }
    }

    private func loadThumbnail() {
        if let cached = PDFThumbnailCache.shared.thumbnail(for: document, index: pageIndex) {
            self.thumbnail = cached
            return
        }
        guard let page = document.page(at: pageIndex) else { return }
        let targetSize = CGSize(width: 164, height: 232)
        Task.detached(priority: .userInitiated) {
            let img = page.thumbnail(of: targetSize, for: .mediaBox)
            await MainActor.run {
                PDFThumbnailCache.shared.setThumbnail(img, for: document, index: pageIndex)
                self.thumbnail = img
            }
        }
    }
}
