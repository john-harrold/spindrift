import PDFKit
import AppKit

@MainActor
class PDFCanvasCoordinator: NSObject, PDFViewDelegate {
    var viewModel: DocumentViewModel
    weak var pdfView: PDFView?

    /// Tracks which sidecar annotation IDs are currently live as PDFAnnotation objects
    private var liveStampAnnotations: [UUID: StampAnnotation] = [:]
    private var liveTextBoxAnnotations: [UUID: TextBoxAnnotation] = [:]
    private var liveCommentAnnotations: [UUID: CommentAnnotation] = [:]
    private var liveMarkupAnnotations: [UUID: PDFAnnotation] = [:]
    private var liveShapeAnnotations: [UUID: ShapeAnnotation] = [:]

    /// Tracks original (pre-OCR-overlay) pages so we can re-overlay without stacking
    private var originalPages: [Int: PDFPage] = [:]
    /// Last OCR results that were overlaid, to detect changes
    private var lastOverlaidOCR: [String: OCRPageResult]?

    /// Previous tool mode, to detect when user switches to a markup tool with existing selection
    private var previousToolMode: ToolMode = .browse

    /// Last annotation revision that was synced, to avoid redundant sync work.
    private var lastSyncedRevision: Int = -1

    /// Last fit-to-width request version that was applied.
    var lastFitToWidthRequest = 0
    /// Last fit-whole-page request version that was applied.
    var lastFitToPageRequest = 0
    var lastSearchHighlightRevision = 0
    var lastZoomRevision = 0

    /// Shape creation state
    private var shapeCreationStart: CGPoint?
    private var creatingShapeID: UUID?

    /// Table selection state
    private var tableSelectionStart: CGPoint?
    private var tableDrawingRect: CGRect?
    private var tableDrawingPageIndex: Int?
    private var liveTableSelectionAnnotations: [TableSelectionAnnotation] = []

    /// Box selection state
    private var boxSelectionStart: CGPoint?
    private var boxDrawingRect: CGRect?
    private var boxDrawingPageIndex: Int?
    private var liveBoxSelectionAnnotation: BoxSelectionAnnotation?

    // MARK: - Inline Text Editing State

    private var inlineEditingTextBoxID: UUID?
    private var inlineTextView: NSTextView?
    private var inlineScrollView: NSScrollView?
    private var preEditSidecar: SidecarModel?
    private nonisolated(unsafe) var scrollObserver: NSObjectProtocol?
    private nonisolated(unsafe) var zoomObserver: NSObjectProtocol?

    var isEditingTextInline: Bool { inlineEditingTextBoxID != nil }

    // MARK: - Drag State

    private enum DragTarget {
        case comment(id: UUID, startBounds: AnnotationBounds, offset: CGPoint)
        case stamp(id: UUID, startBounds: AnnotationBounds, offset: CGPoint)
        case stampResize(id: UUID, startBounds: AnnotationBounds, corner: InteractionHandler.StampAction, aspectRatio: CGFloat)
        case stampRotate(id: UUID)
        case textBox(id: UUID, startBounds: AnnotationBounds, offset: CGPoint)
        case textBoxResize(id: UUID, startBounds: AnnotationBounds, corner: InteractionHandler.StampAction)
        case textBoxRotate(id: UUID)
        case shape(id: UUID, startBounds: AnnotationBounds, offset: CGPoint)
        case shapeResize(id: UUID, startBounds: AnnotationBounds, corner: InteractionHandler.StampAction)
        case shapeRotate(id: UUID)
        case lineEndpointStart(id: UUID)
        case lineEndpointEnd(id: UUID)
        case tableResize(index: Int, startBounds: AnnotationBounds, corner: InteractionHandler.StampAction)
        case tableMove(index: Int, offset: CGPoint)
        case boxSelectResize(startBounds: AnnotationBounds, corner: InteractionHandler.StampAction)
        case boxSelectMove(offset: CGPoint)
    }

    private var dragTarget: DragTarget?
    /// Sidecar snapshot taken at drag start, for undo
    private var preDragSidecar: SidecarModel?

    init(viewModel: DocumentViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    deinit {
        if let obs = scrollObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = zoomObserver { NotificationCenter.default.removeObserver(obs) }
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Page Change Notification

    @objc func pageChanged(_ notification: Notification) {
        guard let pdfView = pdfView,
              let currentPage = pdfView.currentPage,
              let document = pdfView.document else { return }
        let pageIndex = document.index(for: currentPage)
        viewModel.currentPageIndex = pageIndex
    }

    @objc func scaleChanged(_ notification: Notification) {
        guard let pdfView = pdfView else { return }
        // Update viewModel to match PDFView's actual scale (from pinch-zoom)
        let rounded = (pdfView.scaleFactor * 100).rounded() / 100
        if abs(viewModel.zoomLevel - rounded) > 0.001 {
            viewModel.zoomLevel = rounded
        }
    }

    // MARK: - Double-Click / Inline Editing

    /// Handle a double-click on a PDF page. Returns true if the click was consumed.
    func handlePageDoubleClick(page: PDFPage, point: CGPoint, pageIndex: Int) -> Bool {
        // Hit-test for text box
        let hit = InteractionHandler.hitTest(
            point: point,
            sidecar: viewModel.sidecar,
            pageIndex: pageIndex
        )
        guard case .textBox(let id, _) = hit else { return false }
        guard let tbIndex = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == id }),
              let annotation = liveTextBoxAnnotations[id] else { return false }

        beginInlineEdit(textBoxID: id, textBoxIndex: tbIndex, annotation: annotation, page: page)
        return true
    }

    private func beginInlineEdit(textBoxID: UUID, textBoxIndex: Int, annotation: TextBoxAnnotation, page: PDFPage) {
        guard let pdfView = pdfView as? SpindriftPDFView else { return }

        // Commit any existing inline edit first
        if isEditingTextInline { commitInlineEdit() }

        let textBox = viewModel.sidecar.textBoxes[textBoxIndex]
        preEditSidecar = viewModel.sidecar
        inlineEditingTextBoxID = textBoxID

        // Suppress text drawing on the annotation
        annotation.isEditingInline_ = true
        pdfView.setNeedsDisplay(pdfView.bounds)

        // Convert the text box rect from page coordinates to PDFView coordinates
        let pageRect = textBox.bounds.cgRect
        let viewRect = pdfView.convert(pageRect, from: page)

        // Create the text view inside a scroll view (required for NSTextView)
        let scrollView = NSScrollView(frame: viewRect)
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: CGRect(origin: .zero, size: viewRect.size))
        textView.isRichText = false
        textView.isFieldEditor = false
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true

        // Match font scaled by PDFView's scale factor
        let scaledFontSize = textBox.fontSize * pdfView.scaleFactor
        let font = NSFont(name: textBox.fontName, size: scaledFontSize)
            ?? .systemFont(ofSize: scaledFontSize)
        textView.font = font
        textView.textColor = NSColor(hex: textBox.color) ?? .black

        // Inset to match the 4pt/2pt text inset used in TextBoxAnnotation.draw()
        let insetX = 4 * pdfView.scaleFactor
        let insetY = 2 * pdfView.scaleFactor
        textView.textContainerInset = NSSize(width: insetX, height: insetY)

        textView.string = textBox.text

        scrollView.documentView = textView

        // Add to PDFView's view hierarchy
        pdfView.addSubview(scrollView)

        inlineTextView = textView
        inlineScrollView = scrollView

        // Make the text view first responder, then select all
        // (selectAll requires the view to be in the hierarchy and first responder)
        pdfView.window?.makeFirstResponder(textView)
        textView.selectAll(nil)

        // Register scroll/zoom observers to auto-commit
        scrollObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitInlineEdit() }
        }
        zoomObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: pdfView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.commitInlineEdit() }
        }
    }

    func commitInlineEdit() {
        guard let textBoxID = inlineEditingTextBoxID,
              let textView = inlineTextView else { return }

        let newText = textView.string
        if let idx = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == textBoxID }) {
            viewModel.sidecar.textBoxes[idx].text = newText
        }

        // Register undo back to pre-edit state
        if let oldSidecar = preEditSidecar, oldSidecar != viewModel.sidecar {
            viewModel.registerUndo { vm in
                vm.sidecar = oldSidecar
            }
        }

        dismissInlineEditor()
    }

    func cancelInlineEdit() {
        // Restore sidecar to pre-edit state
        if let oldSidecar = preEditSidecar {
            viewModel.sidecar = oldSidecar
        }
        dismissInlineEditor()
    }

    func handleEscapeKey() {
        if isEditingTextInline {
            cancelInlineEdit()
            return
        }
        if viewModel.hasBoxSelection {
            viewModel.clearBoxSelection()
            syncBoxSelectionOverlay()
        }
    }

    private func dismissInlineEditor() {
        // Remove overlay
        inlineScrollView?.removeFromSuperview()
        inlineScrollView = nil
        inlineTextView = nil

        // Restore annotation text drawing
        if let textBoxID = inlineEditingTextBoxID,
           let annotation = liveTextBoxAnnotations[textBoxID] {
            annotation.isEditingInline_ = false
        }

        inlineEditingTextBoxID = nil
        preEditSidecar = nil

        // Remove observers
        if let obs = scrollObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = zoomObserver { NotificationCenter.default.removeObserver(obs) }
        scrollObserver = nil
        zoomObserver = nil

        // Restore first responder to PDFView and refresh
        if let pdfView = pdfView {
            pdfView.window?.makeFirstResponder(pdfView)
            pdfView.setNeedsDisplay(pdfView.bounds)
        }

        syncAnnotations()
    }

    // MARK: - Click Handling

    /// Handle a click on a PDF page. Returns true if the click was consumed.
    func handlePageClick(page: PDFPage, point: CGPoint, pageIndex: Int) -> Bool {
        // If inline editing, commit on click-outside
        if isEditingTextInline {
            commitInlineEdit()
            return true
        }

        dragTarget = nil
        preDragSidecar = nil

        switch viewModel.toolMode {
        case .stamp:
            // Check if clicking any existing annotation first
            let stampHit = InteractionHandler.hitTest(
                point: point,
                sidecar: viewModel.sidecar,
                pageIndex: pageIndex
            )
            if case .stamp(let id, let action) = stampHit {
                viewModel.selectedAnnotationID = id
                if let idx = viewModel.sidecar.stamps.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.stamps[idx].bounds
                    preDragSidecar = viewModel.sidecar
                    if action == .rotate {
                        dragTarget = .stampRotate(id: id)
                    } else if action == .drag {
                        let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                        dragTarget = .stamp(id: id, startBounds: b, offset: offset)
                    } else {
                        let ar = stampAspectRatio(at: idx)
                        dragTarget = .stampResize(id: id, startBounds: b, corner: action, aspectRatio: ar)
                    }
                }
                syncAnnotations()
                return true
            }
            // Clicked a different annotation type — switch to it
            if let handled = handleCrossTypeHit(stampHit, point: point) {
                return handled
            }

            // Place a new stamp if one is selected from the library
            if let stampData = viewModel.pendingStampData {
                viewModel.addStamp(imageData: stampData)
            }
            return true

        case .textBox:
            // Check if clicking any existing annotation first
            let tbHit = InteractionHandler.hitTest(
                point: point,
                sidecar: viewModel.sidecar,
                pageIndex: pageIndex
            )
            if case .textBox(let id, let action) = tbHit {
                viewModel.selectedAnnotationID = id
                if let idx = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.textBoxes[idx].bounds
                    preDragSidecar = viewModel.sidecar
                    if action == .rotate {
                        dragTarget = .textBoxRotate(id: id)
                    } else if action == .drag {
                        let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                        dragTarget = .textBox(id: id, startBounds: b, offset: offset)
                    } else {
                        dragTarget = .textBoxResize(id: id, startBounds: b, corner: action)
                    }
                }
                syncAnnotations()
                return true
            }
            // Clicked a different annotation type — switch to it
            if let handled = handleCrossTypeHit(tbHit, point: point) {
                return handled
            }

            // Place a new text box; stay in text box mode
            let bounds = AnnotationBounds(
                x: point.x - 100,
                y: point.y - 20,
                width: 200,
                height: 40
            )
            let textBox = TextBoxAnnotationModel(
                pageIndex: pageIndex,
                bounds: bounds
            )
            let oldSidecar = viewModel.sidecar
            viewModel.sidecar.textBoxes.append(textBox)
            viewModel.selectedAnnotationID = textBox.id
            viewModel.registerUndo { vm in
                vm.sidecar = oldSidecar
            }
            syncAnnotations()
            return true

        case .comment:
            // Check if clicking any existing annotation first
            let hit = InteractionHandler.hitTest(
                point: point,
                sidecar: viewModel.sidecar,
                pageIndex: pageIndex
            )
            if case .comment(let id) = hit {
                viewModel.selectedAnnotationID = id
                if let idx = viewModel.sidecar.comments.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.comments[idx].bounds
                    let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                    dragTarget = .comment(id: id, startBounds: b, offset: offset)
                    preDragSidecar = viewModel.sidecar
                }
                syncAnnotations()
                return true
            }
            // Clicked a different annotation type — switch to it
            if let handled = handleCrossTypeHit(hit, point: point) {
                return handled
            }

            // Place a new comment; stay in comment mode
            let bounds = AnnotationBounds(
                x: point.x - 12,
                y: point.y - 12,
                width: 24,
                height: 24
            )
            let comment = CommentAnnotationModel(
                pageIndex: pageIndex,
                bounds: bounds
            )
            let oldSidecar = viewModel.sidecar
            viewModel.sidecar.comments.append(comment)
            viewModel.selectedAnnotationID = comment.id
            viewModel.registerUndo { vm in
                vm.sidecar = oldSidecar
            }
            syncAnnotations()
            return true

        case .draw:
            // Check if clicking any existing annotation first
            let drawHit = InteractionHandler.hitTest(
                point: point,
                sidecar: viewModel.sidecar,
                pageIndex: pageIndex
            )
            if case .shape(let id, let action) = drawHit {
                viewModel.selectedAnnotationID = id
                if let idx = viewModel.sidecar.shapes.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.shapes[idx].bounds
                    preDragSidecar = viewModel.sidecar
                    switch action {
                    case .rotate:
                        dragTarget = .shapeRotate(id: id)
                    case .dragLineStart:
                        dragTarget = .lineEndpointStart(id: id)
                    case .dragLineEnd:
                        dragTarget = .lineEndpointEnd(id: id)
                    case .drag:
                        let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                        dragTarget = .shape(id: id, startBounds: b, offset: offset)
                    default:
                        dragTarget = .shapeResize(id: id, startBounds: b, corner: action)
                    }
                }
                syncAnnotations()
                return true
            }
            // Clicked a different annotation type — switch to it
            if let handled = handleCrossTypeHit(drawHit, point: point) {
                return handled
            }

            // Start creating a new shape
            let shapeID = UUID()
            let isLine = (viewModel.drawShapeType == .line || viewModel.drawShapeType == .arrow)
            let bounds = AnnotationBounds(x: point.x, y: point.y, width: 0, height: 0)
            let shape = ShapeAnnotationModel(
                id: shapeID,
                pageIndex: pageIndex,
                bounds: bounds,
                shapeType: viewModel.drawShapeType,
                strokeColor: viewModel.drawStrokeColor,
                fillColor: viewModel.drawHasFill ? viewModel.drawFillColor : nil,
                strokeWidth: viewModel.drawStrokeWidth,
                strokeStyle: viewModel.drawStrokeStyle,
                lineStart: isLine ? QuadPoint(x: point.x, y: point.y) : nil,
                lineEnd: isLine ? QuadPoint(x: point.x, y: point.y) : nil
            )
            preDragSidecar = viewModel.sidecar
            viewModel.sidecar.shapes.append(shape)
            viewModel.selectedAnnotationID = shapeID
            shapeCreationStart = point
            creatingShapeID = shapeID
            syncAnnotations()
            return true

        case .tableSelect:
            // Check if clicking on the selected table box (resize handle or body-move)
            if let selIdx = viewModel.selectedTableBoxIndex,
               selIdx < viewModel.extractedTables.count {
                let selTable = viewModel.extractedTables[selIdx]
                if selTable.pageIndex == pageIndex {
                    let action = InteractionHandler.resizeActionForRect(point: point, bounds: selTable.bbox)
                    if action != .drag {
                        // Start resize drag
                        let startBounds = AnnotationBounds(selTable.bbox)
                        dragTarget = .tableResize(index: selIdx, startBounds: startBounds, corner: action)
                        return true
                    } else if selTable.bbox.contains(point) {
                        // Start move drag
                        let offset = CGPoint(x: point.x - selTable.bbox.origin.x,
                                             y: point.y - selTable.bbox.origin.y)
                        dragTarget = .tableMove(index: selIdx, offset: offset)
                        return true
                    }
                }
            }
            // Check if clicking on an auto-detected table region
            for (i, table) in viewModel.extractedTables.enumerated() where table.pageIndex == pageIndex {
                if table.bbox.contains(point) {
                    viewModel.selectedTableBoxIndex = i
                    syncTableSelectionOverlay()
                    return true
                }
            }
            // Clicking empty space — clear selection, start drag for new box
            viewModel.selectedTableBoxIndex = nil
            tableSelectionStart = point
            tableDrawingPageIndex = pageIndex
            syncTableSelectionOverlay()
            return true

        case .browse:
            // Box selection mode: handle box resize/move/draw before annotation hit-test
            if viewModel.selectMode == .boxSelect {
                // Hit-test existing box selection for resize/move
                if let existingRect = viewModel.boxSelectionRect,
                   let existingPage = viewModel.boxSelectionPageIndex,
                   existingPage == pageIndex {
                    let action = InteractionHandler.resizeActionForRect(point: point, bounds: existingRect)
                    if action != .drag {
                        let startBounds = AnnotationBounds(existingRect)
                        dragTarget = .boxSelectResize(startBounds: startBounds, corner: action)
                        return true
                    } else if existingRect.contains(point) {
                        let offset = CGPoint(x: point.x - existingRect.origin.x,
                                             y: point.y - existingRect.origin.y)
                        dragTarget = .boxSelectMove(offset: offset)
                        return true
                    }
                }
                // Start drawing a new box
                viewModel.clearBoxSelection()
                boxSelectionStart = point
                boxDrawingPageIndex = pageIndex
                return true
            }

            // Text mode: existing annotation hit-test behavior
            let hit = InteractionHandler.hitTest(
                point: point,
                sidecar: viewModel.sidecar,
                pageIndex: pageIndex
            )
            switch hit {
            case .comment(let id):
                viewModel.selectedAnnotationID = id
                viewModel.toolMode = .comment
                if let idx = viewModel.sidecar.comments.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.comments[idx].bounds
                    let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                    dragTarget = .comment(id: id, startBounds: b, offset: offset)
                    preDragSidecar = viewModel.sidecar
                }
                return true

            case .stamp(let id, let action):
                viewModel.selectedAnnotationID = id
                if let idx = viewModel.sidecar.stamps.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.stamps[idx].bounds
                    preDragSidecar = viewModel.sidecar
                    if action == .rotate {
                        dragTarget = .stampRotate(id: id)
                    } else if action == .drag {
                        let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                        dragTarget = .stamp(id: id, startBounds: b, offset: offset)
                    } else {
                        let ar = stampAspectRatio(at: idx)
                        dragTarget = .stampResize(id: id, startBounds: b, corner: action, aspectRatio: ar)
                    }
                }
                return true

            case .textBox(let id, let action):
                viewModel.selectedAnnotationID = id
                viewModel.toolMode = .textBox
                if let idx = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.textBoxes[idx].bounds
                    preDragSidecar = viewModel.sidecar
                    if action == .rotate {
                        dragTarget = .textBoxRotate(id: id)
                    } else if action == .drag {
                        let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                        dragTarget = .textBox(id: id, startBounds: b, offset: offset)
                    } else {
                        dragTarget = .textBoxResize(id: id, startBounds: b, corner: action)
                    }
                }
                return true

            case .shape(let id, let action):
                viewModel.selectedAnnotationID = id
                viewModel.toolMode = .draw
                if let idx = viewModel.sidecar.shapes.firstIndex(where: { $0.id == id }) {
                    let b = viewModel.sidecar.shapes[idx].bounds
                    preDragSidecar = viewModel.sidecar
                    switch action {
                    case .rotate:
                        dragTarget = .shapeRotate(id: id)
                    case .dragLineStart:
                        dragTarget = .lineEndpointStart(id: id)
                    case .dragLineEnd:
                        dragTarget = .lineEndpointEnd(id: id)
                    case .drag:
                        let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                        dragTarget = .shape(id: id, startBounds: b, offset: offset)
                    default:
                        dragTarget = .shapeResize(id: id, startBounds: b, corner: action)
                    }
                }
                return true

            case .none:
                viewModel.selectedAnnotationID = nil
                return false
            }

        case .highlight, .underline, .strikethrough:
            return false

        case .removeMarkup:
            // Hit-test against markup annotations on this page and remove
            if let markupIndex = hitTestMarkup(point: point, pageIndex: pageIndex) {
                let oldSidecar = viewModel.sidecar
                var updated = viewModel.sidecar
                updated.markups.remove(at: markupIndex)
                viewModel.sidecar = updated
                viewModel.registerUndo { vm in
                    vm.sidecar = oldSidecar
                }
                syncAnnotations()
            }
            // Always consume clicks in remove mode to prevent accidental text selection
            return true
        }
    }

    /// Handle a hit on an annotation of a different type than the current tool mode.
    /// Switches to the appropriate tool, selects the annotation, and sets up drag state.
    /// Returns `true` if a cross-type hit was handled, `nil` if the hit was `.none`.
    private func handleCrossTypeHit(_ hit: InteractionHandler.HitResult, point: CGPoint) -> Bool? {
        switch hit {
        case .none:
            return nil

        case .comment(let id):
            viewModel.selectedAnnotationID = id
            viewModel.toolMode = .comment
            if let idx = viewModel.sidecar.comments.firstIndex(where: { $0.id == id }) {
                let b = viewModel.sidecar.comments[idx].bounds
                let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                dragTarget = .comment(id: id, startBounds: b, offset: offset)
                preDragSidecar = viewModel.sidecar
            }
            syncAnnotations()
            return true

        case .stamp(let id, let action):
            viewModel.selectedAnnotationID = id
            viewModel.toolMode = .browse
            if let idx = viewModel.sidecar.stamps.firstIndex(where: { $0.id == id }) {
                let b = viewModel.sidecar.stamps[idx].bounds
                preDragSidecar = viewModel.sidecar
                if action == .rotate {
                    dragTarget = .stampRotate(id: id)
                } else if action == .drag {
                    let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                    dragTarget = .stamp(id: id, startBounds: b, offset: offset)
                } else {
                    let ar = stampAspectRatio(at: idx)
                    dragTarget = .stampResize(id: id, startBounds: b, corner: action, aspectRatio: ar)
                }
            }
            syncAnnotations()
            return true

        case .textBox(let id, let action):
            viewModel.selectedAnnotationID = id
            viewModel.toolMode = .textBox
            if let idx = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == id }) {
                let b = viewModel.sidecar.textBoxes[idx].bounds
                preDragSidecar = viewModel.sidecar
                if action == .drag {
                    let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                    dragTarget = .textBox(id: id, startBounds: b, offset: offset)
                } else {
                    dragTarget = .textBoxResize(id: id, startBounds: b, corner: action)
                }
            }
            syncAnnotations()
            return true

        case .shape(let id, let action):
            viewModel.selectedAnnotationID = id
            viewModel.toolMode = .draw
            if let idx = viewModel.sidecar.shapes.firstIndex(where: { $0.id == id }) {
                let b = viewModel.sidecar.shapes[idx].bounds
                preDragSidecar = viewModel.sidecar
                switch action {
                case .rotate:
                    dragTarget = .shapeRotate(id: id)
                case .dragLineStart:
                    dragTarget = .lineEndpointStart(id: id)
                case .dragLineEnd:
                    dragTarget = .lineEndpointEnd(id: id)
                case .drag:
                    let offset = CGPoint(x: point.x - b.x, y: point.y - b.y)
                    dragTarget = .shape(id: id, startBounds: b, offset: offset)
                default:
                    dragTarget = .shapeResize(id: id, startBounds: b, corner: action)
                }
            }
            syncAnnotations()
            return true
        }
    }

    /// Find the index of the first markup annotation whose live bounds contain the given point.
    private func hitTestMarkup(point: CGPoint, pageIndex: Int) -> Int? {
        // Hit-test against live PDFAnnotation objects for accurate results
        for (id, annotation) in liveMarkupAnnotations {
            // Expand bounds slightly for easier clicking
            let bounds = annotation.bounds.insetBy(dx: -4, dy: -4)
            guard bounds.contains(point) else { continue }
            // Verify this annotation is on the correct page
            if let annotationPage = annotation.page,
               let doc = pdfView?.document,
               doc.index(for: annotationPage) == pageIndex {
                // Find the sidecar index for this ID
                if let index = viewModel.sidecar.markups.firstIndex(where: { $0.id == id }) {
                    return index
                }
            }
        }
        return nil
    }

    // MARK: - Right-Click Handling

    func handlePageRightClick(page: PDFPage, point: CGPoint, pageIndex: Int) -> NSMenu? {
        let hit = InteractionHandler.hitTest(
            point: point,
            sidecar: viewModel.sidecar,
            pageIndex: pageIndex
        )

        switch hit {
        case .comment(let id):
            viewModel.selectedAnnotationID = id
            syncAnnotations()
            let menu = NSMenu()
            let deleteItem = NSMenuItem(title: "Delete Comment", action: #selector(deleteAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = id
            menu.addItem(deleteItem)
            return menu

        case .stamp(let id, _):
            viewModel.selectedAnnotationID = id
            syncAnnotations()
            let menu = NSMenu()
            let deleteItem = NSMenuItem(title: "Delete Stamp", action: #selector(deleteAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = id
            menu.addItem(deleteItem)
            addZOrderItems(to: menu, for: id)
            return menu

        case .textBox(let id, _):
            viewModel.selectedAnnotationID = id
            syncAnnotations()
            let menu = NSMenu()
            let deleteItem = NSMenuItem(title: "Delete Text Box", action: #selector(deleteAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = id
            menu.addItem(deleteItem)
            addZOrderItems(to: menu, for: id)
            return menu

        case .shape(let id, _):
            viewModel.selectedAnnotationID = id
            syncAnnotations()
            let menu = NSMenu()
            let deleteItem = NSMenuItem(title: "Delete Shape", action: #selector(deleteAnnotation(_:)), keyEquivalent: "")
            deleteItem.target = self
            deleteItem.representedObject = id
            menu.addItem(deleteItem)
            addZOrderItems(to: menu, for: id)
            return menu

        case .none:
            return nil
        }
    }

    private func addZOrderItems(to menu: NSMenu, for id: UUID) {
        menu.addItem(NSMenuItem.separator())
        let bringFront = NSMenuItem(title: "Bring to Front", action: #selector(bringToFrontAction(_:)), keyEquivalent: "")
        bringFront.target = self
        bringFront.representedObject = id
        menu.addItem(bringFront)
        let bringForward = NSMenuItem(title: "Bring Forward", action: #selector(bringForwardAction(_:)), keyEquivalent: "")
        bringForward.target = self
        bringForward.representedObject = id
        menu.addItem(bringForward)
        let sendBackward = NSMenuItem(title: "Send Backward", action: #selector(sendBackwardAction(_:)), keyEquivalent: "")
        sendBackward.target = self
        sendBackward.representedObject = id
        menu.addItem(sendBackward)
        let sendBack = NSMenuItem(title: "Send to Back", action: #selector(sendToBackAction(_:)), keyEquivalent: "")
        sendBack.target = self
        sendBack.representedObject = id
        menu.addItem(sendBack)
    }

    @objc private func bringToFrontAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel.bringToFront(id)
        syncAnnotations()
    }
    @objc private func bringForwardAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel.bringForward(id)
        syncAnnotations()
    }
    @objc private func sendBackwardAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel.sendBackward(id)
        syncAnnotations()
    }
    @objc private func sendToBackAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        viewModel.sendToBack(id)
        syncAnnotations()
    }

    @objc private func deleteAnnotation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        deleteAnnotationByID(id)
    }

    private func deleteAnnotationByID(_ id: UUID) {
        var updated = viewModel.sidecar
        let oldSidecar = updated
        var nextSelection: UUID?

        if updated.comments.contains(where: { $0.id == id }) {
            updated.comments.removeAll { $0.id == id }
            nextSelection = updated.comments.last?.id
        } else if updated.stamps.contains(where: { $0.id == id }) {
            updated.stamps.removeAll { $0.id == id }
            nextSelection = updated.stamps.last?.id
        } else if updated.textBoxes.contains(where: { $0.id == id }) {
            updated.textBoxes.removeAll { $0.id == id }
            nextSelection = updated.textBoxes.last?.id
        } else if updated.markups.contains(where: { $0.id == id }) {
            updated.markups.removeAll { $0.id == id }
        } else if updated.shapes.contains(where: { $0.id == id }) {
            updated.shapes.removeAll { $0.id == id }
            nextSelection = updated.shapes.last?.id
        }

        viewModel.sidecar = updated
        viewModel.selectedAnnotationID = nextSelection
        viewModel.registerUndo { vm in
            vm.sidecar = oldSidecar
        }
    }

    /// Delete the currently selected annotation, table box, or request page deletion if nothing is selected.
    func handleDeleteKey() {
        guard !isEditingTextInline else { return }
        // Delete selected table box if in table select mode
        if viewModel.toolMode == .tableSelect, viewModel.selectedTableBoxIndex != nil {
            viewModel.deleteSelectedTable()
            syncTableSelectionOverlay()
            return
        }
        if let id = viewModel.selectedAnnotationID {
            deleteAnnotationByID(id)
        } else {
            // No annotation selected — delete selected pages or current page
            let indices = viewModel.selectedPageIndices.isEmpty
                ? [viewModel.currentPageIndex]
                : viewModel.selectedPageIndices
            viewModel.confirmDeletePages(Set(indices))
        }
    }

    // MARK: - Drag Handling

    func handlePageDrag(page: PDFPage, point: CGPoint, pageIndex: Int) {
        // Handle box selection drawing drag
        if let startPoint = boxSelectionStart, viewModel.toolMode == .browse, viewModel.selectMode == .boxSelect {
            let minX = min(startPoint.x, point.x)
            let minY = min(startPoint.y, point.y)
            let w = abs(point.x - startPoint.x)
            let h = abs(point.y - startPoint.y)
            boxDrawingRect = CGRect(x: minX, y: minY, width: w, height: h)
            boxDrawingPageIndex = pageIndex
            syncBoxSelectionOverlay()
            return
        }

        // Handle table selection drag
        if let startPoint = tableSelectionStart, viewModel.toolMode == .tableSelect {
            let minX = min(startPoint.x, point.x)
            let minY = min(startPoint.y, point.y)
            let w = abs(point.x - startPoint.x)
            let h = abs(point.y - startPoint.y)
            tableDrawingRect = CGRect(x: minX, y: minY, width: w, height: h)
            tableDrawingPageIndex = pageIndex
            syncTableSelectionOverlay()
            return
        }

        // Handle shape creation drag — update live annotation directly for responsiveness
        if let startPoint = shapeCreationStart, let shapeID = creatingShapeID {
            if let annotation = liveShapeAnnotations[shapeID],
               (annotation.shapeType == .line || annotation.shapeType == .arrow) {
                // Line/arrow: set endpoints directly (free direction)
                updateLiveLineEndpoints(id: shapeID, start: startPoint, end: point, page: page)
            } else {
                let minX = min(startPoint.x, point.x)
                let minY = min(startPoint.y, point.y)
                let w = abs(point.x - startPoint.x)
                let h = abs(point.y - startPoint.y)
                let newBounds = CGRect(x: minX, y: minY, width: w, height: h)
                updateLiveShapeBounds(id: shapeID, newBounds: newBounds, page: page)
            }
            return
        }

        guard let target = dragTarget else { return }

        switch target {
        case .comment(let id, _, let offset):
            if let idx = viewModel.sidecar.comments.firstIndex(where: { $0.id == id }) {
                viewModel.sidecar.comments[idx].bounds.x = point.x - offset.x
                viewModel.sidecar.comments[idx].bounds.y = point.y - offset.y
                syncAnnotations()
            }

        case .stamp(let id, _, let offset):
            if let idx = viewModel.sidecar.stamps.firstIndex(where: { $0.id == id }) {
                viewModel.sidecar.stamps[idx].bounds.x = point.x - offset.x
                viewModel.sidecar.stamps[idx].bounds.y = point.y - offset.y
                syncAnnotations()
            }

        case .stampResize(let id, let startBounds, let corner, let aspectRatio):
            let newBounds = resizedBounds(startBounds: startBounds, corner: corner, currentPoint: point, aspectRatio: aspectRatio)
            if let idx = viewModel.sidecar.stamps.firstIndex(where: { $0.id == id }) {
                viewModel.sidecar.stamps[idx].bounds = newBounds
                syncAnnotations()
            }

        case .stampRotate(let id):
            if let idx = viewModel.sidecar.stamps.firstIndex(where: { $0.id == id }) {
                let b = viewModel.sidecar.stamps[idx].bounds
                let cx = b.x + b.width / 2
                let cy = b.y + b.height / 2
                // Angle from center to current mouse position
                let angle = atan2(point.x - cx, point.y - cy)
                let degrees = -angle * 180 / .pi
                // Snap to nearest degree
                viewModel.sidecar.stamps[idx].rotation = degrees.truncatingRemainder(dividingBy: 360)
                syncAnnotations()
            }

        case .textBoxRotate(let id):
            if let idx = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == id }) {
                let b = viewModel.sidecar.textBoxes[idx].bounds
                let cx = b.x + b.width / 2
                let cy = b.y + b.height / 2
                let angle = atan2(point.x - cx, point.y - cy)
                let degrees = -angle * 180 / .pi
                viewModel.sidecar.textBoxes[idx].rotation = degrees.truncatingRemainder(dividingBy: 360)
                syncAnnotations()
            }

        case .textBox(let id, _, let offset):
            if let idx = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == id }) {
                viewModel.sidecar.textBoxes[idx].bounds.x = point.x - offset.x
                viewModel.sidecar.textBoxes[idx].bounds.y = point.y - offset.y
                syncAnnotations()
            }

        case .textBoxResize(let id, let startBounds, let corner):
            let newBounds = resizedBounds(startBounds: startBounds, corner: corner, currentPoint: point)
            if let idx = viewModel.sidecar.textBoxes.firstIndex(where: { $0.id == id }) {
                viewModel.sidecar.textBoxes[idx].bounds = newBounds
                syncAnnotations()
            }

        case .shape(let id, _, let offset):
            if let existing = liveShapeAnnotations[id],
               (existing.shapeType == .line || existing.shapeType == .arrow),
               let ls = existing.lineStart_, let le = existing.lineEnd_ {
                // Body-drag for line: translate both endpoints
                let dx = point.x - offset.x - existing.logicalBounds_.origin.x
                let dy = point.y - offset.y - existing.logicalBounds_.origin.y
                let newStart = CGPoint(x: ls.x + dx, y: ls.y + dy)
                let newEnd = CGPoint(x: le.x + dx, y: le.y + dy)
                updateLiveLineEndpoints(id: id, start: newStart, end: newEnd, page: page)
            } else if let existing = liveShapeAnnotations[id] {
                let newOrigin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
                let newBounds = CGRect(origin: newOrigin, size: existing.logicalBounds_.size)
                updateLiveShapeBounds(id: id, newBounds: newBounds, page: page)
            }

        case .shapeResize(let id, let startBounds, let corner):
            let newBounds = resizedBounds(startBounds: startBounds, corner: corner, currentPoint: point)
            updateLiveShapeBounds(id: id, newBounds: newBounds.cgRect, page: page)

        case .shapeRotate(let id):
            if let idx = viewModel.sidecar.shapes.firstIndex(where: { $0.id == id }) {
                let b = viewModel.sidecar.shapes[idx].bounds
                let cx = b.x + b.width / 2
                let cy = b.y + b.height / 2
                let angle = atan2(point.x - cx, point.y - cy)
                let degrees = -angle * 180 / .pi
                viewModel.sidecar.shapes[idx].rotation = degrees.truncatingRemainder(dividingBy: 360)
                syncAnnotations()
            }

        case .lineEndpointStart(let id):
            if let existing = liveShapeAnnotations[id], let le = existing.lineEnd_ {
                updateLiveLineEndpoints(id: id, start: point, end: le, page: page)
            }

        case .lineEndpointEnd(let id):
            if let existing = liveShapeAnnotations[id], let ls = existing.lineStart_ {
                updateLiveLineEndpoints(id: id, start: ls, end: point, page: page)
            }

        case .tableResize(let index, let startBounds, let corner):
            let newBounds = resizedBounds(startBounds: startBounds, corner: corner, currentPoint: point)
            if index < viewModel.extractedTables.count {
                viewModel.extractedTables[index].bbox = newBounds.cgRect
                syncTableSelectionOverlay()
            }

        case .tableMove(let index, let offset):
            if index < viewModel.extractedTables.count {
                let newOrigin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
                viewModel.extractedTables[index].bbox.origin = newOrigin
                syncTableSelectionOverlay()
            }

        case .boxSelectResize(let startBounds, let corner):
            let newBounds = resizedBounds(startBounds: startBounds, corner: corner, currentPoint: point)
            viewModel.boxSelectionRect = newBounds.cgRect
            syncBoxSelectionOverlay()

        case .boxSelectMove(let offset):
            let newOrigin = CGPoint(x: point.x - offset.x, y: point.y - offset.y)
            viewModel.boxSelectionRect?.origin = newOrigin
            syncBoxSelectionOverlay()
        }
    }

    /// Update a live shape annotation's bounds directly on the page, bypassing the full sync pipeline.
    private func updateLiveShapeBounds(id: UUID, newBounds: CGRect, page: PDFPage) {
        guard let pdfView = pdfView,
              let existing = liveShapeAnnotations[id] else { return }
        existing.page?.removeAnnotation(existing)
        existing.setLogicalBounds(newBounds)
        page.addAnnotation(existing)
        pdfView.setNeedsDisplay(pdfView.bounds)
    }

    /// Update a live line/arrow annotation's endpoints directly on the page.
    private func updateLiveLineEndpoints(id: UUID, start: CGPoint, end: CGPoint, page: PDFPage) {
        guard let pdfView = pdfView,
              let existing = liveShapeAnnotations[id] else { return }
        existing.page?.removeAnnotation(existing)
        existing.setLineEndpoints(start, end)
        page.addAnnotation(existing)
        pdfView.setNeedsDisplay(pdfView.bounds)
    }

    /// Compute new bounds for a resize drag.
    /// - Parameter aspectRatio: If provided, shift-constrain uses this width/height ratio
    ///   (e.g. the stamp's original image ratio) instead of 1:1.
    private func resizedBounds(startBounds: AnnotationBounds, corner: InteractionHandler.StampAction, currentPoint: CGPoint, aspectRatio: CGFloat? = nil) -> AnnotationBounds {
        let rect = startBounds.cgRect
        var newRect: CGRect
        let shiftHeld = NSEvent.modifierFlags.contains(.shift)
        let ar = aspectRatio ?? 1.0  // default to 1:1 for shapes/textboxes

        switch corner {
        case .resizeBottomLeft:
            var w = rect.maxX - currentPoint.x
            var h = rect.maxY - currentPoint.y
            if shiftHeld { constrainToAspectRatio(ar, w: &w, h: &h) }
            newRect = CGRect(x: rect.maxX - w, y: rect.maxY - h, width: w, height: h)
        case .resizeBottomRight:
            var w = currentPoint.x - rect.minX
            var h = rect.maxY - currentPoint.y
            if shiftHeld { constrainToAspectRatio(ar, w: &w, h: &h) }
            newRect = CGRect(x: rect.minX, y: rect.maxY - h, width: w, height: h)
        case .resizeTopLeft:
            var w = rect.maxX - currentPoint.x
            var h = currentPoint.y - rect.minY
            if shiftHeld { constrainToAspectRatio(ar, w: &w, h: &h) }
            newRect = CGRect(x: rect.maxX - w, y: rect.minY, width: w, height: h)
        case .resizeTopRight:
            var w = currentPoint.x - rect.minX
            var h = currentPoint.y - rect.minY
            if shiftHeld { constrainToAspectRatio(ar, w: &w, h: &h) }
            newRect = CGRect(x: rect.minX, y: rect.minY, width: w, height: h)
        case .resizeTop:
            newRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: currentPoint.y - rect.minY)
        case .resizeBottom:
            newRect = CGRect(x: rect.minX, y: currentPoint.y, width: rect.width, height: rect.maxY - currentPoint.y)
        case .resizeLeft:
            newRect = CGRect(x: currentPoint.x, y: rect.minY, width: rect.maxX - currentPoint.x, height: rect.height)
        case .resizeRight:
            newRect = CGRect(x: rect.minX, y: rect.minY, width: currentPoint.x - rect.minX, height: rect.height)
        case .drag, .dragLineStart, .dragLineEnd, .rotate:
            return startBounds
        }

        return AnnotationBounds(newRect.standardized)
    }

    /// Constrain w and h to the given aspect ratio (width/height), preserving signs.
    private func constrainToAspectRatio(_ ar: CGFloat, w: inout CGFloat, h: inout CGFloat) {
        // Use whichever dimension the user dragged further to drive the other
        if abs(w) / ar >= abs(h) {
            h = (h < 0 ? -1 : 1) * abs(w) / ar
        } else {
            w = (w < 0 ? -1 : 1) * abs(h) * ar
        }
    }

    /// Get the original image aspect ratio (width/height) for the stamp at the given index.
    private func stampAspectRatio(at index: Int) -> CGFloat {
        let stamp = viewModel.sidecar.stamps[index]
        if let image = stamp.image, image.size.height > 0 {
            return image.size.width / image.size.height
        }
        // Fallback to current bounds ratio
        let b = stamp.bounds
        return b.height > 0 ? b.width / b.height : 1.0
    }

    func handlePageMouseUp(page: PDFPage, point: CGPoint, pageIndex: Int) {
        // Finalize box selection drawing
        if boxSelectionStart != nil && viewModel.toolMode == .browse && viewModel.selectMode == .boxSelect {
            boxSelectionStart = nil
            if let rect = boxDrawingRect, let drawPage = boxDrawingPageIndex,
               rect.width >= 10, rect.height >= 10 {
                viewModel.boxSelectionRect = rect
                viewModel.boxSelectionPageIndex = drawPage
            }
            boxDrawingRect = nil
            boxDrawingPageIndex = nil
            syncBoxSelectionOverlay()
            return
        }

        // Finalize table selection — append drawn box to extractedTables
        if tableSelectionStart != nil && viewModel.toolMode == .tableSelect {
            tableSelectionStart = nil
            if let rect = tableDrawingRect, let drawPage = tableDrawingPageIndex,
               rect.width >= 10, rect.height >= 10 {
                let newTable = TableExtractionService.ExtractedTable(
                    cells: [], pageIndex: drawPage, bbox: rect,
                    colPositions: [], rowPositions: []
                )
                viewModel.extractedTables.append(newTable)
                viewModel.selectedTableBoxIndex = viewModel.extractedTables.count - 1
            }
            tableDrawingRect = nil
            tableDrawingPageIndex = nil
            syncTableSelectionOverlay()
            return
        }

        // Finalize shape creation — write final logical bounds from live annotation to sidecar
        if let shapeID = creatingShapeID {
            if let annotation = liveShapeAnnotations[shapeID] {
                let logicalBounds = annotation.logicalBounds_
                let isLine = (annotation.shapeType == .line || annotation.shapeType == .arrow)

                // For lines, check distance between endpoints instead of rect size
                let tooSmall: Bool
                if isLine, let ls = annotation.lineStart_, let le = annotation.lineEnd_ {
                    tooSmall = hypot(le.x - ls.x, le.y - ls.y) < 5
                } else {
                    tooSmall = logicalBounds.width < 5 && logicalBounds.height < 5
                }

                if tooSmall {
                    annotation.page?.removeAnnotation(annotation)
                    liveShapeAnnotations.removeValue(forKey: shapeID)
                    viewModel.sidecar.shapes.removeAll { $0.id == shapeID }
                    viewModel.selectedAnnotationID = nil
                } else {
                    if let idx = viewModel.sidecar.shapes.firstIndex(where: { $0.id == shapeID }) {
                        viewModel.sidecar.shapes[idx].bounds = AnnotationBounds(logicalBounds)
                        if isLine, let ls = annotation.lineStart_, let le = annotation.lineEnd_ {
                            viewModel.sidecar.shapes[idx].lineStart = QuadPoint(x: ls.x, y: ls.y)
                            viewModel.sidecar.shapes[idx].lineEnd = QuadPoint(x: le.x, y: le.y)
                        }
                    }
                }
            }
            shapeCreationStart = nil
            creatingShapeID = nil
        }

        // Finalize shape move/resize — write final logical bounds from live annotation to sidecar
        if let target = dragTarget {
            switch target {
            case .shape(let id, _, _), .shapeResize(let id, _, _),
                 .shapeRotate(let id),
                 .lineEndpointStart(let id), .lineEndpointEnd(let id):
                if let annotation = liveShapeAnnotations[id],
                   let idx = viewModel.sidecar.shapes.firstIndex(where: { $0.id == id }) {
                    viewModel.sidecar.shapes[idx].bounds = AnnotationBounds(annotation.logicalBounds_)
                    if let ls = annotation.lineStart_, let le = annotation.lineEnd_ {
                        viewModel.sidecar.shapes[idx].lineStart = QuadPoint(x: ls.x, y: ls.y)
                        viewModel.sidecar.shapes[idx].lineEnd = QuadPoint(x: le.x, y: le.y)
                    }
                }
            case .tableResize(let index, _, _), .tableMove(let index, _):
                // Mark cells and grid positions as stale so Preview re-extracts cleanly
                if index < viewModel.extractedTables.count {
                    viewModel.extractedTables[index].cells = []
                    viewModel.extractedTables[index].colPositions = []
                    viewModel.extractedTables[index].rowPositions = []
                }
            default:
                break
            }
        }

        // Register undo for the full drag if position actually changed
        if let oldSidecar = preDragSidecar, oldSidecar != viewModel.sidecar {
            viewModel.registerUndo { vm in
                vm.sidecar = oldSidecar
            }
        }
        dragTarget = nil
        preDragSidecar = nil
    }

    // MARK: - Markup Tools

    /// Called when the user finishes selecting text via native PDFView drag.
    func handleTextSelectionComplete() {
        guard let pdfView = pdfView,
              let selection = pdfView.currentSelection else { return }

        let markupType: MarkupType?
        switch viewModel.toolMode {
        case .highlight: markupType = .highlight
        case .underline: markupType = .underline
        case .strikethrough: markupType = .strikeOut
        default: markupType = nil
        }

        guard let type = markupType else { return }
        applyMarkup(type: type, from: selection)
        pdfView.clearSelection()
    }

    /// Called from updateNSView to apply markup if user switched to a markup tool with existing selection.
    func applyMarkupIfToolChanged() {
        defer { previousToolMode = viewModel.toolMode }

        guard previousToolMode != viewModel.toolMode else { return }
        guard let pdfView = pdfView,
              let selection = pdfView.currentSelection else { return }

        let markupType: MarkupType?
        switch viewModel.toolMode {
        case .highlight: markupType = .highlight
        case .underline: markupType = .underline
        case .strikethrough: markupType = .strikeOut
        default: markupType = nil
        }

        guard let type = markupType else { return }
        applyMarkup(type: type, from: selection)
        pdfView.clearSelection()
    }

    private func applyMarkup(type: MarkupType, from selection: PDFSelection) {
        guard let doc = pdfView?.document else { return }

        let lineSelections = selection.selectionsByLine()
        var markupsByPage: [Int: [[QuadPoint]]] = [:]

        for lineSelection in lineSelections {
            for page in lineSelection.pages {
                let pageIndex = doc.index(for: page)
                let bounds = lineSelection.bounds(for: page)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let quad: [QuadPoint] = [
                    QuadPoint(x: bounds.minX, y: bounds.minY),
                    QuadPoint(x: bounds.maxX, y: bounds.minY),
                    QuadPoint(x: bounds.maxX, y: bounds.maxY),
                    QuadPoint(x: bounds.minX, y: bounds.maxY)
                ]
                markupsByPage[pageIndex, default: []].append(quad)
            }
        }

        guard !markupsByPage.isEmpty else { return }

        let oldSidecar = viewModel.sidecar
        var updated = viewModel.sidecar

        let color: String
        switch type {
        case .highlight: color = viewModel.highlightColor.hex
        case .underline: color = "#FF0000"
        case .strikeOut: color = "#FF0000"
        }

        for (pageIndex, quads) in markupsByPage {
            let markup = MarkupAnnotationModel(
                pageIndex: pageIndex,
                type: type,
                quadrilateralPoints: quads,
                color: color
            )
            updated.markups.append(markup)
        }

        viewModel.sidecar = updated
        viewModel.registerUndo { vm in
            vm.sidecar = oldSidecar
        }
        syncAnnotations()
    }

    // MARK: - Annotation Sync

    /// Called from updateNSView — only syncs if revision actually changed.
    func syncAnnotationsIfNeeded(revision: Int) {
        guard revision != lastSyncedRevision else { return }
        lastSyncedRevision = revision
        applyOCROverlaysIfNeeded()
        syncAnnotations()
        syncBoxSelectionOverlay()
        syncTableSelectionOverlay()
    }

    /// Synchronize sidecar model annotations to live PDFAnnotation objects on pages.
    func syncAnnotations() {
        guard let pdfView = pdfView,
              let doc = pdfView.document else { return }

        lastSyncedRevision = viewModel.annotationRevision

        syncStamps(doc: doc)
        syncTextBoxes(doc: doc)
        syncComments(doc: doc)
        syncMarkups(doc: doc)
        syncShapes(doc: doc)

        // Reorder managed annotations on each page by drawOrder
        reorderAnnotationsByDrawOrder(doc: doc)

        pdfView.setNeedsDisplay(pdfView.bounds)
    }

    /// Reorder Spindrift-managed annotations on each page to match the drawOrder array.
    private func reorderAnnotationsByDrawOrder(doc: PDFDocument) {
        let drawOrder = viewModel.sidecar.drawOrder
        guard !drawOrder.isEmpty else { return }

        for pageIndex in 0..<doc.pageCount {
            guard let page = doc.page(at: pageIndex) else { continue }

            // Collect managed annotations (those with a spindrift tag in userName)
            var managed: [(annotation: PDFAnnotation, id: UUID)] = []
            var unmanaged: [PDFAnnotation] = []

            for annotation in page.annotations {
                if let userName = annotation.userName,
                   let (_, id) = SpindriftDocument.parseAnnotationTag(userName) {
                    managed.append((annotation, id))
                } else {
                    unmanaged.append(annotation)
                }
            }

            // Sort managed by drawOrder position (not in list = first / bottom)
            managed.sort { a, b in
                let ai = drawOrder.firstIndex(of: a.id) ?? -1
                let bi = drawOrder.firstIndex(of: b.id) ?? -1
                return ai < bi
            }

            // Remove and re-add in order
            for (annot, _) in managed {
                page.removeAnnotation(annot)
            }
            for (annot, _) in managed {
                page.addAnnotation(annot)
            }
        }
    }

    private func syncStamps(doc: PDFDocument) {
        let sidecarStamps = viewModel.sidecar.stamps
        let sidecarIDs = Set(sidecarStamps.map(\.id))
        let selectedID = viewModel.selectedAnnotationID

        for (id, annotation) in liveStampAnnotations {
            if !sidecarIDs.contains(id) {
                annotation.page?.removeAnnotation(annotation)
                liveStampAnnotations.removeValue(forKey: id)
            }
        }

        for stamp in sidecarStamps {
            let logicalRect = stamp.bounds.cgRect

            if let existing = liveStampAnnotations[stamp.id] {
                existing.stampOpacity = stamp.opacity
                existing.rotation_ = stamp.rotation
                existing.isSelected_ = (stamp.id == selectedID)
                existing.logicalBounds_ = logicalRect

                // Always remove/add to force PDFKit to re-call draw()
                existing.page?.removeAnnotation(existing)
                existing.recomputeBounds()
                if let page = doc.page(at: stamp.pageIndex) {
                    page.addAnnotation(existing)
                }
            } else {
                guard let image = stamp.image,
                      let page = doc.page(at: stamp.pageIndex) else { continue }
                let annotation = StampAnnotation(
                    stampID: stamp.id,
                    bounds: logicalRect,
                    image: image,
                    opacity: stamp.opacity,
                    rotation: stamp.rotation
                )
                annotation.isSelected_ = (stamp.id == selectedID)
                annotation.userName = SpindriftDocument.annotationTag(type: "stamp", id: stamp.id)
                page.addAnnotation(annotation)
                liveStampAnnotations[stamp.id] = annotation
            }
        }
    }

    private func syncTextBoxes(doc: PDFDocument) {
        let sidecarBoxes = viewModel.sidecar.textBoxes
        let sidecarIDs = Set(sidecarBoxes.map(\.id))
        let selectedID = viewModel.selectedAnnotationID

        for (id, annotation) in liveTextBoxAnnotations {
            if !sidecarIDs.contains(id) {
                annotation.page?.removeAnnotation(annotation)
                liveTextBoxAnnotations.removeValue(forKey: id)
            }
        }

        for textBox in sidecarBoxes {
            let bgColor = textBox.backgroundColor.flatMap { NSColor(hex: $0) }
            let olColor = textBox.outlineColor.flatMap { NSColor(hex: $0) }

            if let existing = liveTextBoxAnnotations[textBox.id] {
                // Skip updating text content on the annotation being edited inline
                if textBox.id != inlineEditingTextBoxID {
                    existing.update(
                        text: textBox.text,
                        fontName: textBox.fontName,
                        fontSize: textBox.fontSize,
                        textColor: NSColor(hex: textBox.color) ?? .black,
                        backgroundColor: bgColor,
                        outlineColor: olColor,
                        outlineStyle: textBox.outlineStyle,
                        rotation: textBox.rotation
                    )
                }
                existing.isSelected_ = (textBox.id == selectedID)
                let logicalRect = textBox.bounds.cgRect
                let padding: CGFloat = 30
                if existing.logicalBounds_ != logicalRect || existing.rotation_ != textBox.rotation {
                    existing.page?.removeAnnotation(existing)
                    existing.logicalBounds_ = logicalRect
                    existing.rotation_ = textBox.rotation
                    existing.bounds = logicalRect.insetBy(dx: -padding, dy: -padding)
                    if let page = doc.page(at: textBox.pageIndex) {
                        page.addAnnotation(existing)
                    }
                }
            } else {
                guard let page = doc.page(at: textBox.pageIndex) else { continue }
                let annotation = TextBoxAnnotation(
                    textBoxID: textBox.id,
                    bounds: textBox.bounds.cgRect,
                    text: textBox.text,
                    fontName: textBox.fontName,
                    fontSize: textBox.fontSize,
                    textColor: NSColor(hex: textBox.color) ?? .black,
                    backgroundColor: bgColor,
                    outlineColor: olColor,
                    outlineStyle: textBox.outlineStyle,
                    rotation: textBox.rotation
                )
                annotation.isSelected_ = (textBox.id == selectedID)
                annotation.userName = SpindriftDocument.annotationTag(type: "textbox", id: textBox.id)
                page.addAnnotation(annotation)
                liveTextBoxAnnotations[textBox.id] = annotation
            }
        }
    }

    private func syncComments(doc: PDFDocument) {
        let sidecarComments = viewModel.sidecar.comments
        let sidecarIDs = Set(sidecarComments.map(\.id))
        let selectedID = viewModel.selectedAnnotationID

        for (id, annotation) in liveCommentAnnotations {
            if !sidecarIDs.contains(id) {
                annotation.page?.removeAnnotation(annotation)
                liveCommentAnnotations.removeValue(forKey: id)
            }
        }

        for comment in sidecarComments {
            if let existing = liveCommentAnnotations[comment.id] {
                existing.contents = comment.text
                existing.isSelected = (comment.id == selectedID)
                // Update position if changed (during drag)
                if existing.bounds != comment.bounds.cgRect {
                    existing.page?.removeAnnotation(existing)
                    existing.bounds = comment.bounds.cgRect
                    if let page = doc.page(at: comment.pageIndex) {
                        page.addAnnotation(existing)
                    }
                }
            } else {
                guard let page = doc.page(at: comment.pageIndex) else { continue }
                let annotation = CommentAnnotation(
                    commentID: comment.id,
                    bounds: comment.bounds.cgRect
                )
                annotation.contents = comment.text
                annotation.userName = SpindriftDocument.annotationTag(type: "comment", id: comment.id)
                annotation.isSelected = (comment.id == selectedID)
                page.addAnnotation(annotation)
                liveCommentAnnotations[comment.id] = annotation
            }
        }
    }

    private func syncMarkups(doc: PDFDocument) {
        let sidecarMarkups = viewModel.sidecar.markups
        let sidecarIDs = Set(sidecarMarkups.map(\.id))

        // Remove annotations for deleted markups
        for (id, annotation) in liveMarkupAnnotations {
            if !sidecarIDs.contains(id) {
                annotation.page?.removeAnnotation(annotation)
                liveMarkupAnnotations.removeValue(forKey: id)
            }
        }

        // Add new markups (markups don't change after creation)
        for markup in sidecarMarkups {
            if liveMarkupAnnotations[markup.id] != nil { continue }
            guard let page = doc.page(at: markup.pageIndex) else { continue }

            // For strikethrough, use custom drawing since PDFKit's .strikeOut
            // doesn't render reliably on all macOS versions
            let annotation: PDFAnnotation
            if markup.type == .strikeOut {
                annotation = StrikeOutAnnotation(
                    markupID: markup.id,
                    bounds: markup.boundingRect,
                    quads: markup.quadrilateralPoints,
                    color: NSColor(hex: markup.color) ?? .red
                )
            } else {
                annotation = PDFAnnotation(
                    bounds: markup.boundingRect,
                    forType: markup.pdfAnnotationSubtype,
                    withProperties: nil
                )
                annotation.color = NSColor(hex: markup.color) ?? .yellow

                var nsQuadPoints: [[NSValue]] = []
                for quad in markup.quadrilateralPoints {
                    guard quad.count == 4 else { continue }
                    let values = quad.map { NSValue(point: NSPoint(x: $0.x, y: $0.y)) }
                    nsQuadPoints.append(values)
                }
                let flatPoints = nsQuadPoints.flatMap { $0 }
                annotation.setValue(flatPoints, forAnnotationKey: .quadPoints)
            }
            annotation.userName = SpindriftDocument.annotationTag(type: "markup", id: markup.id)
            page.addAnnotation(annotation)
            liveMarkupAnnotations[markup.id] = annotation
        }
    }

    private func syncShapes(doc: PDFDocument) {
        let sidecarShapes = viewModel.sidecar.shapes
        let sidecarIDs = Set(sidecarShapes.map(\.id))
        let selectedID = viewModel.selectedAnnotationID

        for (id, annotation) in liveShapeAnnotations {
            if !sidecarIDs.contains(id) {
                annotation.page?.removeAnnotation(annotation)
                liveShapeAnnotations.removeValue(forKey: id)
            }
        }

        for shape in sidecarShapes {
            let strokeColor = NSColor(hex: shape.strokeColor) ?? .black
            let fillColor = shape.fillColor.flatMap { NSColor(hex: $0) }
            let logicalRect = shape.bounds.cgRect
            let lineStart = shape.lineStart.map { CGPoint(x: $0.x, y: $0.y) }
            let lineEnd = shape.lineEnd.map { CGPoint(x: $0.x, y: $0.y) }

            if let existing = liveShapeAnnotations[shape.id] {
                existing.update(
                    shapeType: shape.shapeType,
                    strokeColor: strokeColor,
                    fillColor: fillColor,
                    strokeWidth: shape.strokeWidth,
                    strokeStyle: shape.strokeStyle,
                    rotation: shape.rotation,
                    lineStart: lineStart,
                    lineEnd: lineEnd
                )
                existing.isSelected_ = (shape.id == selectedID)
                existing.logicalBounds_ = logicalRect

                // Always remove/add to force PDFKit to re-call draw().
                // PDFKit caches annotation rendering and won't redraw for
                // property-only changes without this.
                existing.page?.removeAnnotation(existing)
                existing.recomputeBounds()
                if let page = doc.page(at: shape.pageIndex) {
                    page.addAnnotation(existing)
                }
            } else {
                guard let page = doc.page(at: shape.pageIndex) else { continue }
                let annotation = ShapeAnnotation(
                    shapeID: shape.id,
                    bounds: logicalRect,
                    shapeType: shape.shapeType,
                    strokeColor: strokeColor,
                    fillColor: fillColor,
                    strokeWidth: shape.strokeWidth,
                    strokeStyle: shape.strokeStyle,
                    rotation: shape.rotation,
                    lineStart: lineStart,
                    lineEnd: lineEnd
                )
                annotation.isSelected_ = (shape.id == selectedID)
                annotation.userName = SpindriftDocument.annotationTag(type: "shape", id: shape.id)
                page.addAnnotation(annotation)
                liveShapeAnnotations[shape.id] = annotation
            }
        }
    }

    /// Apply OCR invisible text overlays when OCR results change.
    /// This replaces pages in the document with versions containing embedded invisible text,
    /// making the text natively selectable and searchable by PDFKit.
    private func applyOCROverlaysIfNeeded() {
        let currentOCR = viewModel.sidecar.ocrResults
        guard currentOCR != lastOverlaidOCR else { return }
        guard let pdfView = pdfView, let doc = pdfView.document else { return }
        guard !currentOCR.isEmpty else {
            lastOverlaidOCR = currentOCR
            return
        }

        // Clear live annotation dictionaries — page replacement orphans them.
        // syncAnnotations() will re-create them on the new pages.
        clearLiveAnnotations(in: doc)

        OCRService.applyOCROverlays(to: doc, ocrResults: currentOCR, originalPages: &originalPages)
        lastOverlaidOCR = currentOCR
    }

    /// Remove all live annotations from their pages and clear the tracking dictionaries.
    private func clearLiveAnnotations(in doc: PDFDocument) {
        for (_, annotation) in liveStampAnnotations { annotation.page?.removeAnnotation(annotation) }
        liveStampAnnotations.removeAll()

        for (_, annotation) in liveTextBoxAnnotations { annotation.page?.removeAnnotation(annotation) }
        liveTextBoxAnnotations.removeAll()

        for (_, annotation) in liveCommentAnnotations { annotation.page?.removeAnnotation(annotation) }
        liveCommentAnnotations.removeAll()

        for (_, annotation) in liveMarkupAnnotations { annotation.page?.removeAnnotation(annotation) }
        liveMarkupAnnotations.removeAll()

        for (_, annotation) in liveShapeAnnotations { annotation.page?.removeAnnotation(annotation) }
        liveShapeAnnotations.removeAll()
    }

    // MARK: - Copy Key Handling

    /// Handle Cmd+C. Returns true if consumed (box selection copied), false to let native copy work.
    func handleCopyKey() -> Bool {
        guard viewModel.hasBoxSelection else { return false }
        viewModel.copyBoxSelectionToClipboard()
        return true
    }

    // MARK: - Box Selection Overlay

    /// Synchronize the box selection overlay annotation with the current selection state.
    func syncBoxSelectionOverlay() {
        // Remove existing overlay
        if let existing = liveBoxSelectionAnnotation {
            existing.page?.removeAnnotation(existing)
            liveBoxSelectionAnnotation = nil
        }

        guard let pdfView = pdfView,
              let doc = pdfView.document else { return }

        // Show the in-progress drawing rect (mid-drag)
        if let rect = boxDrawingRect, let drawPage = boxDrawingPageIndex,
           drawPage < doc.pageCount, let page = doc.page(at: drawPage) {
            let annotation = BoxSelectionAnnotation(bounds: rect)
            page.addAnnotation(annotation)
            liveBoxSelectionAnnotation = annotation
        }
        // Show the committed box selection
        else if let rect = viewModel.boxSelectionRect,
                let pageIdx = viewModel.boxSelectionPageIndex,
                pageIdx < doc.pageCount, let page = doc.page(at: pageIdx) {
            let annotation = BoxSelectionAnnotation(bounds: rect)
            page.addAnnotation(annotation)
            liveBoxSelectionAnnotation = annotation
        }

        pdfView.setNeedsDisplay(pdfView.bounds)
    }

    // MARK: - Table Selection Overlay

    /// Synchronize table selection overlay annotations with the current selection state.
    /// In manual mode, the drawn rectangle is replicated to all pages in scope.
    /// In autodetect mode, detected table boxes are shown on all their respective pages.
    func syncTableSelectionOverlay() {
        removeTableSelectionAnnotations()

        guard let pdfView = pdfView,
              let doc = pdfView.document else { return }

        // Show the in-progress drawing rect (mid-drag)
        if let rect = tableDrawingRect, let drawPage = tableDrawingPageIndex {
            if drawPage < doc.pageCount, let page = doc.page(at: drawPage) {
                let annotation = TableSelectionAnnotation(bounds: rect, isAutoDetected: false)
                page.addAnnotation(annotation)
                liveTableSelectionAnnotations.append(annotation)
            }
        }

        // Show table regions on their respective pages
        for (i, table) in viewModel.extractedTables.enumerated() {
            guard table.pageIndex < doc.pageCount,
                  let page = doc.page(at: table.pageIndex) else { continue }
            let isSelected = (viewModel.selectedTableBoxIndex == i)
            let annotation = TableSelectionAnnotation(bounds: table.bbox, isAutoDetected: true, isSelected: isSelected)
            page.addAnnotation(annotation)
            liveTableSelectionAnnotations.append(annotation)
        }

        pdfView.setNeedsDisplay(pdfView.bounds)
    }

    /// Remove all table selection overlay annotations from pages.
    private func removeTableSelectionAnnotations() {
        for annotation in liveTableSelectionAnnotations {
            annotation.page?.removeAnnotation(annotation)
        }
        liveTableSelectionAnnotations.removeAll()
    }
}
