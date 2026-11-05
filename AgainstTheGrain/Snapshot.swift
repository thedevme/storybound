import AppKit
import SwiftUI

/// `-snapshot <folder>` at launch: opens the trailer and food pages, saves a picture of the window for each, and quits.
/// For checking the app without screen recording; nothing happens without the argument.
enum Snapshot {
    static let trailerAt = Notification.Name("snapshotTrailerAt")
    static let scrollTo = Notification.Name("snapshotScrollTo")
    static let select = Notification.Name("snapshotSelect")
    static var activity: NSObjectProtocol?
    /// `-stress <file>`: opens the trailer and scrolls it top to bottom and back many times, writing a heartbeat
    /// line to the file each step; quits when done. A hang shows as the heartbeat stopping.
    static func stressIfAsked(nav: Nav) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-stress"), i + 1 < args.count else { return }
        let log = URL(fileURLWithPath: args[i + 1])
        // no App Nap: a test window behind other apps would otherwise have its timers slowed
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "scroll stress test")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let h = try? FileHandle(forWritingTo: log)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { nav.go(.trailer) }
        // smooth scrolling like a trackpad: 24 px every 16 ms, top to bottom and back, then jiggle near the bottom
        var steps: [CGFloat] = []
        for _ in 0..<3 { steps += stride(from: 0, through: 1, by: 0.004).map { CGFloat($0) }; steps += stride(from: 1, through: 0, by: -0.004).map { CGFloat($0) } }
        for _ in 0..<40 { steps += stride(from: 0.7, through: 1, by: 0.01).map { CGFloat($0) }; steps += stride(from: 1, through: 0.7, by: -0.01).map { CGFloat($0) } }
        // one step per 16 ms frame from a repeating timer (thousands of far-off asyncAfters get batched by the system)
        var n = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
                guard n < steps.count else {
                    timer.invalidate(); h?.write("DONE\n".data(using: .utf8)!); NSApp.terminate(nil); return
                }
                let f = steps[n]
                if let sv = scrollView(), let doc = sv.documentView {
                    let maxY = max(0, doc.frame.height - sv.contentView.bounds.height)
                    sv.contentView.scroll(to: NSPoint(x: 0, y: doc.isFlipped ? f * maxY : (1 - f) * maxY)); sv.reflectScrolledClipView(sv.contentView)
                    if n % 20 == 0 { h?.write("\(n) \(f) \(doc.frame.height) \(Date().timeIntervalSince1970)\n".data(using: .utf8)!) }
                }
                n += 1
            }
        }
    }
    static func runIfAsked(nav: Nav, store: Store, trailer tm: TrailerModel) {
        stressIfAsked(nav: nav)
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-snapshot"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        let steps: [(String, () -> Void)] = [
            ("trailer", { nav.go(.trailer) }),
            ("trailer-detail", { NotificationCenter.default.post(name: select, object: "T07"); nav.inspector = true }),
            ("trailer-panel", { MainActor.assumeIsolated { renderPanel(store, nav, tm, dir.appendingPathComponent("trailer-panel-T07.png")) } }),
            ("trailer-full", { nav.viewing = true }),
            ("trailer-montage", { nav.viewing = false; NotificationCenter.default.post(name: select, object: "T17a") }),
            ("trailer-bottom", { nav.inspector = false; NotificationCenter.default.post(name: scrollTo, object: "T25") }),
            ("episode", { nav.go(.ep, ep: 1, beat: 5) }),
            ("episode2", { nav.go(.ep, ep: 2) }),
            ("plates", { nav.go(.plates) }),
            ("cast", { nav.go(.cast) }),
            ("food", { nav.go(.food) }),
        ]
        var t = 2.0
        for (name, go) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { go() }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 3) { save(dir.appendingPathComponent("\(name).png")) }
            t += 4.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
    }
    /// The side column doesn't draw into a window capture, so the shot's panel is drawn on its own.
    @MainActor static func renderPanel(_ store: Store, _ nav: Nav, _ tm: TrailerModel, _ url: URL) {
        guard let t = tm.trailer, let s = tm.shot else { return }
        let v = TrailerShotDetail(shot: s, trailer: t, files: tm.files, prompt: tm.prompts[s.id], audio: tm.audio, span: tm.audio.timeline[s.id], refresh: {}, scroll: false).frame(width: 440).background(Color.panel).foregroundStyle(Color.ink)
            .environmentObject(store).environmentObject(nav).environmentObject(tm).preferredColorScheme(.dark)
        let r = ImageRenderer(content: v); r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
    /// The window the steps drive: the main one (a launch can also bring back other saved windows).
    static var window: NSWindow? { NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } }
    /// The tallest scroll view in the window: the page's own.
    static func scrollView() -> NSScrollView? {
        func all(_ v: NSView) -> [NSScrollView] { (v as? NSScrollView).map { [$0] } ?? [] + v.subviews.flatMap(all) }
        guard let root = window?.contentView else { return nil }
        return all(root).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }
    static func save(_ url: URL) {
        guard let v = window?.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
