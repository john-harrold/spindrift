import SwiftUI
import PDFKit

extension View {
    @ViewBuilder
    func activeButtonStyle(_ isActive: Bool) -> some View {
        if isActive {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct ContentView: View {
    @ObservedObject var document: SpindriftDocument
    @State private var viewModel = DocumentViewModel()
    @State private var sidebarMode: SidebarMode = .thumbnails
    @State private var showLeftSidebar = true
    @State private var showRightSidebar = true
    @State private var sidebarWidth: CGFloat = 180
    @State private var zoomText = "100%"
    @State private var hasSizedWindow = false
    @FocusState private var isSearchFieldFocused: Bool
    @Environment(\.undoManager) private var undoManager

    enum SidebarMode: String, CaseIterable {
        case thumbnails = "Thumbnails"
        case outline = "TOC"
    }

    var body: some View {
        bodyCore
            .modifier(SheetModifiers(viewModel: viewModel,
                                      deletePageDialogTitle: deletePageDialogTitle,
                                      exportTableAsCSV: exportTableAsCSV,
                                      exportTablesAsExcel: exportTablesAsExcel))
    }

    private var bodyCore: some View {
        mainLayout
            .inspector(isPresented: $showRightSidebar) {
                inspectorContent
                    .inspectorColumnWidth(min: 220, ideal: 260, max: 300)
            }
            .toolbar(id: "main") {
                ToolbarItem(id: "toggle-sidebar", placement: .automatic) {
                    Button {
                        withAnimation { showLeftSidebar.toggle() }
                    } label: {
                        Label("Sidebar", systemImage: "sidebar.left")
                    }
                    .help("Toggle left sidebar")
                }
                MainToolbar(viewModel: viewModel)
                ToolbarItem(id: "toggle-inspector", placement: .automatic) {
                    Button {
                        showRightSidebar.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.right")
                    }
                    .help("Toggle inspector sidebar")
                }
            }
            .navigationTitle(navigationTitle)
            .background(WindowAccessor { window in
                sizeWindowToDocumentIfNeeded(window: window)
            })
            .onAppear {
                viewModel.document = document
                viewModel.sidecar = document.sidecar
                viewModel.undoManager = undoManager
            }
            .onChange(of: undoManager) { _, newValue in
                viewModel.undoManager = newValue
            }
            .background {
                Button("") {
                    viewModel.toolMode = .browse
                    isSearchFieldFocused = true
                }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()

            }
            .onReceive(NotificationCenter.default.publisher(for: .saveOrSaveAs)) { _ in
                if isTemporaryFile {
                    saveAs()
                } else {
                    // Trigger the standard document save
                    NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportAsPDF)) { _ in exportAsPDF() }
            .onReceive(NotificationCenter.default.publisher(for: .ocrCurrentPage)) { _ in viewModel.startOCRCurrentPage() }
            .onReceive(NotificationCenter.default.publisher(for: .ocrAllPages)) { _ in viewModel.startOCRAllPages() }
            .onReceive(NotificationCenter.default.publisher(for: .combineFiles)) { _ in viewModel.showCombineSheet = true }
            .onReceive(NotificationCenter.default.publisher(for: .exportAsWord)) { _ in exportAsWord() }
            .onReceive(NotificationCenter.default.publisher(for: .exportAsText)) { _ in exportAsText() }
            .onReceive(NotificationCenter.default.publisher(for: .saveAs)) { _ in saveAs() }
            .onReceive(NotificationCenter.default.publisher(for: .printDocument)) { _ in printDocument() }
            .onReceive(NotificationCenter.default.publisher(for: .tableSelect)) { _ in
                viewModel.showTableToolbar = true
                viewModel.showOCRToolbar = false
                viewModel.toolMode = .tableSelect
            }
    }

    // MARK: - Temp File Detection

    private var isTemporaryFile: Bool {
        guard let url = document.pdfDocument.documentURL else { return true }
        return url.path.hasPrefix(FileManager.default.temporaryDirectory.path)
            || url.path.hasPrefix("/tmp/")
            || url.path.hasPrefix("/private/tmp/")
    }

    // MARK: - Navigation Title

    private var navigationTitle: String {
        if document.pdfDocument.pageCount == 0 {
            return "Spindrift"
        }
        return "Page \(viewModel.currentPageIndex + 1) of \(document.pdfDocument.pageCount)"
    }

    // MARK: - Tool Mode Hint

    @ViewBuilder
    private var toolModeHint: some View {
        if let hint = toolHintText {
            Text(hint)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .padding(12)
        }
    }

    private var toolHintText: String? {
        nil
    }

    // MARK: - Window Sizing

    private func sizeWindowToDocumentIfNeeded(window: NSWindow) {
        guard !hasSizedWindow,
              let firstPage = document.pdfDocument.page(at: 0),
              let screen = window.screen ?? NSScreen.main else { return }

        let pageBounds = firstPage.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return }

        hasSizedWindow = true

        let pageAspect = pageBounds.width / pageBounds.height
        let isPortrait = pageAspect < 1

        let visibleFrame = screen.visibleFrame
        let maxWidth = visibleFrame.width * 0.95
        let maxHeight = visibleFrame.height * 0.95

        // Approximate chrome around the PDF canvas — sidebars, toolbars, title bar.
        let leftChrome: CGFloat = showLeftSidebar ? (sidebarWidth + 6) : 0
        let rightChrome: CGFloat = showRightSidebar ? 260 : 0
        let verticalChrome: CGFloat = 28 + 38 + 36  // title bar + main toolbar + sub-toolbar
        let horizontalChrome = leftChrome + rightChrome

        let targetWidth: CGFloat
        let targetHeight: CGFloat

        if isPortrait {
            // Portrait: take the screen's height, scale width to match document aspect.
            targetHeight = maxHeight
            let pdfAreaHeight = max(100, targetHeight - verticalChrome)
            let pdfAreaWidth = pdfAreaHeight * pageAspect
            targetWidth = min(maxWidth, pdfAreaWidth + horizontalChrome)
        } else {
            // Landscape: take the screen's width, scale height to match document aspect.
            targetWidth = maxWidth
            let pdfAreaWidth = max(100, targetWidth - horizontalChrome)
            let pdfAreaHeight = pdfAreaWidth / pageAspect
            targetHeight = min(maxHeight, pdfAreaHeight + verticalChrome)
        }

        var frame = window.frame
        frame.size = NSSize(width: targetWidth, height: targetHeight)
        frame.origin.x = visibleFrame.minX + (visibleFrame.width - targetWidth) / 2
        frame.origin.y = visibleFrame.minY + (visibleFrame.height - targetHeight) / 2
        window.setFrame(frame, display: true, animate: false)

        // Re-run fit-to-width once the new bounds settle.
        let vm = viewModel
        DispatchQueue.main.async {
            vm.fitToWidthRequest += 1
        }
    }

    // MARK: - Select Mode Toolbar

    // MARK: - Layout

    private var mainLayout: some View {
        HStack(spacing: 0) {
            if showLeftSidebar {
                leftSidebar
            }
            mainContent
        }
    }

    private var leftSidebar: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Picker("", selection: $sidebarMode) {
                    ForEach(SidebarMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(8)

                switch sidebarMode {
                case .thumbnails:
                    ThumbnailSidebar(viewModel: viewModel)
                case .outline:
                    OutlineSidebar(pdfDocument: document.pdfDocument, viewModel: viewModel)
                }
            }
            .frame(width: sidebarWidth)

            Rectangle()
                .fill(Color.gray.opacity(0.01))
                .frame(width: 6)
                .overlay(Divider())
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            sidebarWidth = min(500, max(120, sidebarWidth + value.translation.width))
                        }
                )
        }
    }

    private var activeToolLabel: some View {
        Label(activeToolName, systemImage: activeToolIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.trailing, 8)
    }

    private var activeToolName: String {
        if viewModel.showOCRToolbar { return "OCR" }
        if viewModel.showTableToolbar { return "Table" }
        return viewModel.toolMode.rawValue
    }

    private var activeToolIcon: String {
        if viewModel.showOCRToolbar { return "text.viewfinder" }
        if viewModel.showTableToolbar { return "tablecells" }
        return viewModel.toolMode.systemImage
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            if viewModel.showOCRToolbar {
                ocrToolbar
            } else if viewModel.showTableToolbar {
                tableToolbar
            } else if viewModel.toolMode.isBrowse {
                browseToolbar
            } else if viewModel.toolMode.isStamp {
                stampToolbar
            } else if viewModel.toolMode.isMarkup {
                markupToolbar
            } else if viewModel.toolMode.isDraw {
                drawToolbar
            } else {
                // Tools without sub-toolbars (e.g. Comment) — show active tool indicator
                HStack {
                    activeToolLabel
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
            }
            PDFCanvasView(
                pdfDocument: document.pdfDocument,
                viewModel: viewModel
            )
            .overlay(alignment: .topLeading) {
                toolModeHint
            }
        }
    }

    // MARK: - Browse Toolbar

    private var browseToolbar: some View {
        HStack(spacing: 12) {
            activeToolLabel

            // Select mode (text / box)
            HStack(spacing: 2) {
                ForEach(SelectMode.allCases) { mode in
                    Button {
                        viewModel.selectMode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                    }
                    .activeButtonStyle(viewModel.selectMode == mode)
                }
            }

            if viewModel.hasBoxSelection {
                Divider()
                    .frame(height: 20)

                Button {
                    viewModel.copyBoxSelectionToClipboard()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help("Copy selected region as image (Cmd+C)")

                Button {
                    viewModel.cropCurrentPageToBoxSelection()
                } label: {
                    Label("Crop Page", systemImage: "crop")
                }
                .buttonStyle(.bordered)
                .help("Crop current page to selection")

                Button {
                    viewModel.cropAllPagesToBoxSelection()
                } label: {
                    Label("Crop All", systemImage: "rectangle.stack")
                }
                .buttonStyle(.bordered)
                .help("Crop all pages to selection")

                Button {
                    viewModel.clearBoxSelection()
                } label: {
                    Label("Clear", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                .help("Clear selection (Escape)")
            }

            Divider()
                .frame(height: 20)

            // Zoom controls
            Button {
                viewModel.zoomLevel = max(0.25, viewModel.zoomLevel - 0.25)
                viewModel.zoomSetByUI += 1
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help("Zoom out")

            TextField("", text: $zoomText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 66)
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .onSubmit {
                    applyZoomFromText()
                }
                .onChange(of: viewModel.zoomLevel) { _, newValue in
                    zoomText = "\(Int(newValue * 100))%"
                }

            Button {
                viewModel.zoomLevel = min(5.0, viewModel.zoomLevel + 0.25)
                viewModel.zoomSetByUI += 1
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .help("Zoom in")

            Button {
                viewModel.zoomLevel = 1.0
                viewModel.zoomSetByUI += 1
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.bordered)
            .help("Reset zoom to 100%")

            Button {
                viewModel.fitToPageRequest += 1
            } label: {
                Image(systemName: "rectangle.arrowtriangle.2.inward")
            }
            .buttonStyle(.bordered)
            .help("Fit page to window")

            Divider()
                .frame(height: 20)

            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search text...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        viewModel.performSearch()
                    }
                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        viewModel.searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            if !viewModel.searchResults.isEmpty {
                Text("\(viewModel.currentSearchIndex + 1)/\(viewModel.searchResults.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.previousSearchResult()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.bordered)
                .help("Previous result")

                Button {
                    viewModel.nextSearchResult()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.bordered)
                .help("Next result")
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func applyZoomFromText() {
        let cleaned = zoomText.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        if let value = Double(cleaned), value > 0 {
            viewModel.zoomLevel = min(5.0, max(0.1, value / 100.0))
            viewModel.zoomSetByUI += 1
        }
    }

    // MARK: - Stamp Toolbar

    private var stampToolbar: some View {
        HStack(spacing: 12) {
            activeToolLabel
            StampToolbar(
                stampLibrary: viewModel.stampLibrary,
                selectedStampID: $viewModel.selectedStampLibraryID
            ) { imageData in
                viewModel.pendingStampData = imageData
            }
        }
    }

    // MARK: - Markup Toolbar

    private var markupToolbar: some View {
        HStack(spacing: 12) {
            activeToolLabel
            HStack(spacing: 2) {
                ForEach(ToolMode.markupCases, id: \.id) { mode in
                    Button {
                        viewModel.toolMode = mode
                    } label: {
                        Image(systemName: mode.systemImage)
                            .frame(width: 24, height: 20)
                    }
                    .activeButtonStyle(viewModel.toolMode == mode)
                    .help(mode.markupTooltip)
                }
            }

            if viewModel.toolMode == .highlight {
                Divider()
                    .frame(height: 20)

                HStack(spacing: 6) {
                    ForEach(HighlightColor.all) { color in
                        Button {
                            viewModel.highlightColor = color
                        } label: {
                            Circle()
                                .fill(color.swiftUIColor)
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if viewModel.highlightColor.name == color.name {
                                        Circle()
                                            .strokeBorder(.primary, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(color.name)
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - OCR Toolbar

    private var ocrToolbar: some View {
        HStack(spacing: 12) {
            activeToolLabel
            Button {
                viewModel.startOCRCurrentPage()
            } label: {
                Label("Current Page", systemImage: "doc.text.viewfinder")
            }
            .buttonStyle(.bordered)

            Button {
                viewModel.startOCRAllPages()
            } label: {
                Label("All Pages", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)

            if let status = viewModel.ocrStatusMessage {
                HStack(spacing: 6) {
                    if status.hasPrefix("Running") {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Table Toolbar

    private var tableToolbar: some View {
        HStack(spacing: 12) {
            activeToolLabel
            HStack(spacing: 2) {
                ForEach(DocumentViewModel.TableMode.allCases) { mode in
                    Button {
                        viewModel.tableMode = mode
                    } label: {
                        Label(mode.rawValue, systemImage: mode.systemImage)
                    }
                    .activeButtonStyle(viewModel.tableMode == mode)
                }
            }

            if viewModel.tableMode == .autodetect {
                tableDetectionMethodPicker

                Button {
                    viewModel.startTableAutoDetect()
                } label: {
                    Label("Detect Tables", systemImage: "sparkle.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isDetectingTables)
            }

            Button {
                viewModel.previewTables()
            } label: {
                Label("Preview", systemImage: "eye")
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isDetectingTables || viewModel.extractedTables.isEmpty)

            Button {
                viewModel.clearTableSelection()
            } label: {
                Label("Clear", systemImage: "xmark")
            }
            .buttonStyle(.bordered)

            if viewModel.isDetectingTables {
                ProgressView()
                    .controlSize(.small)
                Text(viewModel.tableMode == .autodetect ? "Detecting tables..." : "Extracting...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var tableDetectionMethodPicker: some View {
        Menu {
            ForEach(DocumentViewModel.TableDetectionMethod.allCases, id: \.self) { method in
                Button {
                    viewModel.tableDetectionMethod = method
                } label: {
                    if method == viewModel.tableDetectionMethod {
                        Label(method.rawValue, systemImage: "checkmark")
                    } else {
                        Text(method.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Method: \(viewModel.tableDetectionMethod.rawValue)")
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var tablePageScopePicker: some View {
        Menu {
            Button("Current Page") {
                viewModel.tablePageScope = .currentPage
                viewModel.annotationRevision += 1
            }
            Button("All Pages") {
                viewModel.tablePageScope = .allPages
                viewModel.annotationRevision += 1
            }
            Button("Pages...") {
                viewModel.tablePageScope = .specific(parsePageNumbers(viewModel.tableSpecificPages))
                viewModel.annotationRevision += 1
            }
        } label: {
            HStack(spacing: 4) {
                Text(tablePageScopeLabel)
                    .font(.caption)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        if case .specific = viewModel.tablePageScope {
            TextField("e.g. 1,3,5", text: $viewModel.tableSpecificPages)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .onChange(of: viewModel.tableSpecificPages) { _, newValue in
                    viewModel.tablePageScope = .specific(parsePageNumbers(newValue))
                    viewModel.annotationRevision += 1
                }
        }
    }

    private var tablePageScopeLabel: String {
        switch viewModel.tablePageScope {
        case .currentPage: return "Current Page"
        case .allPages: return "All Pages"
        case .specific(let pages): return "Pages: \(pages.map { String($0 + 1) }.joined(separator: ","))"
        }
    }

    /// Parse user-entered page numbers (1-indexed) to 0-indexed array.
    private func parsePageNumbers(_ text: String) -> [Int] {
        text.split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map { $0 - 1 }
            .filter { $0 >= 0 }
    }

    // MARK: - Draw Toolbar

    private var drawToolbar: some View {
        HStack(spacing: 12) {
            activeToolLabel
            HStack(spacing: 2) {
                ForEach(ShapeType.allCases) { type in
                    Button {
                        viewModel.drawShapeType = type
                    } label: {
                        Label(type.rawValue, systemImage: type.systemImage)
                    }
                    .activeButtonStyle(viewModel.drawShapeType == type)
                    .help(type.tooltip)
                }
            }

            Divider()
                .frame(height: 20)

            HStack(spacing: 4) {
                Text("Width")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", value: drawStrokeWidthDoubleBinding, format: .number)
                    .frame(width: 40)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $viewModel.drawStrokeWidth, in: 1...20, step: 1)
                    .labelsHidden()
            }

            Picker("Line", selection: $viewModel.drawStrokeStyle) {
                ForEach(OutlineStyle.allCases) { style in
                    Text(style.rawValue).tag(style)
                }
            }
            .frame(maxWidth: 100)

            ColorPicker("Line", selection: drawStrokeColorBinding)
                .disabled(viewModel.drawStrokeStyle == .none)
                .opacity(viewModel.drawStrokeStyle == .none ? 0.3 : 1)

            if viewModel.drawShapeType == .rectangle || viewModel.drawShapeType == .ellipse {
                Divider()
                    .frame(height: 20)

                Picker("Fill", selection: $viewModel.drawHasFill) {
                    Text("No").tag(false)
                    Text("Yes").tag(true)
                }
                .frame(maxWidth: 80)

                ColorPicker("Fill", selection: drawFillColorBinding)
                    .disabled(!viewModel.drawHasFill)
                    .opacity(viewModel.drawHasFill ? 1 : 0.3)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var drawStrokeWidthDoubleBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.drawStrokeWidth) },
            set: { viewModel.drawStrokeWidth = CGFloat($0) }
        )
    }

    private var drawStrokeColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: viewModel.drawStrokeColor) },
            set: { viewModel.drawStrokeColor = $0.hexString }
        )
    }

    private var drawFillColorBinding: Binding<Color> {
        Binding(
            get: { Color(hex: viewModel.drawFillColor) },
            set: { viewModel.drawFillColor = $0.hexString }
        )
    }

    // MARK: - Inspector

    private var isCommentModeActive: Bool {
        viewModel.toolMode == .comment
    }

    private var isTextBoxModeActive: Bool {
        viewModel.toolMode == .textBox
    }

    private var selectedIsComment: Bool {
        if let id = viewModel.selectedAnnotationID {
            return viewModel.sidecar.comments.contains { $0.id == id }
        }
        return false
    }

    private var selectedIsTextBox: Bool {
        if let id = viewModel.selectedAnnotationID {
            return viewModel.sidecar.textBoxes.contains { $0.id == id }
        }
        return false
    }

    private var isDrawModeActive: Bool {
        viewModel.toolMode == .draw
    }

    private var selectedIsShape: Bool {
        if let id = viewModel.selectedAnnotationID {
            return viewModel.sidecar.shapes.contains { $0.id == id }
        }
        return false
    }

    // showRightSidebar is a @State var toggled by the toolbar button

    @ViewBuilder
    private var inspectorContent: some View {
        if viewModel.toolMode.isBrowse && !viewModel.searchResults.isEmpty {
            searchResultsPanel
        } else if isCommentModeActive || selectedIsComment {
            CommentsPanel(
                viewModel: viewModel,
                selectedCommentID: selectedIsComment ? viewModel.selectedAnnotationID : nil
            )
        } else if isTextBoxModeActive || selectedIsTextBox {
            TextBoxesPanel(
                viewModel: viewModel,
                selectedTextBoxID: selectedIsTextBox ? viewModel.selectedAnnotationID : nil
            )
        } else if selectedIsShape {
            ShapeInspector(viewModel: viewModel, shapeID: viewModel.selectedAnnotationID!)
        } else if isDrawModeActive {
            Text("Click and drag to draw a shape")
                .foregroundStyle(.secondary)
        } else if let id = viewModel.selectedAnnotationID {
            if viewModel.sidecar.stamps.contains(where: { $0.id == id }) {
                StampInspector(viewModel: viewModel, stampID: id)
            } else {
                Text("Select an annotation")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Select an annotation")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Search Results Panel

    private var searchResultsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Results")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 8)

            Text("\(viewModel.searchResults.count) matches for \"\(viewModel.searchText)\"")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            List(Array(viewModel.searchResults.enumerated()), id: \.offset) { index, selection in
                Button {
                    viewModel.navigateToSearchResult(index)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        if let page = selection.pages.first,
                           let pdf = viewModel.pdfDocument {
                            Text("Page \(pdf.index(for: page) + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(searchContextString(for: selection))
                            .font(.callout)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)
                .listRowBackground(
                    index == viewModel.currentSearchIndex
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear
                )
            }
            .listStyle(.plain)
        }
    }

    private func searchContextString(for selection: PDFSelection) -> String {
        // Get surrounding text for context
        guard let page = selection.pages.first else { return selection.string ?? "" }
        let fullText = page.string ?? ""
        let searchString = selection.string ?? viewModel.searchText

        guard let range = fullText.range(of: searchString, options: .caseInsensitive) else {
            return searchString
        }

        // Show some context around the match
        let contextStart = fullText.index(range.lowerBound, offsetBy: -30, limitedBy: fullText.startIndex) ?? fullText.startIndex
        let contextEnd = fullText.index(range.upperBound, offsetBy: 30, limitedBy: fullText.endIndex) ?? fullText.endIndex
        var context = String(fullText[contextStart..<contextEnd])
            .replacingOccurrences(of: "\n", with: " ")
        if contextStart != fullText.startIndex { context = "..." + context }
        if contextEnd != fullText.endIndex { context = context + "..." }
        return context
    }

    // MARK: - Delete Page Confirmation

    private var deletePageDialogTitle: String {
        let count = viewModel.pendingDeletePageIndices.count
        if count == 1, let idx = viewModel.pendingDeletePageIndices.first {
            return "Delete page \(idx + 1)?"
        }
        return "Delete \(count) pages?"
    }

    // MARK: - Export

    private func saveAs() {
        guard let pdfData = document.pdfDocument.dataRepresentation() else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]

        // Use the current document's name, or "From Clipboard" for temp files
        let currentName: String
        if let docURL = document.pdfDocument.documentURL {
            currentName = docURL.deletingPathExtension().lastPathComponent
        } else {
            currentName = "Untitled"
        }
        savePanel.nameFieldStringValue = currentName + ".pdf"

        // Default to the last used directory, not the temp directory
        if let docURL = document.pdfDocument.documentURL,
           !isTemporaryFile {
            savePanel.directoryURL = docURL.deletingLastPathComponent()
        } else {
            // Use NSDocumentController's last directory, or Desktop as fallback
            let recentURLs = NSDocumentController.shared.recentDocumentURLs
            if let lastDir = recentURLs.first?.deletingLastPathComponent() {
                savePanel.directoryURL = lastDir
            } else {
                savePanel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            }
        }

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try pdfData.write(to: url)
                NSDocumentController.shared.openDocument(
                    withContentsOf: url,
                    display: true
                ) { _, _, _ in }
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }

    private func printDocument() {
        // Build a flattened PDF with all annotations baked in
        guard let data = DocumentExporter.exportFlattenedPDF(from: document),
              let printPDF = PDFDocument(data: data) else { return }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true

        let printOp = printPDF.printOperation(for: printInfo, scalingMode: .pageScaleToFit, autoRotate: true)
        printOp?.showsPrintPanel = true
        printOp?.showsProgressPanel = true
        printOp?.run()
    }

    private func exportAsPDF() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.pdf]

        let baseName = document.pdfDocument.documentURL?
            .deletingPathExtension().lastPathComponent ?? "Exported"
        savePanel.nameFieldStringValue = baseName + ".pdf"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            if let data = DocumentExporter.exportFlattenedPDF(from: document) {
                try? data.write(to: url)
            }
        }
    }

    private func exportAsText() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]

        let baseName = document.pdfDocument.documentURL?
            .deletingPathExtension().lastPathComponent ?? "Exported"
        savePanel.nameFieldStringValue = baseName + ".txt"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try TextExportService.export(
                    document: document.pdfDocument,
                    to: url
                )
            } catch {
                let alert = NSAlert()
                alert.messageText = "Text Export Error"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    private func exportAsWord() {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "docx")!]

        // Default to PDF base name with .docx extension
        let baseName = document.pdfDocument.documentURL?
            .deletingPathExtension().lastPathComponent ?? "Exported"
        savePanel.nameFieldStringValue = baseName + ".docx"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            viewModel.startWordExport(to: url)
        }
    }

    private func exportTableAsCSV(_ table: TableExtractionService.ExtractedTable) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.commaSeparatedText]
        savePanel.nameFieldStringValue = "Table.csv"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try table.toCSV().write(to: url, atomically: true, encoding: .utf8)
            } catch {
                viewModel.tableExportError = error.localizedDescription
            }
        }
    }

    private func exportTablesAsExcel(_ tables: [TableExtractionService.ExtractedTable]) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.init(filenameExtension: "xlsx")!]
        savePanel.nameFieldStringValue = "Tables.xlsx"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try ExcelExportService.export(tables: tables, to: url)
            } catch {
                viewModel.tableExportError = error.localizedDescription
            }
        }
    }
}

// MARK: - Sheet Modifiers (extracted to help the type checker)

private struct SheetModifiers: ViewModifier {
    @Bindable var viewModel: DocumentViewModel
    let deletePageDialogTitle: String
    let exportTableAsCSV: (TableExtractionService.ExtractedTable) -> Void
    let exportTablesAsExcel: ([TableExtractionService.ExtractedTable]) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showStampPicker) {
                StampPickerSheet { imageData in
                    viewModel.addStamp(imageData: imageData)
                    viewModel.toolMode = .browse
                }
            }
            .sheet(isPresented: $viewModel.showCombineSheet) {
                CombineFilesSheet { combinedPDF in
                    viewModel.applyCombinedDocument(combinedPDF)
                }
            }
            .confirmationDialog(
                deletePageDialogTitle,
                isPresented: $viewModel.showDeletePageConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    viewModel.executePendingPageDeletion()
                }
                Button("Cancel", role: .cancel) {
                    viewModel.pendingDeletePageIndices = []
                }
            }
            .modifier(OCRAndExportSheets(viewModel: viewModel,
                                          exportTableAsCSV: exportTableAsCSV,
                                          exportTablesAsExcel: exportTablesAsExcel))
    }
}

private struct OCRAndExportSheets: ViewModifier {
    @Bindable var viewModel: DocumentViewModel
    let exportTableAsCSV: (TableExtractionService.ExtractedTable) -> Void
    let exportTablesAsExcel: ([TableExtractionService.ExtractedTable]) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.showOCRProgress) {
                OCRProgressSheet(
                    totalPages: viewModel.pageCount,
                    completedPages: $viewModel.ocrCompletedPages,
                    isComplete: $viewModel.ocrIsComplete,
                    onCancel: { viewModel.cancelOCR() }
                )
            }
            .alert(
                "OCR Error",
                isPresented: Binding(
                    get: { viewModel.ocrError != nil },
                    set: { if !$0 { viewModel.ocrError = nil } }
                )
            ) {
                Button("OK") { viewModel.ocrError = nil }
            } message: {
                Text(viewModel.ocrError ?? "")
            }
            .sheet(isPresented: $viewModel.showWordExportProgress) {
                ExportProgressSheet(
                    title: "Exporting as Word",
                    totalPages: viewModel.pageCount,
                    completedPages: $viewModel.wordExportCompletedPages,
                    isComplete: $viewModel.wordExportIsComplete,
                    completionMessage: "Word export complete!",
                    onCancel: { viewModel.cancelWordExport() }
                )
            }
            .alert(
                "Word Export Error",
                isPresented: Binding(
                    get: { viewModel.wordExportError != nil },
                    set: { if !$0 { viewModel.wordExportError = nil } }
                )
            ) {
                Button("OK") { viewModel.wordExportError = nil }
            } message: {
                Text(viewModel.wordExportError ?? "")
            }
            .sheet(isPresented: $viewModel.showTablePreview) {
                TablePreviewSheet(
                    tables: viewModel.extractedTables,
                    initialPageIndex: viewModel.currentPageIndex,
                    pdfDocument: viewModel.pdfDocument,
                    onExportCSV: { table in exportTableAsCSV(table) },
                    onExportAllExcel: { exportTablesAsExcel(viewModel.extractedTables) },
                    onReExtractWithGrid: { index, cols, rows in
                        viewModel.reExtractWithGrid(tableIndex: index, colPositions: cols, rowPositions: rows)
                    }
                )
            }
            .alert(
                "Table Export Error",
                isPresented: Binding(
                    get: { viewModel.tableExportError != nil },
                    set: { if !$0 { viewModel.tableExportError = nil } }
                )
            ) {
                Button("OK") { viewModel.tableExportError = nil }
            } message: {
                Text(viewModel.tableExportError ?? "")
            }
    }
}

// MARK: - Window Accessor

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                onWindow(window)
            }
        }
    }
}
