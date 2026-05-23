import SwiftUI
import PDFKit
import AppKit

enum ToolMode: String, CaseIterable, Identifiable {
    case browse = "Browse"
    case stamp = "Stamp"
    case textBox = "Text Box"
    case comment = "Comment"
    case draw = "Draw"
    case tableSelect = "Table Select"
    case highlight = "Highlight"
    case underline = "Underline"
    case strikethrough = "Strikethrough"
    case removeMarkup = "Remove"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .browse: return "cursorarrow.and.square.on.square.dashed"
        case .stamp: return "signature"
        case .textBox: return "textbox"
        case .comment: return "text.bubble"
        case .draw: return "pencil.and.outline"
        case .tableSelect: return "tablecells"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikethrough: return "strikethrough"
        case .removeMarkup: return "eraser"
        }
    }

    /// Modes shown in the main segmented picker (excludes markup tools)
    static var pickerCases: [ToolMode] {
        [.browse, .stamp, .textBox, .comment, .draw]
    }

    var isBrowse: Bool {
        self == .browse
    }

    /// Markup modes shown in the markup toolbar
    static var markupCases: [ToolMode] {
        [.highlight, .underline, .strikethrough, .removeMarkup]
    }

    var markupTooltip: String {
        switch self {
        case .highlight: return "Highlight selected text"
        case .underline: return "Underline selected text"
        case .strikethrough: return "Strikethrough selected text"
        case .removeMarkup: return "Remove markup annotations"
        case .tableSelect: return "Select table region"
        default: return rawValue
        }
    }

    var isMarkup: Bool {
        switch self {
        case .highlight, .underline, .strikethrough, .removeMarkup: return true
        default: return false
        }
    }

    var isTableSelect: Bool {
        self == .tableSelect
    }

    var isDraw: Bool {
        self == .draw
    }

    var isStamp: Bool {
        self == .stamp
    }
}

enum SelectMode: String, CaseIterable, Identifiable {
    case text = "Text"
    case boxSelect = "Selection"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .text: return "character.cursor.ibeam"
        case .boxSelect: return "rectangle.dashed"
        }
    }
}

struct HighlightColor: Identifiable, Equatable {
    let name: String
    let hex: String
    let swiftUIColor: Color

    var id: String { name }

    static let yellow  = HighlightColor(name: "Yellow",  hex: "#FFFF0080", swiftUIColor: .yellow)
    static let green   = HighlightColor(name: "Green",   hex: "#90EE9080", swiftUIColor: .green)
    static let blue    = HighlightColor(name: "Blue",    hex: "#ADD8E680", swiftUIColor: .blue)
    static let pink    = HighlightColor(name: "Pink",    hex: "#FFB6C180", swiftUIColor: .pink)
    static let purple  = HighlightColor(name: "Purple",  hex: "#DDA0DD80", swiftUIColor: .purple)

    static let all: [HighlightColor] = [.yellow, .green, .blue, .pink, .purple]
}

@MainActor
@Observable
final class DocumentViewModel {
    var toolMode: ToolMode = .browse {
        didSet {
            if !toolMode.isTableSelect && showTableToolbar {
                showTableToolbar = false
                clearTableSelection()
            }
            if toolMode != .browse {
                clearBoxSelection()
            }
        }
    }
    var selectMode: SelectMode = .text {
        didSet {
            if selectMode == .text {
                clearBoxSelection()
            }
        }
    }
    var highlightColor: HighlightColor = .yellow
    var currentPageIndex: Int = 0
    var selectedAnnotationID: UUID?
    var selectedPageIndices: Set<Int> = []
    var showDeletePageConfirmation = false
    var pendingDeletePageIndices: Set<Int> = []
    var zoomLevel: CGFloat = 1.0
    var zoomSetByUI: Int = 0  // increment to signal PDFCanvasView to push zoom
    var fitToWidthRequest: Int = 1  // increment to request a fit-to-width zoom from PDFCanvasView
    var fitToPageRequest: Int = 0   // increment to request a fit-whole-page zoom from PDFCanvasView
    var showStampPicker = false
    var pendingStampData: Data?
    var selectedStampLibraryID: UUID?
    var showCombineSheet = false

    // MARK: - Z-Order

    private func ensureInDrawOrder(_ id: UUID) {
        if !sidecar.drawOrder.contains(id) {
            sidecar.drawOrder.append(id)
        }
    }

    func bringToFront(_ id: UUID) {
        let oldSidecar = sidecar
        sidecar.drawOrder.removeAll { $0 == id }
        sidecar.drawOrder.append(id)
        registerUndo { vm in vm.sidecar = oldSidecar }
    }

    func sendToBack(_ id: UUID) {
        let oldSidecar = sidecar
        sidecar.drawOrder.removeAll { $0 == id }
        sidecar.drawOrder.insert(id, at: 0)
        registerUndo { vm in vm.sidecar = oldSidecar }
    }

    func bringForward(_ id: UUID) {
        let oldSidecar = sidecar
        ensureInDrawOrder(id)
        guard let idx = sidecar.drawOrder.firstIndex(of: id),
              idx < sidecar.drawOrder.count - 1 else { return }
        sidecar.drawOrder.swapAt(idx, idx + 1)
        registerUndo { vm in vm.sidecar = oldSidecar }
    }

    func sendBackward(_ id: UUID) {
        let oldSidecar = sidecar
        ensureInDrawOrder(id)
        guard let idx = sidecar.drawOrder.firstIndex(of: id),
              idx > 0 else { return }
        sidecar.drawOrder.swapAt(idx, idx - 1)
        registerUndo { vm in vm.sidecar = oldSidecar }
    }

    func drawOrderIndex(for id: UUID) -> Int {
        sidecar.drawOrder.firstIndex(of: id) ?? -1
    }

    // MARK: - Search State
    var searchText: String = ""
    var searchResults: [PDFSelection] = []
    var currentSearchIndex: Int = 0

    /// Revision counter to trigger PDFView search highlight updates.
    var searchHighlightRevision: Int = 0

    func navigateToSearchResult(_ index: Int) {
        guard index >= 0, index < searchResults.count,
              let page = searchResults[index].pages.first,
              let pdf = pdfDocument else { return }
        currentSearchIndex = index
        let pageIndex = pdf.index(for: page)
        goToPage(pageIndex)
        searchHighlightRevision += 1
    }

    func performSearch() {
        searchResults = []
        currentSearchIndex = 0
        guard !searchText.isEmpty, let pdf = pdfDocument else {
            searchHighlightRevision += 1
            return
        }
        searchResults = pdf.findString(searchText, withOptions: .caseInsensitive)
        searchHighlightRevision += 1
    }

    func nextSearchResult() {
        guard !searchResults.isEmpty else { return }
        let next = (currentSearchIndex + 1) % searchResults.count
        navigateToSearchResult(next)
    }

    func previousSearchResult() {
        guard !searchResults.isEmpty else { return }
        let prev = (currentSearchIndex - 1 + searchResults.count) % searchResults.count
        navigateToSearchResult(prev)
    }

    // MARK: - OCR State
    var showOCRToolbar = false
    var showOCRProgress = false
    var ocrCompletedPages: Int = 0
    var ocrIsComplete = false
    var ocrError: String?
    var ocrStatusMessage: String?

    @ObservationIgnored var ocrTask: Task<Void, Never>?

    // MARK: - Word Export State
    var showWordExportProgress = false
    var wordExportCompletedPages: Int = 0
    var wordExportIsComplete = false
    var wordExportError: String?

    @ObservationIgnored var wordExportTask: Task<Void, Never>?

    // MARK: - Table Selection State
    enum TablePageScope: Equatable {
        case currentPage
        case allPages
        case specific([Int])  // 0-indexed page numbers
    }

    enum TableMode: String, CaseIterable, Identifiable {
        case autodetect = "Autodetect"
        case manual = "Manual"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .autodetect: return "wand.and.stars"
            case .manual: return "hand.draw"
            }
        }
    }

    enum TableDetectionMethod: String, CaseIterable {
        case auto = "Auto"
        case lines = "Lines"
        case text = "Text"
        case ocr = "OCR"

        /// Strategy string for PyMuPDF, or nil for auto/OCR.
        var pymudfStrategy: String? {
            switch self {
            case .lines: return "lines"
            case .text: return "text"
            case .auto, .ocr: return nil
            }
        }
    }

    var showTableToolbar = false
    var tableMode: TableMode = .autodetect
    var tableDetectionMethod: TableDetectionMethod = .auto
    var tablePageScope: TablePageScope = .currentPage
    var showTablePreview = false
    var extractedTables: [TableExtractionService.ExtractedTable] = []
    var selectedTableBoxIndex: Int?
    var isDetectingTables = false
    var tableExportError: String?
    var tableSpecificPages: String = ""  // user-entered text for specific pages

    @ObservationIgnored lazy var stampLibrary = StampLibrary()

    // MARK: - Draw Tool Defaults

    var drawShapeType: ShapeType = .rectangle
    var drawStrokeColor: String = "#000000"
    var drawFillColor: String = "#FFFFFF"
    var drawHasFill: Bool = false
    var drawStrokeWidth: CGFloat = 2.0
    var drawStrokeStyle: OutlineStyle = .solid

    // MARK: - Box Selection State
    var boxSelectionRect: CGRect?
    var boxSelectionPageIndex: Int?

    var hasBoxSelection: Bool {
        boxSelectionRect != nil && boxSelectionPageIndex != nil
    }

    /// Incremented whenever annotations change, to trigger PDFCanvasView sync.
    var annotationRevision: Int = 0

    weak var document: SpindriftDocument?
    weak var undoManager: UndoManager?

    /// Stored copy of the sidecar, observable by SwiftUI.
    /// Always assign through this property so both the document and the view stay in sync.
    var sidecar: SidecarModel = SidecarModel() {
        didSet {
            document?.sidecar = sidecar
            annotationRevision += 1
        }
    }

    var pdfDocument: PDFDocument? {
        document?.pdfDocument
    }

    var pageCount: Int {
        pdfDocument?.pageCount ?? 0
    }

    // MARK: - Navigation

    func goToPage(_ index: Int) {
        guard let pdf = pdfDocument, index >= 0, index < pdf.pageCount else { return }
        currentPageIndex = index
    }

    func goToNextPage() {
        goToPage(currentPageIndex + 1)
    }

    func goToPreviousPage() {
        goToPage(currentPageIndex - 1)
    }

    // MARK: - Page Management

    /// Request deletion of the given page indices. Shows a confirmation dialog first.
    func confirmDeletePages(_ indices: Set<Int>) {
        guard let pdf = pdfDocument,
              !indices.isEmpty,
              indices.count < pdf.pageCount else { return }
        pendingDeletePageIndices = indices
        showDeletePageConfirmation = true
    }

    /// Request deletion of a single page. Shows a confirmation dialog first.
    func confirmDeletePage(at pageIndex: Int) {
        confirmDeletePages([pageIndex])
    }

    /// Execute the pending page deletion (called after user confirms).
    func executePendingPageDeletion() {
        deletePages(at: pendingDeletePageIndices)
        pendingDeletePageIndices = []
        selectedPageIndices = []
    }

    /// Delete multiple pages at the given indices. Removes annotations on those pages
    /// and adjusts page indices for subsequent annotations. Cannot delete all pages.
    func deletePages(at pageIndices: Set<Int>) {
        guard let pdf = pdfDocument,
              !pageIndices.isEmpty,
              pageIndices.count < pdf.pageCount else { return }

        // Validate all indices
        let validIndices = pageIndices.filter { $0 >= 0 && $0 < pdf.pageCount }
        guard !validIndices.isEmpty else { return }

        let oldSidecar = sidecar
        let oldPageIndex = currentPageIndex

        // Save pages for undo (in ascending order)
        let sortedIndices = validIndices.sorted()
        let removedPages: [(Int, PDFPage)] = sortedIndices.compactMap { idx in
            guard let page = pdf.page(at: idx) else { return nil }
            return (idx, page)
        }

        // Remove pages from highest index first to avoid index shifting
        for idx in sortedIndices.reversed() {
            pdf.removePage(at: idx)
        }

        // Clean up sidecar
        var updated = sidecar
        let deletedSet = Set(sortedIndices)

        // Remove annotations on deleted pages
        updated.stamps.removeAll { deletedSet.contains($0.pageIndex) }
        updated.textBoxes.removeAll { deletedSet.contains($0.pageIndex) }
        updated.comments.removeAll { deletedSet.contains($0.pageIndex) }
        updated.markups.removeAll { deletedSet.contains($0.pageIndex) }
        updated.shapes.removeAll { deletedSet.contains($0.pageIndex) }
        for idx in sortedIndices {
            updated.ocrResults.removeValue(forKey: String(idx))
        }

        // Build a mapping from old page index to new page index
        // For each surviving page, count how many deleted pages were before it
        func newIndex(for oldIdx: Int) -> Int {
            oldIdx - sortedIndices.prefix(while: { $0 < oldIdx }).count
        }

        // Shift page indices for surviving annotations
        for i in updated.stamps.indices {
            updated.stamps[i].pageIndex = newIndex(for: updated.stamps[i].pageIndex)
        }
        for i in updated.textBoxes.indices {
            updated.textBoxes[i].pageIndex = newIndex(for: updated.textBoxes[i].pageIndex)
        }
        for i in updated.comments.indices {
            updated.comments[i].pageIndex = newIndex(for: updated.comments[i].pageIndex)
        }
        for i in updated.markups.indices {
            updated.markups[i].pageIndex = newIndex(for: updated.markups[i].pageIndex)
        }
        for i in updated.shapes.indices {
            updated.shapes[i].pageIndex = newIndex(for: updated.shapes[i].pageIndex)
        }

        // Re-key OCR results
        var newOCR: [String: OCRPageResult] = [:]
        for (key, value) in updated.ocrResults {
            if let idx = Int(key), !deletedSet.contains(idx) {
                newOCR[String(newIndex(for: idx))] = value
            }
        }
        updated.ocrResults = newOCR

        sidecar = updated
        selectedAnnotationID = nil

        // Adjust current page index
        if currentPageIndex >= pdf.pageCount {
            currentPageIndex = max(0, pdf.pageCount - 1)
        }

        registerUndo { vm in
            // Re-insert pages in ascending order
            for (originalIdx, page) in removedPages {
                vm.pdfDocument?.insert(page, at: originalIdx)
            }
            vm.sidecar = oldSidecar
            vm.currentPageIndex = oldPageIndex
            vm.selectedPageIndices = []
        }
    }

    // MARK: - OCR Actions

    func startOCRCurrentPage() {
        ocrTask?.cancel()
        ocrError = nil
        ocrStatusMessage = "Running OCR on page \(currentPageIndex + 1)..."
        ocrTask = Task {
            do {
                try await ocrCurrentPage()
                ocrStatusMessage = "OCR complete — page \(currentPageIndex + 1)"
                // Clear after 3 seconds
                try? await Task.sleep(for: .seconds(3))
                if ocrStatusMessage?.hasPrefix("OCR complete") == true {
                    ocrStatusMessage = nil
                }
            } catch {
                if !Task.isCancelled {
                    ocrError = error.localizedDescription
                    ocrStatusMessage = nil
                }
            }
        }
    }

    func startOCRAllPages() {
        ocrTask?.cancel()
        ocrCompletedPages = 0
        ocrIsComplete = false
        ocrError = nil
        showOCRProgress = true
        ocrTask = Task {
            do {
                try await ocrAllPages { completedIndex in
                    Task { @MainActor in
                        self.ocrCompletedPages = completedIndex + 1
                    }
                }
                if !Task.isCancelled {
                    ocrIsComplete = true
                }
            } catch {
                if !Task.isCancelled {
                    ocrError = error.localizedDescription
                    showOCRProgress = false
                }
            }
        }
    }

    func cancelOCR() {
        ocrTask?.cancel()
        ocrTask = nil
        showOCRProgress = false
        ocrCompletedPages = 0
        ocrIsComplete = false
    }

    // MARK: - Word Export Actions

    func startWordExport(to url: URL) {
        wordExportTask?.cancel()
        wordExportCompletedPages = 0
        wordExportIsComplete = false
        wordExportError = nil
        showWordExportProgress = true
        wordExportTask = Task {
            do {
                guard let pdf = pdfDocument else {
                    throw WordExportService.WordExportError.noDocument
                }
                try await WordExportService.export(
                    document: pdf,
                    sidecar: sidecar,
                    to: url
                ) { completedIndex in
                    Task { @MainActor in
                        self.wordExportCompletedPages = completedIndex + 1
                    }
                }
                if !Task.isCancelled {
                    wordExportIsComplete = true
                }
            } catch {
                if !Task.isCancelled {
                    wordExportError = error.localizedDescription
                    showWordExportProgress = false
                }
            }
        }
    }

    func cancelWordExport() {
        wordExportTask?.cancel()
        wordExportTask = nil
        showWordExportProgress = false
        wordExportCompletedPages = 0
        wordExportIsComplete = false
    }

    // MARK: - Table Selection Actions

    /// Resolve page scope to a list of valid 0-indexed page numbers.
    func resolvedTablePageIndices() -> [Int] {
        guard let pdf = pdfDocument else { return [] }
        switch tablePageScope {
        case .currentPage:
            return [currentPageIndex]
        case .allPages:
            return Array(0..<pdf.pageCount)
        case .specific(let pages):
            return pages.filter { $0 >= 0 && $0 < pdf.pageCount }
        }
    }

    /// Write the in-memory PDF to a temp file for the Python subprocess.
    /// Returns the temp file URL on success, or nil on failure.
    private func writeTableTempPDF() -> URL? {
        guard let pdf = pdfDocument else { return nil }
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spindrift_table_\(UUID().uuidString).pdf")
        guard pdf.write(to: tempURL) else { return nil }
        return tempURL
    }

    func startTableAutoDetect() {
        guard let pdf = pdfDocument else { return }

        isDetectingTables = true
        extractedTables = []

        if tableDetectionMethod == .ocr {
            // Vision OCR path — operates directly on PDFDocument pages
            Task {
                do {
                    var allTables: [TableExtractionService.ExtractedTable] = []
                    for i in 0..<pdf.pageCount {
                        guard let page = pdf.page(at: i) else { continue }
                        let pageTables = try await VisionTableDetector.detectTables(
                            on: page, pageIndex: i
                        )
                        allTables.append(contentsOf: pageTables)
                    }
                    if !Task.isCancelled {
                        extractedTables = allTables
                        isDetectingTables = false
                        if allTables.isEmpty {
                            tableExportError = "No tables detected."
                        }
                        annotationRevision += 1
                    }
                } catch {
                    if !Task.isCancelled {
                        isDetectingTables = false
                        tableExportError = error.localizedDescription
                    }
                }
            }
        } else {
            // PyMuPDF path — needs a temp file for the Python subprocess
            guard let tempURL = writeTableTempPDF() else {
                tableExportError = "Failed to prepare PDF for table extraction."
                isDetectingTables = false
                return
            }
            let inputPath = tempURL.path
            let strategy = tableDetectionMethod.pymudfStrategy

            Task {
                defer { try? FileManager.default.removeItem(at: tempURL) }
                do {
                    let tables = try await TableExtractionService.detectAndExtract(
                        inputPath: inputPath,
                        pages: nil,
                        strategy: strategy
                    ) { _, _ in }

                    if !Task.isCancelled {
                        extractedTables = tables
                        isDetectingTables = false
                        if tables.isEmpty {
                            tableExportError = "No tables detected."
                        }
                        annotationRevision += 1
                    }
                } catch {
                    if !Task.isCancelled {
                        isDetectingTables = false
                        tableExportError = error.localizedDescription
                    }
                }
            }
        }
    }

    func previewTables() {
        let staleIndices = extractedTables.indices.filter { extractedTables[$0].cells.isEmpty }
        if staleIndices.isEmpty {
            if !extractedTables.isEmpty {
                showTablePreview = true
            }
        } else {
            reExtractStaleTables(staleIndices)
        }
    }

    /// Re-extract tables whose cells were cleared (e.g. after resize/move).
    private func reExtractStaleTables(_ indices: [Int]) {
        guard let pdf = pdfDocument else { return }
        isDetectingTables = true

        guard let tempURL = writeTableTempPDF() else {
            tableExportError = "Failed to prepare PDF for table extraction."
            isDetectingTables = false
            return
        }
        let inputPath = tempURL.path

        // Capture stale table info
        let staleInfo: [(index: Int, pageIndex: Int, bbox: CGRect)] = indices.map { i in
            (i, extractedTables[i].pageIndex, extractedTables[i].bbox)
        }

        Task {
            defer { try? FileManager.default.removeItem(at: tempURL) }
            for info in staleInfo {
                let pageHeight = pdf.page(at: info.pageIndex)?
                    .bounds(for: .mediaBox).height ?? 792.0
                do {
                    // Use force-text extraction (no false-positive filtering)
                    // since the user already defined the table region
                    let tables = try await TableExtractionService.extractFromKnownRegion(
                        inputPath: inputPath,
                        page: info.pageIndex,
                        clip: info.bbox,
                        pageHeight: pageHeight
                    )
                    if !Task.isCancelled, let table = tables.first {
                        extractedTables[info.index].cells = table.cells
                        extractedTables[info.index].colPositions = table.colPositions
                        extractedTables[info.index].rowPositions = table.rowPositions
                    }
                } catch {
                    // Keep empty cells — user will see empty table in preview
                }
            }
            if !Task.isCancelled {
                isDetectingTables = false
                if !extractedTables.isEmpty {
                    showTablePreview = true
                }
            }
        }
    }

    /// Re-extract a table using user-defined grid line positions.
    func reExtractWithGrid(tableIndex: Int, colPositions: [CGFloat], rowPositions: [CGFloat]) {
        guard let pdf = pdfDocument,
              tableIndex < extractedTables.count else { return }
        isDetectingTables = true

        guard let tempURL = writeTableTempPDF() else {
            tableExportError = "Failed to prepare PDF for table extraction."
            isDetectingTables = false
            return
        }
        let inputPath = tempURL.path
        let table = extractedTables[tableIndex]
        let pageHeight = pdf.page(at: table.pageIndex)?
            .bounds(for: .mediaBox).height ?? 792.0

        Task {
            defer { try? FileManager.default.removeItem(at: tempURL) }
            do {
                let tables = try await TableExtractionService.extractWithGrid(
                    inputPath: inputPath,
                    page: table.pageIndex,
                    clip: table.bbox,
                    pageHeight: pageHeight,
                    colPositions: colPositions,
                    rowPositions: rowPositions
                )
                if !Task.isCancelled, let result = tables.first {
                    extractedTables[tableIndex].cells = result.cells
                    extractedTables[tableIndex].colPositions = colPositions
                    extractedTables[tableIndex].rowPositions = rowPositions
                }
            } catch {
                tableExportError = error.localizedDescription
            }
            if !Task.isCancelled {
                isDetectingTables = false
            }
        }
    }

    func deleteSelectedTable() {
        guard let index = selectedTableBoxIndex,
              index >= 0, index < extractedTables.count else { return }
        extractedTables.remove(at: index)
        selectedTableBoxIndex = nil
        annotationRevision += 1
    }

    func clearTableSelection() {
        extractedTables = []
        selectedTableBoxIndex = nil
        annotationRevision += 1
    }

    // MARK: - Box Selection Actions

    func clearBoxSelection() {
        boxSelectionRect = nil
        boxSelectionPageIndex = nil
        annotationRevision += 1
    }

    func copyBoxSelectionToClipboard() {
        guard let rect = boxSelectionRect,
              let pageIndex = boxSelectionPageIndex,
              let page = pdfDocument?.page(at: pageIndex) else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Put vector PDF on the clipboard for full-quality paste in apps that support it
        if let pdfData = BoxSelectService.renderRegionToPDFData(page: page, rect: rect) {
            pasteboard.setData(pdfData, forType: .pdf)
        }
        // Also put a high-res bitmap for apps that only support image paste
        if let image = BoxSelectService.renderRegionToImage(page: page, rect: rect),
           let tiffData = image.tiffRepresentation {
            pasteboard.setData(tiffData, forType: .tiff)
        }
    }

    func cropCurrentPageToBoxSelection() {
        guard let rect = boxSelectionRect,
              let pageIndex = boxSelectionPageIndex,
              let page = pdfDocument?.page(at: pageIndex) else { return }
        let oldCropBox = page.bounds(for: .cropBox)
        page.setBounds(rect, for: .cropBox)
        annotationRevision += 1
        registerUndo { vm in
            page.setBounds(oldCropBox, for: .cropBox)
            vm.annotationRevision += 1
        }
    }

    func cropAllPagesToBoxSelection() {
        guard let rect = boxSelectionRect,
              let pdf = pdfDocument else { return }
        var oldCropBoxes: [(PDFPage, CGRect)] = []
        for i in 0..<pdf.pageCount {
            guard let page = pdf.page(at: i) else { continue }
            oldCropBoxes.append((page, page.bounds(for: .cropBox)))
            page.setBounds(rect, for: .cropBox)
        }
        annotationRevision += 1
        registerUndo { vm in
            for (page, oldBox) in oldCropBoxes {
                page.setBounds(oldBox, for: .cropBox)
            }
            vm.annotationRevision += 1
        }
    }

    // MARK: - Undo

    /// Register an undo operation that dispatches back to the main actor.
    func registerUndo(_ handler: @escaping @MainActor (DocumentViewModel) -> Void) {
        undoManager?.registerUndo(withTarget: self) { vm in
            Task { @MainActor in
                handler(vm)
            }
        }
    }
}
