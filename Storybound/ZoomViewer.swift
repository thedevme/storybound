import SwiftUI
import AppKit
import AVKit

// MARK: - Full-screen pictures you can zoom into

/// Whether the full-screen picture is zoomed in, so Esc can go back to the whole picture before it closes the viewer.
final class ZoomState: ObservableObject {
    static let shared = ZoomState()
    @Published var zoomed = false
    var reset: () -> Void = {}
}

/// A picture at full resolution that fits the window: scroll (any wheel, trackpad or Magic Mouse) or pinch zooms toward
/// the pointer, drag pans (so does Shift-scroll), double-click toggles fit and 2×. `compose` draws on top of the
/// full-size picture first (the trailer's logo and title line), so what you zoom into is exactly what the card shows.
/// `render` makes the picture itself when it isn't one file (the montage's panels).
struct ZoomableImage: NSViewRepresentable {
    let url: URL?
    var crop: [Double]? = nil
    var compose: ((CGImage) -> CGImage)? = nil
    var render: (() -> CGImage?)? = nil
    var key: String = ""          // what's drawn on it; changes only when that does
    var version = 0               // the store's imageVersion: makes SwiftUI re-check the file. It never reloads by itself
    var spacePan = false          // hold the spacebar to pan: drag anywhere, or scroll

    func makeNSView(context: Context) -> ZoomScrollView { ZoomScrollView() }
    func updateNSView(_ v: ZoomScrollView, context: Context) {
        v.spacePan = spacePan
        // the file's own date is in the key: a zoom stays put unless this picture really changes
        // (read fresh each time: a URL remembers its resource values)
        let stamp = url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }?.timeIntervalSince1970 ?? 0
        let k = "\(url?.path ?? "")|\(stamp)|\(crop ?? [])|\(key)"
        guard v.loadedKey != k else { return }
        v.loadedKey = k
        guard url != nil || render != nil else { v.setImage(nil); return }
        let (u, c, comp, make) = (url, crop, compose, render)
        Task.detached(priority: .userInitiated) {
            var cg = make?() ?? u.flatMap { PictureCache.load($0, crop: c, maxPixel: nil) }
            if let base = cg, let comp { cg = comp(base) }
            let done = cg
            await MainActor.run { if v.loadedKey == k { v.setImage(done) } }
        }
    }
    static func dismantleNSView(_ v: ZoomScrollView, coordinator: ()) {
        // the viewer is gone: Esc must not go on "resetting" a picture that's no longer there
        ZoomState.shared.reset = {}
        if ZoomState.shared.zoomed { ZoomState.shared.zoomed = false }
    }
}

final class ZoomScrollView: NSScrollView {
    var loadedKey = ""
    private let imageView = DragImageView()
    private var imageSize = CGSize(width: 16, height: 9)
    var spacePan = false
    private var spaceHeld = false
    private var grabbing = false
    private var monitor: Any?

    // MARK: hold the spacebar to pan
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        endSpace()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in self?.handle(e) ?? e }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.endSpace() }
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    private func endSpace() {
        if spaceHeld { NSCursor.pop() }
        spaceHeld = false; grabbing = false
    }
    private func handle(_ e: NSEvent) -> NSEvent? {
        guard spacePan, e.window === window, window?.attachedSheet == nil else { return e }
        switch e.type {
        case .keyDown where e.keyCode == 49:
            if window?.firstResponder is NSText { return e }       // typing a space in the prompt or search box
            if !spaceHeld { spaceHeld = true; NSCursor.openHand.push() }
            return nil
        case .keyUp where e.keyCode == 49:
            guard spaceHeld else { return e }
            endSpace(); return nil
        case .leftMouseDown where spaceHeld:
            guard bounds.contains(convert(e.locationInWindow, from: nil)) else { return e }
            grabbing = true; NSCursor.closedHand.set(); return nil
        case .leftMouseDragged where grabbing:
            imageView.pan(dx: e.deltaX, dy: e.deltaY); return nil
        case .leftMouseUp where grabbing:
            grabbing = false; NSCursor.openHand.set(); return nil
        default: return e
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        drawsBackground = false
        hasHorizontalScroller = false; hasVerticalScroller = false
        allowsMagnification = true; minMagnification = 1; maxMagnification = 8
        contentView = CenteringClipView()
        contentView.drawsBackground = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        documentView = imageView
        imageView.onDoubleClick = { [weak self] p in self?.toggle(at: p) }
        NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main) { [weak self] _ in self?.publish() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ cg: CGImage?) {
        imageView.image = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        imageSize = cg.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 16, height: 9)
        magnification = 1; fit(); publish()
        ZoomState.shared.reset = { [weak self] in self?.animator().magnification = 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.publish() } }
    }
    /// The document is the picture fitted to the window; magnification 1 is "fit".
    private func fit() {
        let b = bounds.size
        guard b.width > 0, b.height > 0 else { return }
        let s = min(b.width / imageSize.width, b.height / imageSize.height)
        imageView.frame = NSRect(x: 0, y: 0, width: imageSize.width * s, height: imageSize.height * s)
    }
    override func layout() { let m = magnification; super.layout(); if m <= 1.001 { fit() } }
    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); if magnification <= 1.001 { fit() } }

    /// Scrolling zooms toward the pointer on every device: wheel, trackpad, Magic Mouse. Shift-scroll pans instead.
    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.shift) || spaceHeld { super.scrollWheel(with: e); return }
        // no drifting on after the fingers lift
        if !e.momentumPhase.isEmpty { return }
        // away from you zooms in, whichever way "natural scrolling" is set
        let dy = Double(e.scrollingDeltaY) * (e.isDirectionInvertedFromDevice ? -1 : 1)
        guard dy != 0 else { return }
        let f = e.hasPreciseScrollingDeltas ? pow(1.006, dy) : pow(1.15, dy)
        setMagnification(min(maxMagnification, max(1, magnification * f)), centeredAt: imageView.convert(e.locationInWindow, from: nil))
        publish()
    }
    private func toggle(at p: NSPoint) {
        if magnification > 1.01 { animator().magnification = 1 } else { animator().setMagnification(2, centeredAt: p) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.publish() }
    }
    private func publish() { let z = magnification > 1.01; if ZoomState.shared.zoomed != z { ZoomState.shared.zoomed = z } }
}

/// Drag to pan, double-click to zoom.
final class DragImageView: NSImageView {
    var onDoubleClick: (NSPoint) -> Void = { _ in }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onDoubleClick(convert(e.locationInWindow, from: nil)) }
    }
    override func mouseDragged(with e: NSEvent) { pan(dx: e.deltaX, dy: e.deltaY) }
    func pan(dx: CGFloat, dy: CGFloat) {
        guard let sv = enclosingScrollView else { return }
        var o = sv.contentView.bounds.origin
        o.x -= dx / sv.magnification; o.y += (isFlipped ? -1 : 1) * dy / sv.magnification
        sv.contentView.scroll(to: sv.contentView.constrainBoundsRect(NSRect(origin: o, size: sv.contentView.bounds.size)).origin)
        sv.reflectScrolledClipView(sv.contentView)
    }
    override var acceptsFirstResponder: Bool { true }
}

/// Keeps the fitted picture in the middle of the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let d = documentView else { return r }
        if r.width > d.frame.width { r.origin.x = (d.frame.width - r.width) / 2 }
        if r.height > d.frame.height { r.origin.y = (d.frame.height - r.height) / 2 }
        return r
    }
}

/// The controls on every full-screen picture: Fit (when zoomed), Show in Finder, and close.
struct ViewerControls: View {
    @ObservedObject var zoom = ZoomState.shared
    let url: URL?
    let close: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Text("Scroll or pinch to zoom · drag to move · double-click for 2×").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            if zoom.zoomed {
                Button { zoom.reset() } label: { Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left") }
                    .help("Back to the whole picture (Esc)")
            }
            if let url { RevealButton(url: url, label: "Show in Finder").buttonStyle(.bordered) }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34).background(.ultraThinMaterial, in: Circle())
            }.buttonStyle(.plain).help("Close (Esc)")
        }
        .controlSize(.small).padding(16)
    }
}

/// A video at full size with its sound and the system scrubber.
struct FullVideo: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView(); v.controlsStyle = .floating; v.player = AVPlayer(url: url); v.player?.play(); return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url { v.player = AVPlayer(url: url); v.player?.play() }
    }
    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) { v.player?.pause() }
}

/// Lets a picture be dragged out to Finder or another app as its file.
extension View {
    @ViewBuilder func fileDrag(_ url: URL?) -> some View {
        if let url { self.onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() } } else { self }
    }
}

/// A Show in Finder chip that appears over a picture while the pointer is on it.
struct RevealOnHover: ViewModifier {
    let url: URL?
    @State var hover = false
    func body(content: Content) -> some View {
        content
            .onHover { hover = $0 }
            .overlay(alignment: .bottomTrailing) {
                if hover, let url {
                    RevealButton(url: url).font(.system(size: 11, weight: .semibold))
                        .padding(5).background(.black.opacity(0.65), in: Circle()).foregroundStyle(.white).padding(6)
                }
            }
    }
}
extension View { func revealOnHover(_ url: URL?) -> some View { modifier(RevealOnHover(url: url)) } }
