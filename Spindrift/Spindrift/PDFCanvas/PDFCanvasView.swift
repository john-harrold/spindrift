import SwiftUI
import PDFKit

struct PDFCanvasView: NSViewRepresentable {
    let pdfDocument: PDFDocument
    @Bindable var viewModel: DocumentViewModel

    /// Custom eraser cursor built from the SF Symbol "eraser".
    private static let eraserCursor: NSCursor = {
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            if let symbol = NSImage(systemSymbolName: "eraser", accessibilityDescription: nil) {
                let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
                let configured = symbol.withSymbolConfiguration(config) ?? symbol
                configured.draw(in: rect)
            }
            return true
        }
        // Hot spot near bottom-left of the eraser tip
        return NSCursor(image: image, hotSpot: NSPoint(x: 4, y: 20))
    }()

    func makeNSView(context: Context) -> SpindriftPDFView {
        let pdfView = SpindriftPDFView()
        pdfView.document = pdfDocument
        pdfView.autoScales = false
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .controlBackgroundColor
        pdfView.delegate = context.coordinator
        context.coordinator.pdfView = pdfView

        pdfView.onPageClick = { [weak coordinator = context.coordinator] page, pagePoint, pageIndex in
            coordinator?.handlePageClick(page: page, point: pagePoint, pageIndex: pageIndex) ?? false
        }
        pdfView.onPageDrag = { [weak coordinator = context.coordinator] page, pagePoint, pageIndex in
            coordinator?.handlePageDrag(page: page, point: pagePoint, pageIndex: pageIndex)
        }
        pdfView.onPageMouseUp = { [weak coordinator = context.coordinator] page, pagePoint, pageIndex in
            coordinator?.handlePageMouseUp(page: page, point: pagePoint, pageIndex: pageIndex)
        }
        pdfView.onPageRightClick = { [weak coordinator = context.coordinator] page, pagePoint, pageIndex in
            coordinator?.handlePageRightClick(page: page, point: pagePoint, pageIndex: pageIndex)
        }
        pdfView.onTextSelectionComplete = { [weak coordinator = context.coordinator] in
            coordinator?.handleTextSelectionComplete()
        }
        pdfView.onPageDoubleClick = { [weak coordinator = context.coordinator] page, pagePoint, pageIndex in
            coordinator?.handlePageDoubleClick(page: page, point: pagePoint, pageIndex: pageIndex) ?? false
        }
        pdfView.onEscapeKey = { [weak coordinator = context.coordinator] in
            coordinator?.handleEscapeKey()
        }
        pdfView.onDeleteKey = { [weak coordinator = context.coordinator] in
            coordinator?.handleDeleteKey()
        }
        pdfView.onCopyKey = { [weak coordinator = context.coordinator] in
            coordinator?.handleCopyKey() ?? false
        }

        // Observe page changes from scrolling
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(PDFCanvasCoordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: pdfView
        )

        // Observe scale changes from pinch-zoom
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(PDFCanvasCoordinator.scaleChanged(_:)),
            name: .PDFViewScaleChanged,
            object: pdfView
        )

        return pdfView
    }

    func updateNSView(_ pdfView: SpindriftPDFView, context: Context) {
        if pdfView.document !== pdfDocument {
            pdfView.document = pdfDocument
            context.coordinator.lastFitToWidthRequest = 0
        }
        context.coordinator.viewModel = viewModel

        // Apply fit-to-width whenever the request version changes and bounds are ready.
        let fitRequest = viewModel.fitToWidthRequest
        if fitRequest != context.coordinator.lastFitToWidthRequest,
           pdfView.bounds.width > 0,
           let firstPage = pdfDocument.page(at: 0) {
            let pageWidth = firstPage.bounds(for: .mediaBox).width
            if pageWidth > 0 {
                // Leave a small margin so the page doesn't touch the scrollbar.
                let availableWidth = pdfView.bounds.width - 16
                let scale = max(0.1, min(5.0, availableWidth / pageWidth))
                pdfView.scaleFactor = scale
                let viewModelRef = viewModel
                DispatchQueue.main.async {
                    viewModelRef.zoomLevel = scale
                }
            }
            context.coordinator.lastFitToWidthRequest = fitRequest
            context.coordinator.lastZoomRevision = viewModel.zoomSetByUI
        }

        // Apply fit-whole-page whenever the request version changes and bounds are ready.
        let fitPageRequest = viewModel.fitToPageRequest
        if fitPageRequest != context.coordinator.lastFitToPageRequest,
           pdfView.bounds.width > 0,
           pdfView.bounds.height > 0,
           let currentPage = pdfView.currentPage ?? pdfDocument.page(at: 0) {
            let pageBounds = currentPage.bounds(for: .mediaBox)
            if pageBounds.width > 0, pageBounds.height > 0 {
                let availableWidth = pdfView.bounds.width - 16
                let availableHeight = pdfView.bounds.height - 16
                let widthScale = availableWidth / pageBounds.width
                let heightScale = availableHeight / pageBounds.height
                let scale = max(0.1, min(5.0, min(widthScale, heightScale)))
                pdfView.scaleFactor = scale
                let viewModelRef = viewModel
                DispatchQueue.main.async {
                    viewModelRef.zoomLevel = scale
                }
            }
            context.coordinator.lastFitToPageRequest = fitPageRequest
            context.coordinator.lastZoomRevision = viewModel.zoomSetByUI
        }

        // Navigate to the requested page if it differs from what's visible
        let requestedIndex = viewModel.currentPageIndex
        if let currentPage = pdfView.currentPage,
           let doc = pdfView.document {
            let visibleIndex = doc.index(for: currentPage)
            if visibleIndex != requestedIndex,
               let targetPage = doc.page(at: requestedIndex) {
                pdfView.go(to: targetPage)
            }
        }

        // Read annotationRevision, selectedAnnotationID, and toolMode so SwiftUI tracks them.
        // Note: draw defaults (drawShapeType, drawStrokeColor, etc.) are NOT tracked here
        // because they only affect new shapes, not existing annotations on the canvas.
        let revision = viewModel.annotationRevision
        _ = viewModel.selectedAnnotationID
        _ = viewModel.toolMode

        // Sync zoom level — only push to PDFView when explicitly set by UI buttons
        let zoomRev = viewModel.zoomSetByUI
        if zoomRev != context.coordinator.lastZoomRevision {
            context.coordinator.lastZoomRevision = zoomRev
            pdfView.scaleFactor = viewModel.zoomLevel
        }

        // Set cursor override based on tool mode
        _ = viewModel.selectMode
        if viewModel.toolMode == .tableSelect {
            pdfView.overrideCursor = .crosshair
        } else if viewModel.toolMode == .browse && viewModel.selectMode == .boxSelect {
            pdfView.overrideCursor = .crosshair
        } else if viewModel.toolMode == .removeMarkup {
            pdfView.overrideCursor = Self.eraserCursor
        } else {
            pdfView.overrideCursor = nil
        }

        // Sync search highlights
        let searchRevision = viewModel.searchHighlightRevision
        if searchRevision != context.coordinator.lastSearchHighlightRevision {
            context.coordinator.lastSearchHighlightRevision = searchRevision
            if !viewModel.searchResults.isEmpty {
                // Highlight all results, set current result as selection
                pdfView.highlightedSelections = viewModel.searchResults
                let current = viewModel.searchResults[viewModel.currentSearchIndex]
                pdfView.setCurrentSelection(current, animate: true)
                // Scroll to the current result
                if let page = current.pages.first {
                    let bounds = current.bounds(for: page)
                    pdfView.go(to: bounds, on: page)
                }
            } else {
                pdfView.highlightedSelections = nil
                pdfView.clearSelection()
            }
        }

        // If user switched to a markup tool with existing text selection, apply it
        context.coordinator.applyMarkupIfToolChanged()

        // Only sync annotations when the revision has actually changed
        context.coordinator.syncAnnotationsIfNeeded(revision: revision)
    }

    func makeCoordinator() -> PDFCanvasCoordinator {
        PDFCanvasCoordinator(viewModel: viewModel)
    }
}
