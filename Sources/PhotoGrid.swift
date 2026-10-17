import AppKit
import AVFoundation
import Combine
import ImageIO
import UniformTypeIdentifiers

// MARK: - Photo grid (lives inside the menu)

final class PhotosMenuView: NSView {
    private static let width: CGFloat = 300
    private static let pad: CGFloat = 14
    private static let cell: CGFloat = 84
    private static let gap: CGFloat = 8
    private static let gridHeight: CGFloat = 3 * cell + 2 * gap + 12  // 3 rows, then scroll

    private let server = Controller.shared
    private let scopeControl = NSSegmentedControl(labels: ["This session", "All photos"],
                                                  trackingMode: .selectOne, target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private let folderButton = NSButton()
    private let scroll = NSScrollView()
    private let grid = FlippedView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let hint = NSTextField(labelWithString: "Drag to copy · double-click to open")
    private var shownIDs: [String] = []
    private var bag = Set<AnyCancellable>()

    override var isFlipped: Bool { true }

    init() {
        let pad = Self.pad, w = Self.width
        let height = pad / 2 + 24 + 10 + Self.gridHeight + 6 + 14 + pad / 2
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: height))

        scopeControl.selectedSegment = UserDefaults.standard.integer(forKey: "photoScopeIndex")
        scopeControl.target = self
        scopeControl.action = #selector(scopeChanged)
        scopeControl.controlSize = .regular
        scopeControl.frame = NSRect(x: pad, y: pad / 2, width: 200, height: 24)

        countLabel.alignment = .right
        countLabel.textColor = .secondaryLabelColor
        countLabel.frame = NSRect(x: pad + 204, y: pad / 2 + 4, width: 36, height: 16)

        folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Open folder")
        folderButton.isBordered = false
        folderButton.toolTip = "Show the folder in Finder"
        folderButton.target = self
        folderButton.action = #selector(openFolder)
        folderButton.frame = NSRect(x: w - pad - 24, y: pad / 2, width: 24, height: 24)

        let gridTop = pad / 2 + 24 + 10
        scroll.frame = NSRect(x: pad, y: gridTop, width: w - 2 * pad, height: Self.gridHeight)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = grid

        emptyLabel.alignment = .center
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: 11)
        emptyLabel.frame = NSRect(x: pad, y: gridTop + Self.gridHeight / 2 - 20, width: w - 2 * pad, height: 40)

        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 10)
        hint.frame = NSRect(x: pad, y: gridTop + Self.gridHeight + 6, width: w - 2 * pad, height: 14)

        [scopeControl, countLabel, folderButton, scroll, emptyLabel, hint].forEach(addSubview)

        server.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.reload() } }
            .store(in: &bag)
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func scopeChanged() {
        UserDefaults.standard.set(scopeControl.selectedSegment, forKey: "photoScopeIndex")
        reload()
        grid.scroll(.zero)
    }

    @objc private func openFolder() {
        enclosingMenuItem?.menu?.cancelTracking()
        NSWorkspace.shared.open(server.folder)
    }

    func reload() {
        let sessionScope = scopeControl.selectedSegment == 0
        let photos = sessionScope ? server.sessionPhotos : server.allPhotos
        countLabel.stringValue = "\(photos.count)"

        emptyLabel.isHidden = !photos.isEmpty
        hint.isHidden = photos.isEmpty
        emptyLabel.stringValue = !sessionScope ? "Nothing in \(server.folder.lastPathComponent) yet."
            : server.isRunning ? "Photos and videos you send appear here.\nDrag them onto the desktop or into any app."
            : "Start the server, then send photos or videos\nfrom the iPhone. They'll appear here."

        let ids = photos.map(\.cacheKey)
        guard ids != shownIDs else { return }
        shownIDs = ids

        grid.subviews.forEach { $0.removeFromSuperview() }
        let cols = 3, step = Self.cell + Self.gap
        for (i, photo) in photos.enumerated() {
            let thumb = ThumbView(photo: photo)
            thumb.frame = NSRect(x: CGFloat(i % cols) * step, y: CGFloat(i / cols) * step,
                                 width: Self.cell, height: Self.cell)
            grid.addSubview(thumb)
        }
        let rows = (photos.count + cols - 1) / cols
        grid.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width,
                            height: max(CGFloat(rows) * step - Self.gap, scroll.contentSize.height))
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One thumbnail: drag it out to copy the file, double-click to open it.
final class ThumbView: NSView, NSDraggingSource {
    let photo: Photo
    private var mouseDownEvent: NSEvent?

    init(photo: Photo) {
        self.photo = photo
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.contentsGravity = .resizeAspectFill
        toolTip = photo.url.lastPathComponent
        ThumbnailCache.shared.load(photo) { [weak self] thumb in
            self?.layer?.contents = thumb.image
            if let duration = thumb.videoDuration { self?.addVideoBadge(duration) }
        }
    }

    /// "▶ 0:12" in the bottom-left corner of video thumbnails.
    private func addVideoBadge(_ seconds: Double) {
        let total = Int(seconds.rounded())
        let label = NSTextField(labelWithString: String(format: "▶ %d:%02d", total / 60, total % 60))
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        label.layer?.cornerRadius = 3
        label.sizeToFit()
        label.frame = NSRect(x: 4, y: 4, width: label.frame.width + 6, height: label.frame.height)
        label.alignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            enclosingMenuItem?.menu?.cancelTracking()
            NSWorkspace.shared.open(photo.url)
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 3 else { return }
        mouseDownEvent = nil

        let item = NSDraggingItem(pasteboardWriter: photo.url as NSURL)
        let image = (layer?.contents as? NSImage) ?? NSWorkspace.shared.icon(forFile: photo.url.path)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy  // never move the original out of the folder
    }
}

/// Thumbnails are made off the main thread and cached by file path + size + date.
/// Videos get a frame from about a second in, plus their length.
final class Thumbnail {
    let image: NSImage
    let videoDuration: Double?
    init(image: NSImage, videoDuration: Double?) {
        self.image = image
        self.videoDuration = videoDuration
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private static let maxPixels: CGFloat = 240
    private let cache = NSCache<NSString, Thumbnail>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    func load(_ photo: Photo, completion: @escaping (Thumbnail) -> Void) {
        let key = photo.cacheKey as NSString
        if let hit = cache.object(forKey: key) { return completion(hit) }
        let url = photo.url
        queue.addOperation { [cache] in
            let made = Self.isVideo(url) ? Self.videoThumbnail(url) : Self.imageThumbnail(url)
            if let made { cache.setObject(made, forKey: key) }
            let thumb = made ?? Thumbnail(image: NSWorkspace.shared.icon(forFile: url.path), videoDuration: nil)
            DispatchQueue.main.async { completion(thumb) }
        }
    }

    static func isVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) ?? false
    }

    private static func imageThumbnail(_ url: URL) -> Thumbnail? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return Thumbnail(image: NSImage(cgImage: cg, size: .zero), videoDuration: nil)
    }

    /// Runs on the thumbnail queue, so it's fine to wait for AVFoundation here.
    private static func videoThumbnail(_ url: URL) -> Thumbnail? {
        let asset = AVURLAsset(url: url)
        let done = DispatchSemaphore(value: 0)
        var duration: Double?
        var frame: CGImage?

        Task.detached {
            if let d = try? await asset.load(.duration), d.isNumeric { duration = d.seconds }
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: maxPixels, height: maxPixels)
            let at = CMTime(seconds: min(1, (duration ?? 0) / 2), preferredTimescale: 600)
            frame = try? await gen.image(at: at).image
            done.signal()
        }
        done.wait()

        guard let frame else { return nil }
        return Thumbnail(image: NSImage(cgImage: frame, size: .zero), videoDuration: duration)
    }
}
