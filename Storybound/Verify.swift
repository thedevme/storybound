import SwiftUI
import AVFoundation

/// `-verify <folder>` at launch: draws the trailer's new views to pictures in that folder and quits before any window
/// opens, so checking the app never touches the window you're working in. Nothing is sent to Kie.
enum Verify {
    @MainActor static func runIfAsked() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-beats-test"), i + 1 < args.count { BeatsTest.run(URL(fileURLWithPath: args[i + 1])) }
        if let i = args.firstIndex(of: "-zoom-test"), i + 2 < args.count { ZoomTest.run(URL(fileURLWithPath: args[i + 1]), picture: URL(fileURLWithPath: args[i + 2])) }
        if let i = args.firstIndex(of: "-frame-test"), i + 1 < args.count { FrameTest.run(URL(fileURLWithPath: args[i + 1])) }
        // `-render-trailer <folder> [seconds]`: renders the real trailer to that folder with no window, prints the status, quits
        if let i = args.firstIndex(of: "-render-trailer"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1])
            let seconds = args.count > i + 2 ? Double(args[i + 2]) : nil
            let store = Store(), tm = TrailerModel(), ex = VideoExporter()
            var done = false
            Task { await ex.exportTrailer(tm, store: store, seconds: seconds, ambience: true, folder: dir); done = true }
            let began = Date()
            while !done { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            let note = "status: \(ex.status)\noutput: \(ex.output?.path ?? "none")\nseconds taken: \(Int(Date().timeIntervalSince(began)))\n"
            try? note.write(to: dir.appendingPathComponent("render.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        // `-trailer-voice-test <folder>`: runs a real sync on the recording and saves script lines, all on a copy of shots.json
        if let i = args.firstIndex(of: "-trailer-voice-test"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1]); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let real = Store().trailerShotsURL, copy = dir.appendingPathComponent("shots.json")
            try? FileManager.default.removeItem(at: copy); try? FileManager.default.copyItem(at: real, to: copy)
            Store.shotsFileOverride = copy
            let store = Store(); var log: [String] = []
            guard let t = store.loadTrailer() else { exit(3) }
            var done = false
            Task {
                if let p = await store.planTrailerSync(t) {
                    log.append(p.note); log.append("moves: \(p.moves.count)")
                    for m in p.moves { log.append("  \(m.shot) \(m.before) -> \(m.after)") }
                    log.append("matched: \(p.matched.count), unsure: \(p.unsure)")
                } else { log.append("no plan: \(store.trailerSyncNote ?? "")") }
                done = true
            }
            while !done { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            let nav = Nav(), tm = TrailerModel(); tm.reload(store)
            let r = ImageRenderer(content: TrailerProductionBoxes(t: t).padding(16).frame(width: 800).background(Color.panel).foregroundStyle(Color.ink).environmentObject(store).environmentObject(nav).environmentObject(tm).preferredColorScheme(.dark))
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("boxes.png")) }
            log.append("edit line ok: \(store.editShot("T02", "line", "TEST LINE") && store.loadTrailer()?.shots.first { $0.id == "T02" }?.line == "TEST LINE")")
            log.append("top edit ok: \(store.editTrailerTop(["audio_original": t.audio]) && store.loadTrailer()?.audio_original == t.audio)")
            log.append("shots after edits: \(store.loadTrailer()?.shots.count ?? 0)")
            try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("voice.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        if let i = args.firstIndex(of: "-trailer-bar-test"), i + 1 < args.count {
            let dir = URL(fileURLWithPath: args[i + 1]); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = Store(), nav = Nav(), tm = TrailerModel(), listener = Listener(); nav.tab = .trailer; tm.reload(store)
            if let season = store.season, let t = tm.trailer {
                tm.audio.timeline = trailerTimeline(t); tm.audio.current = "T03"; tm.audio.clock.time = 12
                let r = ImageRenderer(content: NowPlaying(season: season).frame(width: 1100).foregroundStyle(Color.ink).environmentObject(store).environmentObject(nav).environmentObject(tm).environmentObject(listener).preferredColorScheme(.dark))
                if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("trailer-bar.png")) }
                let bar = TrailerNowPlaying(audio: tm.audio, clock: tm.audio.clock, trailer: t)
                var log: [String] = []
                for d in [1, 1, -1, -1, -1] { bar.jump(d); log.append("\(d > 0 ? "next" : "back") -> \(tm.audio.clock.time)") }
                try? log.joined(separator: "\n").write(to: dir.appendingPathComponent("jumps.txt"), atomically: true, encoding: .utf8)
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "-kie-test"), i + 1 < args.count { KieTest.run(URL(fileURLWithPath: args[i + 1])) }
        guard let i = args.firstIndex(of: "-verify"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        var notes: [String] = []
        let store = Store(), nav = Nav(), tm = TrailerModel()
        tm.reload(store)
        guard let t = tm.trailer else { notes.append("no trailer"); finish(dir, notes) }

        guard let t22 = tm.trailer?.shots.first(where: { $0.id == "T22" }), let t25 = tm.trailer?.shots.first(where: { $0.id == "T25" }) else { finish(dir, notes) }
        notes.append("T22 kind=\(t22.kind) zoom=\(String(describing: t22.zoom)) transition=\(String(describing: t22.transition))")
        notes.append("T25 video=\(tm.files["T25"]?.video?.path ?? "none") reveal=\(tm.files["T25"]?.reveal?.lastPathComponent ?? "none")")
        notes.append("T01 video=\(tm.files["T01"]?.video?.path ?? "none")")
        notes.append("paintings found: \(t.shots.filter { tm.files[$0.id]?.painting != nil }.count) of \(t.shots.count)")

        // decode what the renders need (the views read decoded pictures at once)
        func warm(_ u: URL?, _ m: Int?, crop: [Double]? = nil) { if let u, let cg = PictureCache.load(u, crop: crop, maxPixel: m) { PictureCache.shared.set(PictureCache.key(u, crop, m, store.imageVersion), cg) } }
        for s in ["T22", "T23", "T24", "T25"] { warm(tm.files[s]?.shown, 1600); warm(tm.files[s]?.shown, 1000) }
        for r in tm.prompts["T22"]?.refs?["bw"] ?? [] { warm(URL(fileURLWithPath: r.file), 300) }

        func render<V: View>(_ name: String, _ v: V, width: CGFloat) {
            let r = ImageRenderer(content: v.frame(width: width).background(Color.panel).foregroundStyle(Color.ink)
                .environmentObject(store).environmentObject(nav).environmentObject(tm).preferredColorScheme(.dark))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: dir.appendingPathComponent(name)); notes.append("rendered \(name)") }
            else { notes.append("FAILED \(name)") }
        }

        // the move editor on T22, with its start and end boxes
        render("t22-zoom-editor.png", ZoomEditor(shot: t22, url: tm.files["T22"]?.shown, length: 3, zoom: t22.zoom ?? .full).padding(16), width: 520)
        render("t22-transition-editor.png", TransitionEditor(shot: t22, kind: .crossfade, duration: 0.5).padding(16), width: 520)

        // the trailer player's frames: T22 at its start, middle and end, and halfway through its crossfade into T23
        if let span = tm.audio.timeline["T22"] {
            let loader = FrameLoader()
            let size = CGSize(width: 960, height: 540)
            for (label, time) in [("start", span.0 + 0.01), ("middle", (span.0 + span.1) / 2), ("end-before-fade", span.1 - 0.3), ("crossfade-half", span.1 - 0.25 + 0.0)] {
                render("watch-T22-\(label).png", WatchFrame(loader: loader, audio: tm.audio, trailer: tm.trailer!, time: time, size: size), width: size.width)
            }
            notes.append("T22 span \(span); crossfade window \(span.1 - 0.5)...\(span.1)")
        }

        // full screen: the composed picture (logo and title line drawn in, as the card shows them)
        for (id, logo, sub) in [("T25", true, false), ("T24", false, true)] {
            if let u = tm.files[id]?.shown, let base = PictureCache.load(u, crop: nil, maxPixel: nil),
               let out = Store.titleComposer(logo: logo ? store.logoURL : nil, subscribe: sub)?(base) {
                let rep = NSBitmapImageRep(cgImage: out); rep.size = NSSize(width: 1920, height: 1080)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("fullscreen-\(id)-composed.png"))
                notes.append("composed \(id): \(out.width)x\(out.height)")
            }
        }
        // T25's video: its first frame (what the card shows under the play badge)
        if let v = tm.files["T25"]?.video {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: v)); g.appliesPreferredTrackTransform = true
            if let cg = try? g.copyCGImage(at: .zero, actualTime: nil) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("T25-video-first-frame.png"))
                notes.append("T25 video first frame \(cg.width)x\(cg.height)")
            }
        }
        // the "Is this right?" sheet for T22's B&W (not sent: no OK is pressed, and the balance call doesn't run here)
        if let j = tm.job(store, "T22", "bw") {
            render("generate-confirm-T22-bw.png", GenConfirmSheet(jobs: [j]), width: 760)
            render("generate-job-T22-bw.png", JobSummary(job: j, open: false).padding(12), width: 720)
            notes.append("job T22 bw: \(j.model) \(j.res) \(j.credits) credits, \(j.refs.count) refs, saves \(j.out.lastPathComponent)")
        }
        if let j = tm.job(store, "T22", "color") { notes.append("job T22 color: \(j.model) \(j.res) \(j.credits) credits, canColor=\(tm.canColor("T22"))") }
        // Edit: the prompt fix_jobs would build, with and without an extra image
        let ch = ["Jasmine holds the wok handle with both mitten hands.", "Remove the steam above the wok."]
        if let e = tm.editJob(store, "T22", "bw", changes: ch, extras: []) {
            try? e.prompt.write(to: dir.appendingPathComponent("edit-T22-bw-prompt.txt"), atomically: true, encoding: .utf8)
            notes.append("edit T22 bw: \(e.res) \(e.credits) credits, image 1 = \(e.refs.first?.name ?? "?"), saves \(e.out.lastPathComponent)")
        }
        let andre = PromptAttachment(url: URL(fileURLWithPath: store.kitchen.path + "/ART/Characters/Andre/Andre - Locked Design.png"), role: "Andre's locked design: colors only")
        if let e = tm.editJob(store, "T22", "color", changes: ch, extras: [andre]) {
            try? e.prompt.write(to: dir.appendingPathComponent("edit-T22-color-prompt.txt"), atomically: true, encoding: .utf8)
            notes.append("edit T22 color: \(e.res) \(e.credits) credits, refs \(e.refs.map(\.name))")
            render("edit-sheet-T22-color.png", EditSheet(request: EditRequest(ids: ["T22"], step: "color"), text: ch.joined(separator: "\n"), extras: [andre]), width: 780)
            render("edit-job-T22-color.png", JobSummary(job: e, open: true).padding(12), width: 720)
        }
        render("t22-detail.png", TrailerShotDetail(shot: t22, trailer: tm.trailer!, files: tm.files, prompt: tm.prompts["T22"], audio: tm.audio,
                                                   span: tm.audio.timeline["T22"], refresh: {}, scroll: false), width: 460)
        _ = t25
        // the flashback tiles: plain labels, files, prompts, and a Generate sheet opened (never sent)
        for tl in tm.tiles {
            notes.append("tile \(tl.id): \"\(tl.label)\" sketch=\(tm.files[tl.id]?.sketch?.lastPathComponent ?? "MISSING") painting=\(tm.files[tl.id]?.painting?.lastPathComponent ?? "none") prompts=\(tm.tilePrompts[tl.id] != nil)")
        }
        for u in tm.tiles.compactMap({ tm.files[$0.id]?.shown }) { warm(u, 500); warm(u, 1600) }
        if let g2 = tm.tile("S1-G2") {
            render("tile-S1-G2-detail.png", TileDetail(tile: g2), width: 460)
            if let j = tm.job(store, "S1-G2", "bw") {
                render("tile-S1-G2-generate-bw.png", JobSummary(job: j, open: false).padding(12), width: 720)
                render("tile-S1-G2-generate-sheet.png", GenConfirmSheet(jobs: [j]), width: 760)
                notes.append("tile S1-G2 bw job: \(j.model) \(j.res) \(j.credits) credits, \(j.refs.map(\.name)), saves \(j.out.path)")
            }
            notes.append("tile S1-G2 color job: \(tm.job(store, "S1-G2", "color").map { "\($0.res), refs \($0.refs.map(\.name))" } ?? "none") canColor=\(tm.canColor("S1-G2"))")
        }
        if let g3 = tm.tile("S1-G3"), let e = tm.editJob(store, "S1-G3", "bw", changes: ["Make the table square."], extras: []) {
            notes.append("tile S1-G3 edit bw: image 1 = \(e.refs.first?.url?.path ?? "?"), saves \(e.out.lastPathComponent) in \(g3.episode)")
        }
        if let m = tm.trailer?.shots.first(where: { $0.kind == "montage" }) {
            render("card-T17a.png", TrailerCard(shot: m, trailer: tm.trailer!, files: tm.files, span: tm.audio.timeline[m.id], live: false, logo: false,
                                                prompt: nil, selected: false, tap: {}, refresh: {}).padding(12), width: 620)
        }
        // run progress, with made-up states (nothing is sent): G8 downloading, T19 waiting, G2 failed, T21 done
        let fake = [tm.job(store, "S1-G8", "bw"), tm.job(store, "T19", "color"), tm.job(store, "S1-G2", "bw"), tm.job(store, "T21", "color")].compactMap { $0 }
        tm.kie.lastRun = fake
        if fake.count == 4 {
            tm.kie.phase[fake[0].id] = .downloading; tm.kie.status[fake[0].id] = "Downloading…"
            tm.kie.phase[fake[1].id] = .waiting(Date().addingTimeInterval(-75)); tm.kie.status[fake[1].id] = "Rendering… 75s"
            tm.kie.phase[fake[2].id] = .failed("Image generation failed: content policy"); tm.kie.failed[fake[2].id] = "Image generation failed: content policy"
            tm.kie.phase[fake[3].id] = .done(Date())
        }
        notes.append("fake run: \(fake.map(\.id))")
        if let g8 = tm.tile("S1-G8") {
            tm.selected = "S1-G8"
            render("run-panel-tile-G8.png", VStack(spacing: 0) { RunList(kie: tm.kie).padding([.horizontal, .top], 20); TileDetail(tile: g8) }, width: 460)
        }
        if let t19 = tm.trailer!.shots.first(where: { $0.id == "T19" }) {
            tm.selected = "T19"
            render("run-panel-T19.png", TrailerShotDetail(shot: t19, trailer: tm.trailer!, files: tm.files, prompt: tm.prompts["T19"], audio: tm.audio,
                                                          span: tm.audio.timeline["T19"], refresh: {}, scroll: false), width: 460)
            if let g2 = tm.tile("S1-G2") { tm.selected = "S1-G2"; render("run-panel-tile-G2-failed.png", TileDetail(tile: g2), width: 460) }
            if let m = tm.trailer!.shots.first(where: { $0.kind == "montage" }) {
                func card(_ s: TrailerShot) -> TrailerCard {
                    TrailerCard(shot: s, trailer: tm.trailer!, files: tm.files, span: tm.audio.timeline[s.id], live: false, logo: false, prompt: tm.prompts[s.id], selected: false, tap: {}, refresh: {})
                }
                render("cards-T17a-T19-row.png", Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow(alignment: .top) { card(m); card(t19) }
                }.padding(16), width: 1240)
            }
        }
        // video shots: length, slot and what happens, and the timing controls
        for s in tm.trailer!.shots where s.video != nil {
            if let v = tm.files[s.id]?.video { tm.videoLengths[s.id] = CMTimeGetSeconds(AVURLAsset(url: v).duration) }
            notes.append("\(s.id) time \(s.time): " + (VideoStatusLine.text(s, span: tm.audio.timeline[s.id], file: tm.videoLengths[s.id]) ?? "no status"))
        }
        if let t01 = tm.trailer!.shots.first(where: { $0.id == "T01" }), let sp = t01.span {
            render("t01-video-timing.png", VideoTiming(shot: t01, start: sp.0, end: sp.1 ?? sp.0, inPoint: 0, outPoint: tm.videoLengths["T01"] ?? 0).padding(16), width: 520)
            render("card-T01.png", TrailerCard(shot: t01, trailer: tm.trailer!, files: tm.files, span: tm.audio.timeline["T01"], live: false, logo: false,
                                               prompt: nil, selected: false, tap: {}, refresh: {}).padding(12), width: 620)
        }
        notes.append("fmtTime: \([0, 4, 36.2, 59, 75.5].map(fmtTime))")
        for (into, mode) in [(5.0, "hold"), (5.3, "fade"), (6.0, "loop")] {
            var p = VideoPlan(); p.end = mode
            notes.append("plan \(mode) at \(into) s of a 4.04 s video: \(p.frame(into, file: 4.04))")
        }
        // export: what the status line would name if files were missing or the timing had a hole
        var holes = tm.files; holes["T05"] = nil; holes["ep01-the-walkout/S1-G2"] = nil; holes["T24"] = PanelFiles(sketch: nil, painting: nil)
        var lens: [String: Double] = [:]
        for s in tm.trailer!.shots { if tm.files[s.id]?.video != nil { lens[s.id] = 5 } }
        notes.append("export problems, whole trailer, files removed: \(VideoExporter.trailerProblems(tm.trailer!, timeline: tm.audio.timeline, files: holes, lengths: lens, upTo: 75.5))")
        notes.append("export problems, first 10 s, same files: \(VideoExporter.trailerProblems(tm.trailer!, timeline: tm.audio.timeline, files: holes, lengths: lens, upTo: 8))")
        notes.append("export problems, real files: \(VideoExporter.trailerProblems(tm.trailer!, timeline: tm.audio.timeline, files: tm.files, lengths: lens, upTo: 75.5))")
        // the trailer player from 0:55 to the end: which shot, and for a video shot the frame it shows (held at the end)
        notes.append("logo overlay on: \(store.logoShots(tm.trailer!).sorted()) (video shots: \(tm.trailer!.shots.filter { $0.video != nil }.map(\.id)))")
        notes.append("logoURL: \(store.logoURL?.lastPathComponent ?? "none")")
        let tl = tm.audio.timeline
        for k in 0...14 {
            let time = min(tm.trailer!.audio_seconds - 0.05, 55.0 + Double(k) * 1.5)
            guard let id = trailerShot(at: time, tl), let s = tm.trailer!.shots.first(where: { $0.id == id }), let span = tl[id] else { notes.append("\(time): no shot"); continue }
            let name = String(format: "play-%05.1f-%@.png", time, id)
            if let v = tm.files[id]?.video {
                let a = AVURLAsset(url: v)
                let length = CMTimeGetSeconds(a.duration)
                let (vt, hold) = videoTime(time - span.0, length: length)
                let g = AVAssetImageGenerator(asset: a); g.appliesPreferredTrackTransform = true
                g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero; g.maximumSize = CGSize(width: 960, height: 540)
                if let cg = try? g.copyCGImage(at: CMTime(seconds: vt, preferredTimescale: 600), actualTime: nil) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                }
                notes.append(String(format: "%.1f s: %@ video %@ at %.2f of %.2f s%@", time, id, v.lastPathComponent, vt, length, hold ? " (holding last frame)" : ""))
            } else {
                render(name, WatchFrame(loader: FrameLoader(), audio: tm.audio, trailer: tm.trailer!, time: time, size: CGSize(width: 960, height: 540)), width: 960)
                notes.append(String(format: "%.1f s: %@ picture%@", time, id, s.transition != nil && time > span.1 - (s.transition?.duration ?? 0) ? " (in its transition)" : ""))
            }
        }
        finish(dir, notes)
    }
    static func finish(_ dir: URL, _ notes: [String]) -> Never {
        try? notes.joined(separator: "\n").write(to: dir.appendingPathComponent("verify.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }
}

final class ZoomTick: ObservableObject { @Published var value = 0; var updates = 0 }
struct ZoomTickRoot: View {
    @ObservedObject var tick: ZoomTick
    let url: URL?
    var body: some View {
        let _ = (tick.updates += 1)
        ZoomableImage(url: url, key: "a", version: tick.value)
    }
}

// MARK: - Zoom: synthetic input on the real views, in windows that are never shown
enum ZoomTest {
    @MainActor static func run(_ dir: URL, picture: URL) -> Never {
        var out: [String] = []
        NSApplication.shared.setActivationPolicy(.prohibited)
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func find(_ v: NSView) -> ZoomScrollView? { (v as? ZoomScrollView) ?? v.subviews.lazy.compactMap(find).first }
        let center = NSPoint(x: 700, y: 400)

        // a copy of the picture, so "the file changed" can be tested without touching the real one
        let copy = dir.appendingPathComponent("zoom-copy.png")
        try? FileManager.default.removeItem(at: copy); try? FileManager.default.copyItem(at: picture, to: copy)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: AnyView(ZStack { Color.black; ZoomableImage(url: copy, key: "a") }))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 800); win.contentView = host
        host.layoutSubtreeIfNeeded(); pump(2.5)
        guard let sv = find(host) else { out.append("no ZoomScrollView found"); finish(dir, out) }
        func mag() -> String { String(format: "%.3f", sv.magnification) }
        func reset() { sv.magnification = 1; pump(0.1) }
        func hit() -> NSView? { host.hitTest(center) }

        func scroll(precise: Bool, dy: Int32, shift: Bool = false) -> NSEvent? {
            guard let c = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0) else { return nil }
            c.location = center; if shift { c.flags = .maskShift }
            return NSEvent(cgEvent: c)
        }
        out.append("hit view: \(hit().map { String(describing: type(of: $0)) } ?? "none")")
        for _ in 0..<5 { if let e = scroll(precise: false, dy: 1), let v = hit() { v.scrollWheel(with: e) } }; pump(0.1)
        out.append("mouse wheel, 5 notches: \(mag())"); reset()
        for _ in 0..<10 { if let e = scroll(precise: true, dy: 12), let v = hit() { v.scrollWheel(with: e) } }; pump(0.1)
        out.append("trackpad / Magic Mouse scroll, 10 steps: \(mag())")
        for _ in 0..<40 { if let e = scroll(precise: true, dy: -12), let v = hit() { v.scrollWheel(with: e) } }; pump(0.1)
        out.append("scrolled back the other way: \(mag()) (stops at fit)"); reset()

        // the point under the pointer stays under the pointer
        let spot = NSPoint(x: 350, y: 200), before = spot
        sv.setMagnification(1, centeredAt: spot)
        if let c = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0) {
            let screen = NSPoint(x: spot.x, y: CGFloat(NSScreen.screens.first?.frame.height ?? 800) - spot.y); c.location = screen
            if let e = NSEvent(cgEvent: c), let doc = sv.documentView {
                let p = doc.convert(e.locationInWindow, from: nil)
                let onScreen0 = sv.contentView.convert(p, from: doc)
                sv.scrollWheel(with: e); pump(0.05)
                let onScreen1 = sv.contentView.convert(p, from: doc)
                let a = NSPoint(x: onScreen0.x - sv.contentView.bounds.minX, y: onScreen0.y - sv.contentView.bounds.minY)
                _ = a; _ = before
                out.append(String(format: "toward the pointer: mag %.3f, picture point stayed within (%.1f, %.1f) px of the pointer", sv.magnification,
                                  abs((onScreen1.x - sv.contentView.bounds.minX) * sv.magnification - (onScreen0.x)), abs((onScreen1.y - sv.contentView.bounds.minY) * sv.magnification - (onScreen0.y))))
            }
        }
        reset()

        func pinch(_ m: Double) -> NSEvent? {
            guard let c = CGEvent(source: nil), let type = CGEventType(rawValue: 29) else { return nil }
            c.type = type
            c.setIntegerValueField(CGEventField(rawValue: 110)!, value: 8)
            c.setDoubleValueField(CGEventField(rawValue: 113)!, value: m)
            c.setIntegerValueField(CGEventField(rawValue: 132)!, value: 2)
            c.location = center
            return NSEvent(cgEvent: c)
        }
        if let p = pinch(0.2), let v = hit() { for _ in 0..<5 { v.magnify(with: p) } }; pump(0.1)
        out.append("pinch: \(mag())"); reset()

        // double-click and drag, through the real view
        func mouse(_ type: CGEventType, clicks: Int64 = 1, dx: Int64 = 0, dy: Int64 = 0) -> NSEvent? {
            guard let c = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: center, mouseButton: .left) else { return nil }
            c.setIntegerValueField(.mouseEventClickState, value: clicks)
            c.setIntegerValueField(.mouseEventDeltaX, value: dx); c.setIntegerValueField(.mouseEventDeltaY, value: dy)
            return NSEvent(cgEvent: c)
        }
        if let e = mouse(.leftMouseDown, clicks: 2), let v = hit() { v.mouseDown(with: e) }; pump(0.6)
        out.append("double-click: \(mag())")
        let o0 = sv.contentView.bounds.origin
        if let e = mouse(.leftMouseDragged, dx: 80, dy: 40), let v = hit() { v.mouseDragged(with: e) }; pump(0.1)
        let o1 = sv.contentView.bounds.origin
        out.append(String(format: "drag 80, 40 px: view moved (%.0f, %.0f), still %@", o1.x - o0.x, o1.y - o0.y, mag()))
        if let e = scroll(precise: true, dy: 40, shift: true), let v = hit() { let z = mag(); v.scrollWheel(with: e); pump(0.1); out.append("Shift-scroll pans, zoom unchanged: \(z) → \(mag())") }
        if let e = mouse(.leftMouseDown, clicks: 2), let v = hit() { v.mouseDown(with: e) }; pump(0.6)
        out.append("double-click again: \(mag())")

        // Fit and Esc's reset
        sv.setMagnification(3, centeredAt: NSPoint(x: 300, y: 200)); pump(0.1)
        ZoomState.shared.reset(); pump(0.6)
        out.append("Fit: \(mag()), zoomed flag \(ZoomState.shared.zoomed)")

        // a zoom holds through anything that doesn't change this picture's file: same view, really redrawn
        let tick = ZoomTick()
        let host2 = NSHostingView(rootView: ZoomTickRoot(tick: tick, url: copy))
        let win2 = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        host2.frame = NSRect(x: 0, y: 0, width: 1400, height: 800); win2.contentView = host2
        host2.layoutSubtreeIfNeeded(); pump(2.5)
        if let z = find(host2) {
            z.setMagnification(3, centeredAt: NSPoint(x: 300, y: 200)); pump(0.1)
            let key0 = z.loadedKey, updates0 = tick.updates
            tick.value += 1; host2.layoutSubtreeIfNeeded(); pump(2.5)
            out.append(String(format: "redrawn %d time(s), same file: mag %.3f, same view %@, key unchanged %@", tick.updates - updates0, z.magnification, String(find(host2) === z), String(z.loadedKey == key0)))
            try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: copy.path)
            tick.value += 1; host2.layoutSubtreeIfNeeded(); pump(2.5)
            out.append(String(format: "this picture's file changed: mag %.3f (back to fit on purpose), same view %@, key changed %@", z.magnification, String(find(host2) === z), String(z.loadedKey != key0)))
        } else { out.append("second host: no zoom view") }
        host2.rootView = ZoomTickRoot(tick: tick, url: nil); host2.layoutSubtreeIfNeeded(); pump(0.2)
        try? FileManager.default.removeItem(at: copy)

        // a viewer that goes away while zoomed must not trap Esc
        sv.setMagnification(3, centeredAt: NSPoint(x: 300, y: 200)); pump(0.1)
        if let e = scroll(precise: true, dy: 1), let v = hit() { v.scrollWheel(with: e) }; pump(0.1)
        out.append("zoomed flag while zoomed: \(ZoomState.shared.zoomed)")
        host.rootView = AnyView(Color.black); host.layoutSubtreeIfNeeded(); pump(0.3)
        out.append("viewer gone: zoomed flag \(ZoomState.shared.zoomed)")

        // the whole window: is anything on top of the picture in each full-screen view?
        let store = Store(), nav = Nav(), tm = TrailerModel()
        tm.reload(store); pump(0.3)
        let full = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 950), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let root = ContentView().environmentObject(store).environmentObject(nav).environmentObject(Hover()).environmentObject(VideoExporter())
            .environmentObject(Player()).environmentObject(Listener()).environmentObject(tm)
        let fh = NSHostingView(rootView: root); fh.frame = NSRect(x: 0, y: 0, width: 1500, height: 950); full.contentView = fh
        func at(_ label: String) {
            fh.layoutSubtreeIfNeeded(); pump(2.5)
            let v = fh.hitTest(NSPoint(x: 750, y: 475))
            let z = find(fh)
            var line = "\(label): top view \(v.map { String(describing: type(of: $0)) } ?? "none")"
            if let z, let v, let e = scroll(precise: true, dy: 40) {
                z.magnification = 1; v.scrollWheel(with: e); pump(0.1)
                line += String(format: ", scroll zooms to %.3f, picture %@", z.magnification, (z.documentView as? NSImageView)?.image == nil ? "NOT LOADED" : "loaded")
                z.magnification = 1
            } else { line += ", no zoom view" }
            out.append(line)
        }
        nav.go(.trailer); pump(0.5)
        tm.selected = "T23"; nav.inspector = true; nav.viewing = true; at("trailer shot T23, panel open")
        // the real viewer: what a Kie run landing, a Reload or a drop on another shot does while you're zoomed in
        if let z = find(fh) {
            z.setMagnification(3, centeredAt: NSPoint(x: 300, y: 200)); pump(0.1)
            let v0 = store.imageVersion
            store.refreshFiles(); tm.refreshFiles(store); fh.layoutSubtreeIfNeeded(); pump(2.5)
            out.append(String(format: "real viewer, version %d → %d: mag %.3f, same view %@", v0, store.imageVersion, z.magnification, String(find(fh) === z)))
            tm.reload(store); fh.layoutSubtreeIfNeeded(); pump(2.5)
            out.append(String(format: "real viewer, after a full reload: mag %.3f, same view %@", z.magnification, String(find(fh) === z)))
            z.magnification = 1
        }
        tm.selected = "T17a"; at("T17a montage")
        tm.selected = "S1-G3"; at("flashback tile S1-G3")
        tm.selected = "T25"; at("T25 (a video shot)")
        nav.viewing = false; pump(0.3)
        nav.go(.ep, ep: 1, beat: 5); pump(0.5); nav.viewing = true; at("episode 1 beat 5 (viewing=\(nav.viewing) shown=\(nav.shownEpisode ?? -1) selected=\(nav.selected ?? -1))")
        for e in store.season?.eps ?? [] {
            let none = e.beats.filter { store.fullPictureURL(e, $0) == nil }
            let gone = e.beats.filter { b in store.fullPictureURL(e, b).map { !FileManager.default.fileExists(atPath: $0.path) } ?? false }.map(\.n)
            let drawn = none.filter { store.fullPicture(e, $0) != nil }.map(\.n)
            out.append("ep \(e.n): \(e.beats.count) beats, no picture yet \(none.count), shows a picture with no file \(drawn.count) \(drawn.prefix(8)), file missing on disk \(gone.count) \(gone.prefix(8))")
        }
        finish(dir, out)
    }
    static func finish(_ dir: URL, _ out: [String]) -> Never {
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("zoom.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }
}

// MARK: - Framing a shot: real events on the real control, in a window that is never shown, on a copy of shots.json
enum FrameTest {
    @MainActor static func run(_ dir: URL) -> Never {
        var out: [String] = []
        NSApplication.shared.setActivationPolicy(.prohibited)
        func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let store0 = Store()
        let copy = dir.appendingPathComponent("shots-copy.json")
        try? FileManager.default.removeItem(at: copy); try? FileManager.default.copyItem(at: store0.trailerShotsURL, to: copy)
        Store.shotsFileOverride = copy
        let store = Store(), nav = Nav(), tm = TrailerModel()
        tm.reload(store); pump(0.3)
        func saved(_ id: String) -> String {
            let d = (try? JSONSerialization.jsonObject(with: Data(contentsOf: copy))) as? [String: Any]
            let shots = d?["shots"] as? [[String: Any]]
            return shots?.first { $0["id"] as? String == id }?["zoom"].map { "\($0)" } ?? "none"
        }
        func shot(_ id: String) -> TrailerShot { tm.trailer!.shots.first { $0.id == id }! }

        // conversions
        for f in [BeatFrame(scale: 1.6, x: 0.4, y: 0.6), BeatFrame(scale: 2, x: 0.25, y: 0.25), BeatFrame()] {
            let back = BeatFrame(rect: f.rect)
            out.append(String(format: "frame %.2f× (%.2f, %.2f) → %@ → %.2f× (%.2f, %.2f)", f.scale, f.x, f.y, "\(f.rect)", back.scale, back.x, back.y))
        }

        // the real control, real mouse events through the window
        let id = "T07"
        out.append("\(id) before: \(saved(id))")
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.borderless], backing: .buffered, defer: false)
        let tick = FrameTick()
        let host = NSHostingView(rootView: AnyView(FrameTestRoot(tick: tick, tm: tm, id: id).environmentObject(store).environmentObject(tm).environmentObject(nav)))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 420); win.contentView = host
        host.layoutSubtreeIfNeeded(); pump(2.0); host.layoutSubtreeIfNeeded(); pump(0.3)
        func mouse(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        // set a zoom first the way the slider's let-go does, then drag it for real
        store.editShot(id, "zoom", ShotZoom.still(BeatFrame(scale: 2, x: 0.5, y: 0.5)).saved); tm.reload(store); pump(0.5); host.layoutSubtreeIfNeeded(); pump(1.0)
        out.append("\(id) at 2×: \(saved(id))")
        // parked far off every screen, so SwiftUI treats it as a live window; nothing shows
        win.setFrameOrigin(NSPoint(x: -30000, y: -30000)); win.orderBack(nil); host.layoutSubtreeIfNeeded(); pump(0.5)
        func short(_ id: String) -> String { shot(id).zoom.map { "\($0.start)" } ?? "none" }
        func mouseAt(_ t: NSEvent.EventType, _ p: NSPoint) -> NSEvent? { mouse(t, p) }
        let p = NSPoint(x: 240, y: 240)
        out.append("window visible=\(win.isVisible) on a screen=\(win.screen != nil); top view: \(host.hitTest(p).map { String(describing: type(of: $0)) } ?? "none")")
        // through the window's own dispatch
        tm.reload(store); pump(0.2)
        if let e = mouseAt(.leftMouseDown, p) { win.sendEvent(e) }; pump(0.05)
        for i in 1...6 { if let e = mouseAt(.leftMouseDragged, NSPoint(x: p.x - CGFloat(i) * 10, y: p.y)) { win.sendEvent(e) }; pump(0.03) }
        if let e = mouseAt(.leftMouseUp, NSPoint(x: p.x - 60, y: p.y)) { win.sendEvent(e) }; pump(0.6)
        out.append("drag via window: \(short(id))")
        // straight to the hosting view
        if let e = mouseAt(.leftMouseDown, p) { host.mouseDown(with: e) }; pump(0.05)
        for i in 1...6 { if let e = mouseAt(.leftMouseDragged, NSPoint(x: p.x - CGFloat(i) * 10, y: p.y)) { host.mouseDragged(with: e) }; pump(0.03) }
        if let e = mouseAt(.leftMouseUp, NSPoint(x: p.x - 60, y: p.y)) { host.mouseUp(with: e) }; pump(0.6)
        out.append("drag via hosting view: \(short(id))")
        win.orderOut(nil)

        // what uses it: the planner (Watch and Export), the export's own frame, the card
        var still = BeatFrame(scale: 2, x: 0.62, y: 0.5); still = still.clamped()
        store.editShot(id, "zoom", ShotZoom.still(still).saved); tm.reload(store); pump(0.3)
        let t = tm.trailer!, tl = trailerTimeline(t)
        let span = tl[id]!, mid = (span.0 + span.1) / 2
        let lens: [String: Double] = [:]
        let planner = TrailerPlanner(trailer: t, timeline: tl, files: tm.files, videoLengths: lens, logoShots: store.logoShots(t))
        for time in [span.0 + 0.01, mid, span.1 - 0.01] {
            if case .picture(_, let r, _, _, _)? = planner.plan(at: time)?.a { out.append(String(format: "planner %.2f s: region %@", time, "\(r)")) }
        }
        let draw = TrailerFrameDrawer(planner: planner, lengths: lens, logoFile: store.logoURL)
        var finished = false
        Task {
            if let cg = try? await draw.image(at: mid) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("export-\(id)-framed.png"))
            }
            finished = true
        }
        while !finished { pump(0.05) }
        func render<V: View>(_ name: String, _ v: V, width: CGFloat) {
            let r = ImageRenderer(content: v.frame(width: width).background(Color.panel).foregroundStyle(Color.ink)
                .environmentObject(store).environmentObject(nav).environmentObject(tm).preferredColorScheme(.dark))
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name)) }
        }
        for u in [tm.files[id]?.shown, tm.files["T22"]?.shown].compactMap({ $0 }) { for m in [1000, 1600] { if let cg = PictureCache.load(u, crop: nil, maxPixel: m) { PictureCache.shared.set(PictureCache.key(u, nil, m, store.imageVersion), cg) } } }
        render("card-\(id)-framed.png", TrailerCard(shot: shot(id), trailer: t, files: tm.files, span: tl[id], live: false, logo: false, prompt: nil, selected: false, tap: {}, refresh: {}).padding(12), width: 620)
        if let u = tm.files[id]?.shown, let cg = PictureCache.load(u, crop: nil, maxPixel: 1600) {
            render("panel-still.png", FrameControl(image: Image(decorative: cg, scale: 1), saved: still, canReset: true, caption: "test", commit: { _ in }, reset: {}).padding(16), width: 460)
        }
        render("framing-\(id)-still.png", FrameTestRoot(tick: tick, tm: tm, id: id), width: 460)
        render("framing-T22-move.png", FrameTestRoot(tick: tick, tm: tm, id: "T22"), width: 460)
        out.append("T22 active line: \(ShotFraming(shot: shot("T22"), url: nil).activeLine)")
        out.append("\(id) active line: \(ShotFraming(shot: shot(id), url: nil).activeLine)")
        // Reset removes the key; the whole picture saves nothing
        store.editShot(id, "zoom", ShotZoom.full.saved); tm.reload(store)
        out.append("\(id) after Reset: \(saved(id))")
        out.append("T22 in the copy still: \(saved("T22"))")
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("frame.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }
}
final class FrameTick: ObservableObject { @Published var n = 0 }
struct FrameTestRoot: View {
    @ObservedObject var tick: FrameTick
    @ObservedObject var tm: TrailerModel
    let id: String
    var body: some View {
        if let s = tm.trailer?.shots.first(where: { $0.id == id }) { ShotFraming(shot: s, url: tm.files[id]?.shown).padding(0).frame(width: 480, alignment: .top) }
    }
}


/// `-kie-test <folder>`: checks the Kie tab with no window and nothing sent to Kie: the request bodies, saving and reloading
/// a picture (a copy of a local file), and a drawing of the tab.
enum KieTest {
    @MainActor static func run(_ dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [String] = []
        for c in KieChoice.allCases { for urls in [[], ["https://x/a.png"]] {
            let d = try? JSONSerialization.data(withJSONObject: c.input(prompt: "p", res: "2K", aspect: "16:9", urls: urls), options: [.sortedKeys])
            out.append("\(c.modelID(hasRefs: !urls.isEmpty)) \(d.flatMap { String(data: $0, encoding: .utf8) } ?? "")")
        } }
        let store = Store(), st = KieStudio.shared
        st.folder = dir.appendingPathComponent("ART-Kie")
        let src = store.kitchen.appendingPathComponent("ART/Hand Drawn Storyboards/trailer/T21-painting.png")
        let tmp = dir.appendingPathComponent("tmp.png")
        try? FileManager.default.removeItem(at: tmp); try? FileManager.default.copyItem(at: src, to: tmp)
        do {
            try st.keep(tmp, ext: "png", prompt: "A test prompt, not sent anywhere.", choice: .nano, model: "nano-banana-2", res: "1K", aspect: "16:9", refs: [src], credits: "8", task: "local-test")
            st.results = []; st.shown = nil; st.load()
            out.append("reloaded \(st.results.count) result(s): \(st.shown?.file ?? "none")")
        } catch { out.append("save FAILED \(error)") }
        st.balance = 5836; st.prompt = "A test prompt."; st.refs = [src]
        st.runs = [KieRun(title: "GPT · 4K · 16:9", status: "Waiting on Kie 0:40"), KieRun(title: "Nano Banana · 1K · 16:9", status: "Kie 422: example failure", failed: true)]
        if let u = st.shown.flatMap({ st.url($0) }) { for m in [2400, 300] { if let cg = PictureCache.load(u, crop: nil, maxPixel: m) { PictureCache.shared.set(PictureCache.key(u, nil, m, 0), cg) } } }
        if let cg = PictureCache.load(src, crop: nil, maxPixel: 200) { PictureCache.shared.set(PictureCache.key(src, nil, 200, 0), cg) }
        if let u = st.shown.flatMap({ st.url($0) }) {
            let p = ImageRenderer(content: KiePicture(url: u).frame(width: 800, height: 450).background(Color.dark))
            if let img = p.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("kie-picture.png")) }
        }
        let r = ImageRenderer(content: KieTab().frame(width: 1300, height: 900).background(Color.dark).foregroundStyle(Color.ink).environmentObject(store).preferredColorScheme(.dark))
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("kie-tab.png")) }
        let f = ImageRenderer(content: KieTab().form.padding(20).frame(width: 420).background(Color.panel).foregroundStyle(Color.ink).environmentObject(store).preferredColorScheme(.dark))
        if let img = f.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("kie-form.png")) }
        try? out.joined(separator: "\n").write(to: dir.appendingPathComponent("kie-test.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }
}
