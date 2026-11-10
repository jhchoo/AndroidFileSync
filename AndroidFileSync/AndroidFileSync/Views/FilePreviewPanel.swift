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
import QuickLookUI
import WebKit
internal import Combine

// MARK: - Preview Panel

struct FilePreviewPanel: View {
    @ObservedObject var previewManager: FilePreviewManager
    @StateObject private var pdfCoordinator = PDFPreviewCoordinator()
    @StateObject private var quickLookCoordinator = QuickLookPreviewCoordinator()
    
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
            } else if isQuickLookPreview {
                quickLookCoordinator.startKeyMonitoring()
            }
        }
        .onDisappear {
            pdfCoordinator.saveCurrentLocation()
            pdfCoordinator.stopKeyMonitoring()
            quickLookCoordinator.stopKeyMonitoring()
        }
        .onChange(of: previewManager.previewContent) { newContent in
            if case .pdfReady = newContent {
                pdfCoordinator.startKeyMonitoring()
                quickLookCoordinator.stopKeyMonitoring()
            } else if case .quickLookReady = newContent {
                quickLookCoordinator.resetZoom()
                quickLookCoordinator.startKeyMonitoring()
                pdfCoordinator.stopKeyMonitoring()
            } else {
                pdfCoordinator.stopKeyMonitoring()
                quickLookCoordinator.stopKeyMonitoring()
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
    
    private var isPDFPreview: Bool {
        if case .pdfReady = previewManager.previewContent { return true }
        return false
    }

    private var isQuickLookPreview: Bool {
        if case .quickLookReady = previewManager.previewContent { return true }
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
                .frame(maxWidth: (isPDFPreview || isQuickLookPreview) ? 180 : 380, alignment: .leading)
            
            // PDF 확대/축소 및 가로/세로 맞춤 컨트롤 바 (네비게이션바 좌측 영역)
            if isPDFPreview {
                PDFZoomControlBar(coordinator: pdfCoordinator)
            } else if isQuickLookPreview {
                QuickLookZoomControlBar(coordinator: quickLookCoordinator)
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
        let ext = previewManager.previewFile?.pathExtension ?? ""
        Image(systemName: iconName(for: ext))
            .font(.system(size: 14))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor(for: ext))
    }

    private func iconName(for ext: String) -> String {
        switch ext.lowercased() {
        case "doc", "docx", "dot", "dotx":
            return "doc.richtext"
        case "xls", "xlsx", "xlsm", "xlsb", "csv", "tsv":
            return "tablecells"
        case "ppt", "pptx", "pps", "ppsx", "pot", "potx":
            return "rectangle.on.rectangle"
        case "pdf":
            return "doc.richtext"
        default:
            let category = PreviewFileCategory(extension: ext)
            return category.symbolName
        }
    }

    private func iconColor(for ext: String) -> Color {
        switch ext.lowercased() {
        case "doc", "docx", "dot", "dotx":
            return .blue
        case "xls", "xlsx", "xlsm", "xlsb", "csv", "tsv":
            return .green
        case "ppt", "pptx", "pps", "ppsx", "pot", "potx":
            return .orange
        case "pdf":
            return .red
        default:
            let category = PreviewFileCategory(extension: ext)
            return iconColor(for: category)
        }
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
        case .quickLookReady(let url):
            quickLookPreview(url: url)
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
            
            Text(previewManager.fullFilePullProgress.isEmpty ? "Loading preview…" : previewManager.fullFilePullProgress)
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

            PDFKitRepresentable(
                url: url,
                documentKey: previewManager.previewFile?.path ?? url.path,
                coordinator: pdfCoordinator
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.18))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
        .accessibilityLabel("PDF Document Preview")
    }
    
    // MARK: - QuickLook Preview

    private func quickLookPreview(url: URL) -> some View {
        QuickLookRepresentable(url: url, coordinator: quickLookCoordinator)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .transition(.opacity)
            .accessibilityLabel("Document Preview")
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
    
    // MARK: - Document Preview (Fallback)
    
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
            VStack(spacing: 6) {
                Text(file.name)
                    .font(.system(size: 15, weight: .semibold))
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
        case "doc", "docx", "dot", "dotx":       return "doc.richtext"
        case "xls", "xlsx", "xlsm", "xlsb",
             "csv", "tsv":                       return "tablecells"
        case "ppt", "pptx", "pps", "ppsx",
             "pot", "potx":                      return "rectangle.on.rectangle"
        case "pages":                            return "doc.richtext"
        case "numbers":                          return "tablecells"
        case "key", "keynote":                   return "rectangle.on.rectangle"
        case "txt", "md", "markdown", "rtf", "rtfd": return "doc.text"
        case "html", "htm":                      return "globe"
        case "json", "xml", "yaml", "yml", "plist": return "curlybraces"
        case "swift", "java", "py", "js", "ts",
             "c", "cpp", "h", "hpp", "css",
             "sh", "bash", "zsh":                return "chevron.left.forwardslash.chevron.right"
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
        pdfCoordinator.saveCurrentLocation()
        pdfCoordinator.stopKeyMonitoring()
        quickLookCoordinator.stopKeyMonitoring()
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
    @Published var scrollStep: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(scrollStep), forKey: "afs_pdf_scroll_step")
        }
    }
    @Published var document: PDFDocument?
    var documentKey: String?
    private weak var currentPDFView: PDFView?
    private var keyMonitor: Any?

    init() {
        let savedStep = UserDefaults.standard.double(forKey: "afs_pdf_scroll_step")
        self.scrollStep = savedStep > 0 ? CGFloat(savedStep) : 80
    }

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
        guard let doc = currentPDFView?.document else {
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

        // Cmd shortcuts
        if flags.contains(.command) && flags.intersection([.option, .control]).isEmpty {
            switch event.keyCode {
            case 24, 69: // Cmd + Plus / Equal / Keypad Plus
                zoomIn()
                return nil
            case 27, 78: // Cmd + Minus / Keypad Minus
                zoomOut()
                return nil
            case 29: // Cmd + 0 (Reset zoom)
                resetZoom()
                return nil
            case 126: // Cmd + Up
                scrollToTop()
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
        // 방향키 상/하: 일반 컨텐츠 부드러운 스크롤 이동
        case 125: // Down Arrow
            scrollContent(deltaY: -scrollStep)
            return nil
        case 126: // Up Arrow
            scrollContent(deltaY: scrollStep)
            return nil

        // Page Up / Down 및 좌우 방향키: 페이지 단위 이동
        case 121, 124: // Page Down (121), Right Arrow (124)
            goToNextPage()
            return nil
        case 116, 123: // Page Up (116), Left Arrow (123)
            goToPreviousPage()
            return nil
        default:
            return event
        }
    }

    /// PDF 내부 NSScrollView를 찾아 지정된 deltaY(pt)만큼 스크롤
    func scrollContent(deltaY: CGFloat) {
        guard let pdfView = currentPDFView else { return }
        guard let scrollView = findScrollView(in: pdfView) else { return }
        let clipView = scrollView.contentView
        let currentOrigin = clipView.bounds.origin

        var newOrigin = currentOrigin
        // macOS isFlipped 좌표계: 위로 스크롤(deltaY > 0) -> y 감소, 아래로 스크롤(deltaY < 0) -> y 증가
        if clipView.isFlipped {
            newOrigin.y -= deltaY
        } else {
            newOrigin.y += deltaY
        }

        let docView = clipView.documentView
        let maxY = (docView?.bounds.height ?? clipView.bounds.height) - clipView.bounds.height
        newOrigin.y = max(0, min(max(maxY, 0), newOrigin.y))

        clipView.scroll(to: newOrigin)
        scrollView.reflectScrolledClipView(clipView)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.updateCurrentPageFromViewport()
            self.saveCurrentLocation()
        }
    }

    /// 문서 맨 위로 즉시 이동
    func scrollToTop() {
        goToPage(0)
        guard let pdfView = currentPDFView else { return }
        if let scrollView = findScrollView(in: pdfView) {
            let clipView = scrollView.contentView
            var origin = clipView.bounds.origin
            origin.y = 0
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }
        saveCurrentLocation()
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView {
            return sv
        }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) {
                return found
            }
        }
        return nil
    }

    func attach(pdfView: PDFView, documentKey: String?) {
        self.currentPDFView = pdfView
        self.document = pdfView.document
        self.documentKey = documentKey
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

        // 스크롤 변경(좌우 / 상하 이동) 감지 등록
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        if let clipView = findScrollView(in: pdfView)?.contentView {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleBoundsChanged(_:)),
                name: NSView.boundsDidChangeNotification,
                object: clipView
            )
        }

        startKeyMonitoring()
        restoreSavedLocationIfAvailable()
    }

    @objc private func handleBoundsChanged(_ note: Notification) {
        updateCurrentPageFromViewport()
        saveCurrentLocation()
    }

    /// 현재 뷰포트에 가장 많이 보이거나 중심에 위치한 페이지를 감지하여 currentPageIndex 동기화
    func updateCurrentPageFromViewport() {
        guard let pdfView = currentPDFView,
              let doc = pdfView.document,
              doc.pageCount > 0 else { return }

        // 1. PDFView의 visiblePages 중 뷰포트 내 가장 넓은 면적을 차지하는 페이지 계산
        let visiblePages = pdfView.visiblePages
        if !visiblePages.isEmpty {
            let viewBounds = pdfView.bounds
            var bestPage: PDFPage? = nil
            var maxVisibleArea: CGFloat = 0

            for page in visiblePages {
                let rectInView = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
                let intersection = rectInView.intersection(viewBounds)
                if !intersection.isNull && !intersection.isEmpty {
                    let area = intersection.width * intersection.height
                    if area > maxVisibleArea {
                        maxVisibleArea = area
                        bestPage = page
                    }
                }
            }

            if let chosen = bestPage {
                let idx = doc.index(for: chosen)
                if idx >= 0 && idx < doc.pageCount && self.currentPageIndex != idx {
                    self.currentPageIndex = idx
                }
                return
            }
        }

        // 2. Fallback: 뷰포트 중앙(center)에 위치한 페이지 찾기
        let centerPoint = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        if let centerPage = pdfView.page(for: centerPoint, nearest: true) {
            let idx = doc.index(for: centerPage)
            if idx >= 0 && idx < doc.pageCount && self.currentPageIndex != idx {
                self.currentPageIndex = idx
                return
            }
        }

        // 3. Fallback: pdfView.currentPage
        if let current = pdfView.currentPage {
            let idx = doc.index(for: current)
            if idx >= 0 && idx < doc.pageCount && self.currentPageIndex != idx {
                self.currentPageIndex = idx
            }
        }
    }

    /// 이전에 저장된 위치(페이지, 상하/좌우 스크롤, 배율) 복원
    func restoreSavedLocationIfAvailable() {
        guard let key = documentKey,
              let location = PDFDocumentLocationCache.shared.location(for: key),
              let pdfView = currentPDFView,
              let doc = pdfView.document,
              doc.pageCount > 0 else { return }

        let targetIndex = min(max(0, location.pageIndex), doc.pageCount - 1)
        if let page = doc.page(at: targetIndex) {
            pdfView.go(to: page)
            self.currentPageIndex = targetIndex
        }

        if let savedScale = location.scaleFactor, savedScale > 0.1 {
            pdfView.autoScales = false
            pdfView.scaleFactor = CGFloat(savedScale)
            self.scaleFactor = CGFloat(savedScale)
        }

        if let scrollView = findScrollView(in: pdfView) {
            DispatchQueue.main.async {
                let clipView = scrollView.contentView
                var origin = clipView.bounds.origin
                if let savedOffsetX = location.scrollOffsetX {
                    origin.x = CGFloat(savedOffsetX)
                }
                if let savedOffsetY = location.scrollOffsetY {
                    origin.y = CGFloat(savedOffsetY)
                }
                clipView.scroll(to: origin)
                scrollView.reflectScrolledClipView(clipView)
            }
        }
    }

    /// 현재 위치를 7일 유효 캐시에 저장 (상하 및 좌우 스크롤 포함)
    func saveCurrentLocation() {
        guard let key = documentKey,
              let pdfView = currentPDFView else { return }

        var currentScrollX: Double? = nil
        var currentScrollY: Double? = nil
        if let scrollView = findScrollView(in: pdfView) {
            let bounds = scrollView.contentView.bounds
            currentScrollX = Double(bounds.origin.x)
            currentScrollY = Double(bounds.origin.y)
        }

        PDFDocumentLocationCache.shared.saveLocation(
            for: key,
            pageIndex: currentPageIndex,
            scrollOffsetX: currentScrollX,
            scrollOffsetY: currentScrollY,
            scaleFactor: Double(scaleFactor)
        )
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
            saveCurrentLocation()
        }
        if self.pageCount != doc.pageCount {
            self.pageCount = max(doc.pageCount, 1)
        }
    }

    @objc private func handleScaleChanged(_ note: Notification) {
        guard let pdfView = currentPDFView else { return }
        if abs(self.scaleFactor - pdfView.scaleFactor) > 0.001 {
            self.scaleFactor = pdfView.scaleFactor
            saveCurrentLocation()
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
        saveCurrentLocation()
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
            pdfView.layoutDocumentView()
            centerHorizontalScrollIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.centerHorizontalScrollIfNeeded()
            }
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
            pdfView.layoutDocumentView()
            centerHorizontalScrollIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.centerHorizontalScrollIfNeeded()
            }
        }
    }

    /// 가로맞춤 / 세로맞춤 시 하단에 가로스크롤바가 존재하면 중앙으로 이동
    func centerHorizontalScrollIfNeeded() {
        guard let pdfView = currentPDFView else { return }
        guard let scrollView = findScrollView(in: pdfView) else { return }
        let clipView = scrollView.contentView
        guard let docView = clipView.documentView else { return }

        let docWidth = max(docView.bounds.width, docView.frame.width)
        let clipWidth = clipView.bounds.width
        let maxScrollX = docWidth - clipWidth

        // 하단 가로스크롤바가 존재하는 경우(문서 너비가 뷰포트 너비보다 큰 경우) 중앙으로 스크롤 이동
        if maxScrollX > 1.0 {
            var origin = clipView.bounds.origin
            let minX = docView.bounds.origin.x
            origin.x = minX + (maxScrollX / 2.0)
            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
            saveCurrentLocation()
        }
    }
}

// MARK: - Native PDFKit View

struct PDFKitRepresentable: NSViewRepresentable {
    let url: URL
    let documentKey: String
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
        coordinator.attach(pdfView: pdfView, documentKey: documentKey)

        DispatchQueue.main.async {
            pdfView.layoutDocumentView()
            if PDFDocumentLocationCache.shared.location(for: documentKey) == nil {
                pdfView.autoScales = true
            }
            coordinator.updatePages()
        }

        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        if pdfView.document?.documentURL != url {
            loadDocument(into: pdfView)
            coordinator.attach(pdfView: pdfView, documentKey: documentKey)
            DispatchQueue.main.async {
                pdfView.layoutDocumentView()
                if PDFDocumentLocationCache.shared.location(for: documentKey) == nil {
                    pdfView.autoScales = true
                }
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

// MARK: - Native QuickLook View

final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String? = nil) {
        self.previewItemURL = url
        self.previewItemTitle = title ?? url.lastPathComponent
        super.init()
    }
}

struct QuickLookRepresentable: NSViewRepresentable {
    let url: URL
    let coordinator: QuickLookPreviewCoordinator

    func makeNSView(context: Context) -> QLPreviewView {
        let previewView: QLPreviewView
        if let view = QLPreviewView(frame: .zero, style: .normal) {
            previewView = view
        } else {
            previewView = QLPreviewView(frame: .zero) ?? QLPreviewView()
        }
        previewView.autoresizingMask = [.width, .height]
        previewView.autostarts = true
        previewView.previewItem = QuickLookPreviewItem(url: url)
        coordinator.attach(previewView: previewView)
        return previewView
    }

    func updateNSView(_ previewView: QLPreviewView, context: Context) {
        coordinator.attach(previewView: previewView)
        if let currentItem = previewView.previewItem as? QuickLookPreviewItem, currentItem.previewItemURL == url {
            return
        }
        previewView.previewItem = QuickLookPreviewItem(url: url)
        previewView.refreshPreviewItem()
        coordinator.applyZoom()
    }

    static func dismantleNSView(_ previewView: QLPreviewView, coordinator: ()) {
        previewView.close()
    }
}

// MARK: - QuickLook Coordinator

@MainActor
final class QuickLookPreviewCoordinator: ObservableObject {
    @Published var scaleFactor: CGFloat = 1.0
    private weak var currentPreviewView: QLPreviewView?
    private var keyMonitor: Any?

    deinit {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func attach(previewView: QLPreviewView) {
        self.currentPreviewView = previewView
        applyZoom()
        startKeyMonitoring()
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
        guard let window = NSApp.keyWindow, window.isKeyWindow else {
            return event
        }
        if let responder = window.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return event
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Cmd shortcuts
        if flags.contains(.command) && flags.intersection([.option, .control]).isEmpty {
            switch event.keyCode {
            case 24, 69: // Cmd + Plus / Equal / Keypad Plus
                zoomIn()
                return nil
            case 27, 78: // Cmd + Minus / Keypad Minus
                zoomOut()
                return nil
            case 29: // Cmd + 0 (Reset to 100%)
                resetZoom()
                return nil
            default:
                return event
            }
        }

        return event
    }

    func zoomIn() {
        scaleFactor = min(round((scaleFactor + 0.2) * 10) / 10, 3.0)
        applyZoom()
    }

    func zoomOut() {
        scaleFactor = max(round((scaleFactor - 0.2) * 10) / 10, 0.4)
        applyZoom()
    }

    func resetZoom() {
        scaleFactor = 1.0
        applyZoom()
    }

    func applyZoom() {
        guard let root = currentPreviewView else { return }
        let scale = self.scaleFactor

        if !applyZoomToSubviews(root: root, scale: scale) {
            // QuickLook loads subviews asynchronously; retry shortly if not yet loaded
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self = self, let current = self.currentPreviewView, current === root else { return }
                if !self.applyZoomToSubviews(root: current, scale: self.scaleFactor) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self = self, let current = self.currentPreviewView, current === root else { return }
                        _ = self.applyZoomToSubviews(root: current, scale: self.scaleFactor)
                    }
                }
            }
        }
    }

    @discardableResult
    private func applyZoomToSubviews(root: NSView, scale: CGFloat) -> Bool {
        // 1. WebKit-based QuickLook (Word doc/docx, Excel xls/xlsx/csv, RTF, HTML, etc.)
        if let webView = findWKWebView(in: root) {
            webView.allowsMagnification = true
            webView.pageZoom = scale
            return true
        }

        // 2. ScrollView-based QuickLook (Text files, source code, etc.)
        if let scrollView = findScrollView(in: root) {
            scrollView.allowsMagnification = true
            let center = NSPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)
            scrollView.animator().setMagnification(scale, centeredAt: center)
            return true
        }

        // 3. Layer-based QuickLook (PowerPoint ppt/pptx slides, Keynote, etc.)
        if let container = findContentContainer(in: root), let child = container.subviews.first {
            child.wantsLayer = true
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.18)
            child.layer?.sublayerTransform = CATransform3DMakeScale(scale, scale, 1.0)
            CATransaction.commit()
            return true
        }

        return false
    }

    private func findWKWebView(in view: NSView) -> WKWebView? {
        if let wv = view as? WKWebView { return wv }
        for sub in view.subviews {
            if let found = findWKWebView(in: sub) { return found }
        }
        return nil
    }

    private func findScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = findScrollView(in: sub) { return found }
        }
        return nil
    }

    private func findContentContainer(in view: NSView) -> NSView? {
        let className = NSStringFromClass(type(of: view))
        if className.contains("QLDisplayBundleContainerView") {
            return view
        }
        for sub in view.subviews {
            if let found = findContentContainer(in: sub) { return found }
        }
        return nil
    }
}

// MARK: - QuickLook Zoom Control Bar

struct QuickLookZoomControlBar: View {
    @ObservedObject var coordinator: QuickLookPreviewCoordinator

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
            .help("축소 (⌘ -)")

            // Percentage Display
            Text("\(Int(round(coordinator.scaleFactor * 100)))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 40)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                .help("100%로 재설정 (⌘ 0)")
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
            .help("확대 (⌘ +)")

            dividerLine

            // 100% Reset / Actual Size
            Button {
                coordinator.resetZoom()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("실제 크기 100% (⌘ 0)")
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
            .help("축소 (Zoom Out / ⌘ -)")

            // Percentage Display
            Text("\(Int(round(coordinator.scaleFactor * 100)))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 40)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                .help("100%로 재설정 (⌘ 0)")
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
            .help("확대 (Zoom In / ⌘ +)")

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

            dividerLine

            // Scroll to Top (문서 맨 위로 이동)
            Button {
                coordinator.scrollToTop()
            } label: {
                Image(systemName: "arrow.up.to.line")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("문서 맨 위로 이동 (⌘ + ↑)")

            // Scroll Step Selector (방향키 스크롤 이동량 조절)
            Menu {
                Button("미세 이동 (40 pt)") { coordinator.scrollStep = 40 }
                Button("기본 이동 (80 pt)") { coordinator.scrollStep = 80 }
                Button("빠른 이동 (140 pt)") { coordinator.scrollStep = 140 }
                Button("반 페이지 (250 pt)") { coordinator.scrollStep = 250 }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up.and.down")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(Int(coordinator.scrollStep))px")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 4)
                .frame(height: 20)
                .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("방향키 스크롤 이동 거리 설정 (선택 저장됨)")
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
                    VStack(spacing: 20) {
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
