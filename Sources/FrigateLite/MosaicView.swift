import AppKit
import QuartzCore

/// CALayer without implicit animations. Default layers cross-fade every `contents` change
/// for 0.25 s, which would make the window server redraw at full refresh rate. We never want that.
class PlainLayer: CALayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

final class PlainTextLayer: CATextLayer {
    override func action(forKey event: String) -> CAAction? { nil }
}

enum TileUpdate {
    case image(CGImage, offline: Bool)
    case failed(String)
}

/// All camera tiles live in one layer tree inside one view. New frames for every visible
/// camera are applied in a single CATransaction, so the window server composites (and
/// DisplayLink re-encodes) the window once per tick instead of once per camera per frame.
/// Nothing in this view animates or draws between ticks.
@MainActor
final class MosaicView: NSView {
    var onSelect: ((String?) -> Void)?
    var onKey: ((NSEvent) -> Bool)?

    var showLabels = true { didSet { if showLabels != oldValue { relayout() } } }

    private(set) var order: [String] = []
    private(set) var focused: String?
    private var tiles: [String: Tile] = [:]
    private let message = PlainTextLayer()
    private let gap: CGFloat = 2

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.backgroundColor = NSColor.black.cgColor
        message.isWrapped = true
        message.alignmentMode = .center
        message.isHidden = true
        layer?.addSublayer(message)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    // MARK: Content

    /// Sets the cameras shown in the grid, in display order. Existing tiles keep their last image.
    func setCameras(_ cameras: [Camera]) {
        let names = Set(cameras.map(\.name))
        for (name, tile) in tiles where !names.contains(name) {
            tile.root.removeFromSuperlayer()
            tiles[name] = nil
        }
        for camera in cameras where tiles[camera.name] == nil {
            let tile = Tile(camera: camera)
            layer?.insertSublayer(tile.root, below: message)
            tiles[camera.name] = tile
        }
        order = cameras.map(\.name)
        if let f = focused, tiles[f] == nil { focused = nil }
        relayout()
    }

    func setFocus(_ name: String?) {
        focused = name.flatMap { tiles[$0] == nil ? nil : $0 }
        relayout()
    }

    func showMessage(_ text: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let text {
            message.string = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor(white: 0.75, alpha: 1),
            ])
            message.isHidden = false
            layoutMessage()
        } else {
            message.isHidden = true
        }
        CATransaction.commit()
    }

    /// Applies one tick's worth of frames in a single commit.
    func apply(_ updates: [String: TileUpdate]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (name, update) in updates { tiles[name]?.apply(update) }
        CATransaction.commit()
    }

    /// Pixel height to request from Frigate for a camera, matched to its on-screen size.
    func pixelHeight(for name: String) -> Int {
        guard let tile = tiles[name] else { return 360 }
        let h = Int((tile.root.bounds.height * scale).rounded(.up))
        let cap = tile.camera.height > 0 ? tile.camera.height : 1080
        // Round to 10 px so window resizes don't produce endless distinct sizes.
        return min(cap, max(90, (h + 9) / 10 * 10))
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout()
    }

    private func relayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let s = scale
        message.contentsScale = s
        layoutMessage()

        let bounds = self.bounds
        for tile in tiles.values { tile.root.isHidden = true }

        if let f = focused, let tile = tiles[f] {
            tile.root.isHidden = false
            tile.root.frame = Self.fit(aspect: tile.camera.aspect, in: bounds).integral
            tile.layoutContents(showLabel: showLabels, scale: s)
            return
        }

        let visible = order.compactMap { tiles[$0] }
        let n = visible.count
        guard n > 0, bounds.width > 10, bounds.height > 10 else { return }

        let aspects = visible.map(\.camera.aspect).sorted()
        let cellAspect = aspects[aspects.count / 2]
        let (cols, rows, cell) = bestGrid(count: n, in: bounds.size, aspect: cellAspect)
        let totalHeight = CGFloat(rows) * cell.height + CGFloat(rows - 1) * gap
        let top = bounds.midY + totalHeight / 2 // layer coordinates have their origin bottom-left

        for (i, tile) in visible.enumerated() {
            let row = i / cols, col = i % cols
            let inRow = min(cols, n - row * cols) // centre a partly filled last row
            let rowWidth = CGFloat(inRow) * cell.width + CGFloat(inRow - 1) * gap
            let x = bounds.midX - rowWidth / 2 + CGFloat(col) * (cell.width + gap)
            let y = top - CGFloat(row + 1) * cell.height - CGFloat(row) * gap
            let cellRect = CGRect(x: x, y: y, width: cell.width, height: cell.height)
            tile.root.isHidden = false
            tile.root.frame = Self.fit(aspect: tile.camera.aspect, in: cellRect).integral
            tile.layoutContents(showLabel: showLabels, scale: s)
        }
    }

    /// Column count that makes tiles as large as possible for this window shape.
    private func bestGrid(count n: Int, in size: CGSize, aspect: CGFloat) -> (Int, Int, CGSize) {
        var best = (cols: 1, rows: n, cell: CGSize.zero)
        for cols in 1...n {
            let rows = (n + cols - 1) / cols
            let maxW = (size.width - CGFloat(cols - 1) * gap) / CGFloat(cols)
            let maxH = (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            var w = maxW, h = maxW / aspect
            if h > maxH { h = maxH; w = h * aspect }
            if w * h > best.cell.width * best.cell.height { best = (cols, rows, CGSize(width: w, height: h)) }
        }
        return best
    }

    private static func fit(aspect: CGFloat, in rect: CGRect) -> CGRect {
        var w = rect.width, h = rect.width / aspect
        if h > rect.height { h = rect.height; w = h * aspect }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private func layoutMessage() {
        guard !message.isHidden, let text = message.string as? NSAttributedString else { return }
        let width = min(bounds.width - 40, 560)
        let rect = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        let h = ceil(rect.height) + 4
        message.frame = CGRect(x: bounds.midX - width / 2, y: bounds.midY - h / 2, width: width, height: h)
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        if focused != nil {
            onSelect?(nil)
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if let name = order.first(where: { tiles[$0].map { !$0.root.isHidden && $0.root.frame.contains(p) } ?? false }) {
            onSelect?(name)
        }
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// One camera: the image is the root layer's contents, with a name label and a status dot on top.
@MainActor
private final class Tile {
    let camera: Camera
    let root = PlainLayer()
    private let labelBox = PlainLayer()
    private let label = PlainTextLayer()
    private let dot = PlainLayer()
    private let note = PlainTextLayer()
    private var hasImage = false

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    init(camera: Camera) {
        self.camera = camera
        root.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        root.contentsGravity = .resizeAspect
        root.masksToBounds = true

        labelBox.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        labelBox.cornerRadius = 4
        label.string = NSAttributedString(string: camera.title, attributes: [
            .font: Self.labelFont, .foregroundColor: NSColor(white: 1, alpha: 0.9),
        ])
        labelBox.addSublayer(label)

        dot.cornerRadius = 4
        dot.isHidden = true
        dot.borderColor = NSColor(white: 0, alpha: 0.6).cgColor
        dot.borderWidth = 1

        note.isWrapped = true
        note.alignmentMode = .center
        note.string = NSAttributedString(string: "Waiting for first frame…", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.6, alpha: 1),
        ])

        root.addSublayer(note)
        root.addSublayer(labelBox)
        root.addSublayer(dot)
    }

    func apply(_ update: TileUpdate) {
        switch update {
        case .image(let image, let offline):
            root.contents = image
            hasImage = true
            note.isHidden = true
            setDot(offline ? .systemOrange : nil)
        case .failed(let reason):
            setDot(.systemRed)
            if !hasImage {
                note.string = NSAttributedString(string: reason, attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.6, alpha: 1),
                ])
                note.isHidden = false
            }
        }
    }

    private func setDot(_ color: NSColor?) {
        dot.isHidden = color == nil
        if let color { dot.backgroundColor = color.cgColor }
    }

    func layoutContents(showLabel: Bool, scale: CGFloat) {
        let b = root.bounds
        label.contentsScale = scale
        note.contentsScale = scale

        labelBox.isHidden = !showLabel
        let textSize = (label.string as? NSAttributedString)?.size() ?? .zero
        let boxW = min(ceil(textSize.width) + 12, max(0, b.width - 12))
        let boxH = ceil(textSize.height) + 4
        labelBox.frame = CGRect(x: 6, y: b.height - boxH - 6, width: boxW, height: boxH)
        label.frame = CGRect(x: 6, y: 2, width: boxW - 12, height: boxH - 4)
        label.truncationMode = .end

        dot.frame = CGRect(x: b.width - 14, y: b.height - 14, width: 8, height: 8)

        let noteW = max(0, b.width - 24)
        let noteH = max(0, min(84, b.height - 40)) // room for a wrapped error message
        note.frame = CGRect(x: 12, y: b.midY - noteH / 2, width: noteW, height: noteH)
    }
}
