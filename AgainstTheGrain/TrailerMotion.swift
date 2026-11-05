import SwiftUI
import AVFoundation
import AVKit

// MARK: - A shot's camera move and its transition into the next shot (saved on the shot in shots.json)

/// The camera move: the start and end frames as [x0, y0, x1, y1] fractions of the picture, both 16:9.
/// Saved as "zoom" (the shot's "camera" key already names its location camera).
struct ShotZoom: Codable, Equatable {
    var start: [Double]; var end: [Double]; var ease: String?
    static let full = ShotZoom(start: fullFrame, end: fullFrame, ease: "inOut")
    var isStill: Bool { start == end }
    /// The frame at a point in the shot (0...1).
    func at(_ p: Double) -> [Double] {
        let t = ease == "linear" ? p : p * p * (3 - 2 * p)
        return zip(start, end).map { $0 + ($1 - $0) * min(1, max(0, t)) }
    }
}
let fullFrame: [Double] = [0, 0, 1, 1]
func isFull(_ r: [Double]?) -> Bool { guard let r, r.count == 4 else { return true }; return r[0] <= 0.001 && r[1] <= 0.001 && r[2] >= 0.999 && r[3] >= 0.999 }

/// How a shot hands over to the next one.
struct ShotTransition: Codable, Equatable { var type: String; var duration: Double }
enum TransitionKind: String, CaseIterable, Identifiable {
    case cut, crossfade, dipBlack = "dip-black", dipWhite = "dip-white", pushLeft = "push-left", pushRight = "push-right", zoomThrough = "zoom-through"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: return "Cut"; case .crossfade: return "Crossfade"; case .dipBlack: return "Dip to black"; case .dipWhite: return "Dip to white"
        case .pushLeft: return "Push left"; case .pushRight: return "Push right"; case .zoomThrough: return "Zoom through"
        }
    }
}

extension Store {
    /// Sets (or removes, with nil) one key on one shot in shots.json. Python does the edit so every other key keeps
    /// its place and the file's own formatting (indent 2) is kept exactly.
    @discardableResult
    func editShot(_ id: String, _ key: String, _ value: Any?) -> Bool {
        let json: String
        if let value {
            guard let d = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), let s = String(data: d, encoding: .utf8) else { return false }
            json = s
        } else { json = "null" }
        let script = """
        import json, os, sys
        p, i, k, v = sys.argv[1:5]
        d = json.load(open(p))
        for s in d['shots']:
            if s['id'] == i:
                if v == 'null': s.pop(k, None)
                else: s[k] = json.loads(v)
                break
        else:
            sys.exit(2)
        t = p + '.tmp'
        open(t, 'w').write(json.dumps(d, indent=2))
        os.replace(t, p)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", script, trailerShotsURL.path, id, key, json]
        do { try p.run(); p.waitUntilExit() } catch { say("Couldn't save the shot: \(error.localizedDescription)"); return false }
        if p.terminationStatus != 0 { say("Couldn't save \(id) (shots.json)"); return false }
        return true
    }
    /// Puts a video on a shot: copied into the trailer's video folder unless it's already in Kitchen.
    func setTrailerVideo(_ s: TrailerShot, from url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) else { say("That is not a video."); return false }
        var src = url
        if !url.path.hasPrefix(kitchen.path + "/") {
            let dir = trailerPanels.appendingPathComponent("video")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dst = dir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: dst.path) { try? FileManager.default.removeItem(at: dst) }
            do { try FileManager.default.copyItem(at: url, to: dst) } catch { say("Couldn't copy the video: \(error.localizedDescription)"); return false }
            src = dst
        }
        let rel = String(src.path.dropFirst(kitchen.path.count + 1))
        guard editShot(s.id, "video", rel) else { return false }
        say("\(s.id) plays \(src.lastPathComponent)"); return true
    }
}

extension TrailerAudio {
    /// The playhead right now, for drawing every frame (the published clock ticks 20 times a second).
    func now() -> Double { playerTime() ?? clock.time }
}

// MARK: - Framing a shot: the episode beats' control, saved through "zoom" (a still is start = end)

extension BeatFrame {
    /// The frame as [x0, y0, x1, y1] fractions of the picture (16:9 in a 16:9 picture).
    var rect: [Double] {
        let c = clamped(), h = 0.5 / c.scale
        return [c.x - h, c.y - h, c.x + h, c.y + h].map { ($0 * 10000).rounded() / 10000 }
    }
    init(rect r: [Double]) {
        self.init()
        guard r.count == 4 else { return }
        let side = max(0.01, max(r[2] - r[0], r[3] - r[1]))
        scale = 1 / side; x = (r[0] + r[2]) / 2; y = (r[1] + r[3]) / 2
    }
}

extension ShotZoom {
    /// A framed still: the same rectangle from start to end.
    static func still(_ f: BeatFrame) -> ShotZoom { let r = f.rect; return ShotZoom(start: r, end: r, ease: "inOut") }
    /// What shots.json holds: nothing for the whole picture.
    var saved: [String: Any]? {
        isFull(start) && isFull(end) ? nil : ["start": start, "end": end, "ease": ease ?? "inOut"]
    }
}

/// A shot's framing in its panel: the same control as an episode beat, and plainly which of framing or move is active.
struct ShotFraming: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    let url: URL?
    @State private var cg: CGImage?

    var moving: Bool { shot.zoom.map { !$0.isStill } ?? false }
    var frame: BeatFrame { shot.zoom.map { BeatFrame(rect: $0.start) } ?? BeatFrame() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(activeLine, systemImage: moving ? "video.fill" : frame.isFull ? "rectangle" : "crop")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(moving || !frame.isFull ? Color.gold : Color.soft)
                .fixedSize(horizontal: false, vertical: true)
            if let cg {
                FrameControl(image: Image(decorative: cg, scale: 1), saved: frame, canReset: shot.zoom != nil && !moving,
                             caption: moving ? "Showing the move's start frame. This shot has a camera move, so its framing is locked."
                                             : "Drag to move, pinch or slide to zoom. This framing is for \(shot.id) only; it shows on its card, in Watch trailer and in the export.",
                             locked: moving, overPicture: AnyView(RunStatusOverlay(kie: tm.kie, id: shot.id)),
                             commit: { save(.still($0)) }, reset: { save(.full) })
            } else {
                PanelImage(url: url, maxPixel: 1600, missing: "\(shot.id) not drawn yet", version: store.imageVersion)
                    .overlay { RunStatusOverlay(kie: tm.kie, id: shot.id) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if moving {
                Button("Use a still framing instead") { save(.still(frame)) }.controlSize(.small)
                    .help("Removes the move and holds its start frame")
            }
        }
        .task(id: "\(url?.path ?? "")|\(store.imageVersion)") {
            guard let url else { cg = nil; return }
            let k = PictureCache.key(url, nil, 1600, store.imageVersion)
            if let hit = PictureCache.shared.get(k) { cg = hit; return }
            let img = await Task.detached(priority: .userInitiated) { PictureCache.load(url, crop: nil, maxPixel: 1600) }.value
            if let img { PictureCache.shared.set(k, img) }
            cg = img
        }
    }
    var activeLine: String {
        if moving { return "Active: camera move, from start to end. Still framing is off." }
        if frame.isFull { return "Active: the whole picture. No framing, no move." }
        return String(format: "Active: still framing at %.1f×. No move.", frame.scale)
    }
    func save(_ z: ShotZoom) { if store.editShot(shot.id, "zoom", z.saved) { tm.reload(store) } }
}

// MARK: - Editing the move and the transition (in the shot's panel)

struct ZoomEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    let url: URL?
    let length: Double
    @State var zoom = ShotZoom.full
    @State var editing = 0          // 0 start, 1 end
    @State var drawing: [Double]?
    @State var previewing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Camera move")
                Spacer()
                Picker("", selection: $editing) { Text("Start").tag(0); Text("End").tag(1) }.pickerStyle(.segmented).frame(width: 140)
            }
            Text("Drag a box on the picture for the \(editing == 0 ? "start" : "end") frame. Both stay 16:9. The card shows the start; the trailer moves from start to end over the shot.")
                .font(.system(size: 11)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    PanelImage(url: url, maxPixel: 1600, missing: "No picture yet", version: store.imageVersion)
                    box(zoom.start, g.size, Color.done, "START")
                    box(zoom.end, g.size, Color.gold, "END")
                    if let d = drawing { box(d, g.size, .white, "", dash: true) }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 3).onChanged { v in
                    drawing = rect(from: v.startLocation, to: v.location, in: g.size)
                }.onEnded { _ in
                    if let d = drawing { if editing == 0 { zoom.start = d } else { zoom.end = d }; save() }
                    drawing = nil
                })
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Picker("Ease", selection: Binding(get: { zoom.ease ?? "inOut" }, set: { zoom.ease = $0; save() })) {
                    Text("Ease in-out").tag("inOut"); Text("Linear").tag("linear")
                }.fixedSize()
                Button("Full frame") { if editing == 0 { zoom.start = fullFrame } else { zoom.end = fullFrame }; save() }
                    .help("Set the \(editing == 0 ? "start" : "end") frame back to the whole picture")
                Button("Remove move") { zoom.end = zoom.start; save() }.help("No move: holds the start frame")
                Spacer()
                Button(previewing ? "Stop" : "Preview") { previewing.toggle() }
            }.controlSize(.small)
            if previewing {
                TimelineView(.animation) { ctx in
                    let len: Double = Swift.max(1.0, length)
                    let now: Double = ctx.date.timeIntervalSinceReferenceDate
                    let p: Double = now.truncatingRemainder(dividingBy: len + 0.6) / len
                    PanelImage(url: url, maxPixel: 1600, region: zoom.at(min(1, p)), version: store.imageVersion)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onAppear { zoom = shot.zoom ?? .full }
        .onChange(of: shot.id) { _, _ in zoom = shot.zoom ?? .full; previewing = false }
        .onChange(of: shot.zoom) { _, z in zoom = z ?? .full }     // the framing above changed it
    }

    func box(_ r: [Double], _ s: CGSize, _ c: Color, _ label: String, dash: Bool = false) -> some View {
        let f = CGRect(x: r[0] * s.width, y: r[1] * s.height, width: (r[2] - r[0]) * s.width, height: (r[3] - r[1]) * s.height)
        return Rectangle().stroke(c, style: StrokeStyle(lineWidth: 2, dash: dash ? [5] : []))
            .frame(width: f.width, height: f.height)
            .overlay(alignment: .topLeading) {
                if !label.isEmpty { Text(label).font(.system(size: 9, weight: .bold)).padding(3).background(c).foregroundStyle(Color.dark) }
            }
            .offset(x: f.minX, y: f.minY)
            .allowsHitTesting(false)
    }
    /// A 16:9 box from where the drag started toward the pointer, kept inside the picture.
    func rect(from a: CGPoint, to b: CGPoint, in s: CGSize) -> [Double] {
        let ax = Double(a.x / s.width), ay = Double(a.y / s.height), bx = Double(b.x / s.width), by = Double(b.y / s.height)
        var side = max(abs(bx - ax), abs(by - ay))            // in a 16:9 box, a 16:9 frame has equal width and height fractions
        side = min(1, max(0.08, side))
        var x0 = bx < ax ? ax - side : ax, y0 = by < ay ? ay - side : ay
        x0 = min(1 - side, max(0, x0)); y0 = min(1 - side, max(0, y0))
        return [x0, y0, x0 + side, y0 + side].map { (v: Double) in (v * 10000).rounded() / 10000 }
    }
    func save() {
        if store.editShot(shot.id, "zoom", zoom.saved) { tm.reload(store) }
    }
}

struct TransitionEditor: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    @State var kind = TransitionKind.cut
    @State var duration = 0.5
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow("Transition into the next shot")
            HStack(spacing: 10) {
                Picker("", selection: Binding(get: { kind }, set: { kind = $0; save() })) {
                    ForEach(TransitionKind.allCases) { Text($0.label).tag($0) }
                }.fixedSize()
                if kind != .cut {
                    Slider(value: $duration, in: 0.1...2, step: 0.1) { Text("") } onEditingChanged: { if !$0 { save() } }
                        .frame(maxWidth: 160)
                    Text(String(format: "%.1f s", duration)).monospacedDigit().font(.system(size: 11)).foregroundStyle(Color.soft)
                }
            }.controlSize(.small)
        }
        .onAppear { load() }
        .onChange(of: shot.id) { _, _ in load() }
    }
    func load() { kind = TransitionKind(rawValue: shot.transition?.type ?? "cut") ?? .cut; duration = shot.transition?.duration ?? 0.5 }
    func save() {
        let v: Any? = kind == .cut ? nil : ["type": kind.rawValue, "duration": (duration * 10).rounded() / 10]
        if store.editShot(shot.id, "transition", v) { tm.reload(store) }
    }
}

/// A shot's video slot in its panel: choose, show in Finder, remove.
struct VideoControls: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    @State var target = false
    var body: some View {
        let url = tm.files[shot.id]?.video
        VStack(alignment: .leading, spacing: 6) {
            HStack { Eyebrow("Video"); Spacer(); if let url { RevealButton(url: url) } }
            Text(url.map { "Plays \($0.lastPathComponent) in this shot's slot, in sync with the recording. The sketch and painting stay underneath." }
                 ?? "Drop a video (.mp4, .mov) here or on the card to play it in this shot's slot.")
                .font(.system(size: 11)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(target ? Color.gold : Color.line, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                .fileDrop(targeted: $target) { u in if store.setTrailerVideo(shot, from: u) { tm.reload(store) } }
            if url != nil { VideoTiming(shot: shot) }
            HStack(spacing: 6) {
                Button("Choose video…") { nav.choose([.movie]) { u in if store.setTrailerVideo(shot, from: u) { tm.reload(store) } } }
                if url != nil { Button("Remove video", role: .destructive) { if store.editShot(shot.id, "video", nil) { tm.reload(store) } }
                    .help("Takes the video off this shot (the file stays where it is)") }
            }.controlSize(.small)
        }
    }
}

// MARK: - Video on a card: its first frame, playing muted while the pointer is on it

struct VideoThumb: View {
    let url: URL
    @State var poster: CGImage?
    @State var hover = false
    var body: some View {
        Color(hex: 0x2a2520).aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
            .overlay {
                if hover { OnceVideo(url: url).allowsHitTesting(false) }
                else if let poster { Image(decorative: poster, scale: 1).resizable().scaledToFill() }
            }
            .overlay(alignment: .center) {
                if !hover { Image(systemName: "play.circle.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 4) }
            }
            .clipped()
            .onHover { hover = $0 }
            .task(id: url) {
                let k = "poster|\(url.path)"
                if let hit = PictureCache.shared.get(k) { poster = hit; return }
                let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                gen.appliesPreferredTrackTransform = true; gen.maximumSize = CGSize(width: 1000, height: 1000)
                if let cg = try? await gen.image(at: .zero).image { PictureCache.shared.set(k, cg); poster = cg }
            }
    }
}

/// A muted video that plays once and stays on its last frame, filling its box.
struct OnceVideo: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> LoopingVideo.V {
        let v = LoopingVideo.V(); let p = AVPlayer(url: url); p.isMuted = true; p.actionAtItemEnd = .pause
        v.layerPlayer.player = p; p.play(); return v
    }
    func updateNSView(_ v: LoopingVideo.V, context: Context) {}
    static func dismantleNSView(_ v: LoopingVideo.V, coordinator: ()) { v.layerPlayer.player?.pause() }
}

/// A muted looping video, filling its box.
struct LoopingVideo: NSViewRepresentable {
    let url: URL
    final class V: NSView {
        let layerPlayer = AVPlayerLayer()
        var looper: AVPlayerLooper?
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.addSublayer(layerPlayer); layerPlayer.videoGravity = .resizeAspectFill }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); layerPlayer.frame = bounds }
    }
    func makeNSView(context: Context) -> V {
        let v = V(); let q = AVQueuePlayer(); q.isMuted = true
        v.looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url)); v.layerPlayer.player = q; q.play(); return v
    }
    func updateNSView(_ v: V, context: Context) {}
    static func dismantleNSView(_ v: V, coordinator: ()) { v.layerPlayer.player?.pause() }
}

/// Where a shot's video should be `t` seconds into its slot: it plays at normal speed (never stretched), then holds
/// its last frame once the slot outlasts it. Returns the time and whether it's holding.
func videoTime(_ t: Double, length: Double) -> (Double, Bool) {
    guard length.isFinite, length > 0 else { return (max(0, t), false) }
    let last = max(0, length - 1.0 / 30)
    return t >= last ? (last, true) : (max(0, t), false)
}

/// A shot's video settings: trim, what happens when it ends before its slot, and its sound.
struct VideoPlan: Equatable {
    var inPoint = 0.0
    var outPoint: Double? = nil
    var end = "hold"            // "hold", "fade" (freeze, then fade to black) or "loop"
    var volume = 0.0            // 0 = off
    /// The trimmed length.
    func length(_ file: Double) -> Double { max(0.05, min(file, outPoint ?? file) - inPoint) }
    /// Where the video is `into` seconds into its slot, whether it's holding, and how far a fade to black has gone.
    func frame(_ into: Double, file: Double) -> (time: Double, hold: Bool, black: Double) {
        guard file.isFinite, file > 0 else { return (inPoint + max(0, into), false, 0) }
        let len = length(file), last = inPoint + len - 1.0 / 30
        if into < len { return (inPoint + max(0, into), false, 0) }
        switch end {
        case "loop": return (inPoint + into.truncatingRemainder(dividingBy: len), false, 0)
        case "fade": return (last, true, min(1, (into - len) / 0.6))
        default: return (last, true, 0)
        }
    }
}
extension TrailerShot {
    var videoPlan: VideoPlan { VideoPlan(inPoint: video_in ?? 0, outPoint: video_out, end: video_end ?? "hold", volume: video_volume ?? 0) }
}
/// 75.5 -> "1:15.5", 4 -> "0:04".
func fmtTime(_ s: Double) -> String {
    let m = Int(s) / 60, r = s - Double(m * 60)
    return abs(r - r.rounded()) < 0.05 ? String(format: "%d:%02d", m, Int(r.rounded())) : String(format: "%d:%04.1f", m, r)
}

/// A video that follows the trailer's playhead: `time` is where it should be, `playing` whether the recording runs.
struct SyncedVideo: NSViewRepresentable {
    let url: URL
    let time: Double
    let playing: Bool
    var plan = VideoPlan()
    final class V: NSView {
        let layerPlayer = AVPlayerLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer?.addSublayer(layerPlayer); layerPlayer.videoGravity = .resizeAspect }
        required init?(coder: NSCoder) { fatalError() }
        override func layout() { super.layout(); layerPlayer.frame = bounds }
    }
    func makeNSView(context: Context) -> V { let v = V(); let p = AVPlayer(url: url); p.isMuted = true; v.layerPlayer.player = p; return v }
    func updateNSView(_ v: V, context: Context) {
        guard let p = v.layerPlayer.player else { return }
        if (p.currentItem?.asset as? AVURLAsset)?.url != url { p.replaceCurrentItem(with: AVPlayerItem(url: url)) }
        let length = p.currentItem?.duration.seconds ?? .nan
        let (want, hold, _) = plan.frame(time, file: length)
        p.isMuted = plan.volume <= 0; p.volume = Float(plan.volume / 100)
        let have = p.currentTime().seconds
        if !have.isFinite || abs(have - want) > 0.25 { p.seek(to: CMTime(seconds: want, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        // a slot longer than its video holds the video's last frame; never the sketch or painting underneath
        let run = playing && !hold
        if run && p.rate == 0 { p.play() } else if !run && p.rate != 0 { p.pause() }
    }
    static func dismantleNSView(_ v: V, coordinator: ()) { v.layerPlayer.player?.pause() }
}

// MARK: - Watching the trailer: every shot with its move and transition, in time with the recording

/// Full-size frames for playback, loaded off the main thread at 3840 px so zoomed shots stay sharp. Keeps the few
/// around the playhead.
final class FrameLoader: ObservableObject {
    @Published private(set) var frames: [String: CGImage] = [:]
    private var loading: Set<String> = []
    func image(_ url: URL?) -> CGImage? { url.flatMap { frames[$0.path] } }
    /// Called while drawing: never changes anything right away (that would redraw in a loop); it schedules the loads.
    func want(_ urls: [URL]) {
        let need = urls.filter { frames[$0.path] == nil && !loading.contains($0.path) }
        guard !need.isEmpty else { return }
        for u in need { loading.insert(u.path) }
        DispatchQueue.main.async { self.load(need, keep: Set(urls.map(\.path))) }
    }
    private func load(_ need: [URL], keep: Set<String>) {
        if frames.count > 6 { frames = frames.filter { keep.contains($0.key) } }
        for u in need {
            Task.detached(priority: .userInitiated) { [weak self] in
                let cg = PictureCache.load(u, crop: nil, maxPixel: 3840)
                await MainActor.run { self?.loading.remove(u.path); if let cg { self?.frames[u.path] = cg } }
            }
        }
    }
}

struct TrailerWatch: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    @StateObject var loader = FrameLoader()
    @ObservedObject var audio: TrailerAudio
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let t = tm.trailer {
                GeometryReader { g in
                    TimelineView(.animation(paused: !audio.playing)) { _ in
                        WatchFrame(loader: loader, audio: audio, trailer: t, time: audio.now(), size: fit(g.size))
                            .frame(width: g.size.width, height: g.size.height)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let t = tm.trailer { TrailerTransport(audio: audio, clock: audio.clock, length: t.audio_seconds).padding(12).background(.black.opacity(0.5), in: Capsule()).padding(20) }
        }
        .overlay(alignment: .topLeading) {
            // the playhead and the shot on screen, so a handover (T01 to T02, into T25) can be seen exactly
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                let t = audio.now()
                Text("\(fmtTime(t))  ·  \(trailerShot(at: t, audio.timeline) ?? "–")").font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .padding(.horizontal, 12).padding(.vertical, 6).background(.black.opacity(0.6), in: Capsule()).foregroundStyle(.white).padding(16)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).frame(width: 34, height: 34).background(.ultraThinMaterial, in: Circle())
            }.buttonStyle(.plain).padding(16).help("Close (Esc)")
        }
        .onAppear { if !audio.playing { audio.toggle() } }   // starts wherever the playhead was put (Play this shot)
        .onDisappear { audio.stop() }
    }

    func fit(_ s: CGSize) -> CGSize { s.width / s.height > 16 / 9 ? CGSize(width: s.height * 16 / 9, height: s.height) : CGSize(width: s.width, height: s.width * 9 / 16) }

}

/// What one shot contributes to a frame. Watch trailer and Export both draw this, so they can't drift apart.
enum ShotLayer {
    case video(URL, into: Double, plan: VideoPlan, black: Double, shot: String)
    case montage(URL?, tile: String, shot: String)
    case picture(URL?, region: [Double], logo: Bool, subscribe: Bool, shot: String)
    /// Identical signatures draw identical pictures, so Export can reuse the last frame. A video's includes where it is in the file.
    func signature(fileLength: Double?) -> String {
        switch self {
        case .video(let u, let into, let plan, let black, _):
            let t = plan.frame(into, file: fileLength ?? .nan).time
            return "v|\(u.path)|\((t * 1000).rounded())|\((black * 100).rounded())"
        case .montage(let u, let tile, _): return "m|\(u?.path ?? tile)"
        case .picture(let u, let r, let logo, let sub, let id): return "p|\(u?.path ?? id)|\(r.map { ($0 * 100000).rounded() })|\(logo)|\(sub)"
        }
    }
}

/// The frame at one time: the shot on screen, and the next one while its transition runs.
struct TrailerFramePlan {
    var shot: String
    var a: ShotLayer
    var b: ShotLayer?
    var kind: TransitionKind
    var q: Double
}

/// Decides what's on screen at any moment: the shot, how far through its move, its video's position, its transition.
struct TrailerPlanner {
    let trailer: TrailerFile
    let timeline: [String: (Double, Double)]
    let files: [String: PanelFiles]
    let videoLengths: [String: Double]
    let logoShots: Set<String>

    func plan(at time: Double) -> TrailerFramePlan? {
        guard let id = trailerShot(at: time, timeline), let s = trailer.shots.first(where: { $0.id == id }), let span = timeline[id] else { return nil }
        let p = (time - span.0) / max(0.01, span.1 - span.0)
        let here = layer(s, p, time - span.0)
        let nextID = trailerShot(at: span.1 + 0.001, timeline)
        if let next = nextID.flatMap({ n in n == id ? nil : trailer.shots.first { $0.id == n } }),
           let tr = s.transition, let kind = TransitionKind(rawValue: tr.type), kind != .cut, time > span.1 - tr.duration {
            return TrailerFramePlan(shot: id, a: here, b: layer(next, 0, 0), kind: kind, q: (time - (span.1 - tr.duration)) / tr.duration)
        }
        return TrailerFramePlan(shot: id, a: here, b: nil, kind: .cut, q: 0)
    }
    func layer(_ s: TrailerShot, _ p: Double, _ into: Double) -> ShotLayer {
        if let v = files[s.id]?.video {
            let plan = s.videoPlan
            return .video(v, into: into, plan: plan, black: plan.frame(into, file: videoLengths[s.id] ?? .nan).black, shot: s.id)
        }
        if s.kind == "montage", let ps = s.montage, !ps.isEmpty {
            // her Meridian days, speeding up across the pause
            let i = min(ps.count - 1, Int(pow(min(1, max(0, p)), 0.6) * Double(ps.count)))
            return .montage(files["\(ps[i].episode)/\(ps[i].id)"]?.shown, tile: ps[i].id, shot: s.id)
        }
        return .picture(files[s.id]?.shown, region: (s.zoom ?? .full).at(p), logo: s.video == nil && logoShots.contains(s.id), subscribe: s.logo != nil, shot: s.id)
    }
}

/// One frame of the trailer at a time, for the player: the plan, drawn with live pictures and videos.
struct WatchFrame: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let loader: FrameLoader
    let audio: TrailerAudio
    let trailer: TrailerFile
    let time: Double
    let size: CGSize
    var body: some View {
        let planner = TrailerPlanner(trailer: trailer, timeline: audio.timeline, files: tm.files, videoLengths: tm.videoLengths, logoShots: store.logoShots(trailer))
        if let plan = planner.plan(at: time) {
            let _ = loader.want([plan.a, plan.b].compactMap { l in
                if case .picture(let u, _, _, _, _)? = l { return u }
                return nil
            })
            if let b = plan.b { TrailerBlend(k: plan.kind, q: plan.q, a: layer(plan.a), b: layer(b), size: size) }
            else { layer(plan.a) }
        } else {
            Color.black.frame(width: size.width, height: size.height)
        }
    }
    @ViewBuilder func layer(_ l: ShotLayer) -> some View {
        switch l {
        case .video(let u, let into, let plan, let black, _):
            SyncedVideo(url: u, time: into, playing: audio.playing, plan: plan).frame(width: size.width, height: size.height)
                .overlay { if black > 0 { Color.black.opacity(black) } }
        case .montage(let u, _, _):
            PanelImage(url: u, maxPixel: 1600, version: store.imageVersion).frame(width: size.width, height: size.height)
        case .picture(let u, let r, let logo, let sub, _):
            ZStack {
                Color.black
                if let cg = loader.image(u) { Framed(cg: cg, region: r) }
                else { PanelImage(url: u, maxPixel: 1000, region: r, version: store.imageVersion) }
                ShotTitles(logo: logo ? store.logoURL : nil, subscribe: sub, version: store.imageVersion, size: size)
            }
            .frame(width: size.width, height: size.height).clipped()
        }
    }
}

/// The logo and the subscribe line over a shot, in the same place in the player and the export.
struct ShotTitles: View {
    let logo: URL?
    var logoImage: CGImage? = nil        // already loaded (the export)
    let subscribe: Bool
    var version = 0
    let size: CGSize
    var body: some View {
        if logo != nil || logoImage != nil {
            LogoOverlay(url: logo, version: version, ready: logoImage).padding(.horizontal, size.width * 0.107).padding(.vertical, size.height * 0.095)
        }
        if subscribe {
            VStack { Spacer(); Text("SUBSCRIBE FOR EPISODE ONE").font(.system(size: size.width * 0.02, weight: .bold)).tracking(size.width * 0.005).foregroundStyle(Color.dark).padding(.bottom, size.height * 0.03) }
        }
    }
}

/// A transition between two shots, q from 0 to 1.
struct TrailerBlend<A: View, B: View>: View {
    let k: TransitionKind
    let q: Double
    let a: A
    let b: B
    let size: CGSize
    var body: some View {
        switch k {
        case .crossfade: ZStack { a; b.opacity(q) }
        case .dipBlack, .dipWhite:
            ZStack { if q < 0.5 { a } else { b }; (k == .dipBlack ? Color.black : Color.white).opacity(1 - abs(q - 0.5) * 2) }
        case .pushLeft: ZStack { a.offset(x: -q * size.width); b.offset(x: (1 - q) * size.width) }.clipped()
        case .pushRight: ZStack { a.offset(x: q * size.width); b.offset(x: -(1 - q) * size.width) }.clipped()
        case .zoomThrough: ZStack { a.scaleEffect(1 + 2 * q).opacity(1 - q); b.scaleEffect(0.85 + 0.15 * q).opacity(q) }.clipped()
        case .cut: a
        }
    }
}

/// A picture showing just `region` ([x0, y0, x1, y1]) of itself, filling its box.
struct Framed: View {
    let cg: CGImage
    let region: [Double]
    var body: some View {
        GeometryReader { g in
            let rw = max(0.01, region[2] - region[0]), rh = max(0.01, region[3] - region[1])
            Image(decorative: cg, scale: 1).resizable()
                .frame(width: g.size.width / rw, height: g.size.height / rh)
                .offset(x: -region[0] * g.size.width / rw, y: -region[1] * g.size.height / rh)
        }
        .clipped()
    }
}

// MARK: - A video shot's timing: its slot, trim, what happens at its end, its sound, and play buttons

/// "Video 4.04 s in a 4.0 s slot: plays fully" — what the video does in its slot, on the card and in the panel.
struct VideoStatusLine: View {
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    let span: (Double, Double)?
    var body: some View {
        if let text = Self.text(shot, span: span, file: tm.videoLengths[shot.id]) {
            Label(text, systemImage: "film").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.gold)
        }
    }
    static func text(_ shot: TrailerShot, span: (Double, Double)?, file: Double?) -> String? {
        guard let file, let span else { return nil }
        let plan = shot.videoPlan, len = plan.length(file), slot = span.1 - span.0
        let head = String(format: "Video %.2f s in a %.1f s slot: ", len, slot)
        if abs(len - slot) <= 0.1 { return head + "plays fully" }
        if len > slot { return head + String(format: "the last %.1f s is cut off", len - slot) }
        let rest = slot - len
        switch plan.end {
        case "loop": return head + String(format: "loops to fill %.1f s", rest)
        case "fade": return head + String(format: "freezes, then fades to black for %.1f s", rest)
        default: return head + String(format: "holds last frame %.1f s", rest)
        }
    }
}

struct VideoTiming: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    @State var start = 0.0
    @State var end = 0.0
    @State var inPoint = 0.0
    @State var outPoint = 0.0
    @State var endMode = "hold"
    @State var volume = 0.0
    @State var preview: [String: CGImage] = [:]

    var body: some View {
        let file = tm.videoLengths[shot.id] ?? 0
        VStack(alignment: .leading, spacing: 10) {
            VideoStatusLine(shot: shot, span: shot.span.map { ($0.0, $0.1 ?? $0.0) })
            // the slot
            Eyebrow("Shot time in the trailer", color: .soft)
            HStack(spacing: 8) {
                timeField("Start", $start); timeField("End", $end)
                Button("Save time") { saveTime() }.disabled(!timeChanged).help("Writes \"\(fmtTime(start))-\(fmtTime(end))\" to this shot in shots.json")
            }
            ForEach(neighbourNotes, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle($0.contains("overlap") ? Color.red2 : Color.soft) }
            // trim
            if file > 0 {
                Eyebrow("Trim the video", color: .soft)
                trimRow("In", $inPoint, 0...file, key: "video_in")
                trimRow("Out", $outPoint, 0...file, key: "video_out")
            }
            HStack(spacing: 10) {
                Text("When the video ends early").font(.system(size: 11)).foregroundStyle(Color.soft)
                Picker("", selection: Binding(get: { endMode }, set: { endMode = $0; save("video_end", $0 == "hold" ? nil : $0) })) {
                    Text("Hold last frame").tag("hold"); Text("Freeze, then fade to black").tag("fade"); Text("Loop").tag("loop")
                }.fixedSize()
            }
            HStack(spacing: 10) {
                Text("Video sound in Watch trailer").font(.system(size: 11)).foregroundStyle(Color.soft)
                Slider(value: $volume, in: 0...100, step: 5) { Text("") } onEditingChanged: { if !$0 { save("video_volume", volume <= 0 ? nil : volume) } }
                    .frame(maxWidth: 150)
                Text(volume <= 0 ? "Off" : "\(Int(volume))%").font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.soft)
            }
            HStack(spacing: 8) {
                Button { play(from: max(0, start - 5)) } label: { Label("Play from 5 s before", systemImage: "gobackward.5") }
                Button { play(from: start) } label: { Label("Play this shot", systemImage: "play.fill") }
            }
        }
        .controlSize(.small)
        .onAppear { load() }
        .onChange(of: shot.id) { _, _ in load() }
    }

    func timeField(_ label: String, _ v: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(Color.soft)
            TextField("", value: v, format: .number.precision(.fractionLength(0...2))).frame(width: 56).textFieldStyle(.roundedBorder)
            Stepper("", value: v, in: 0...600, step: 0.1).labelsHidden()
            Text(fmtTime(v.wrappedValue)).font(.system(size: 10)).monospacedDigit().foregroundStyle(Color.mute)
        }
    }
    func trimRow(_ label: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, key: String) -> some View {
        HStack(spacing: 8) {
            Group {
                if let cg = preview[key] { Image(decorative: cg, scale: 1).resizable().scaledToFit() } else { Color(hex: 0x2a2520) }
            }.frame(width: 96, height: 54).clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label).font(.system(size: 11)).frame(width: 26, alignment: .leading)
            Slider(value: v, in: range) { Text("") } onEditingChanged: { editing in
                if !editing { save(key, (key == "video_in" && v.wrappedValue <= 0.01) || (key == "video_out" && v.wrappedValue >= range.upperBound - 0.01) ? nil : (v.wrappedValue * 100).rounded() / 100) }
            }
            Text(String(format: "%.2f s", v.wrappedValue)).font(.system(size: 11)).monospacedDigit().foregroundStyle(Color.soft).frame(width: 52)
        }
        .task(id: (v.wrappedValue * 10).rounded()) { await frame(key, at: v.wrappedValue) }
    }
    func frame(_ key: String, at t: Double) async {
        guard let u = tm.files[shot.id]?.video else { return }
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: u)); g.appliesPreferredTrackTransform = true; g.maximumSize = CGSize(width: 240, height: 240)
        g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        if let cg = try? await g.image(at: CMTime(seconds: min(t, max(0, (tm.videoLengths[shot.id] ?? t) - 0.04)), preferredTimescale: 600)).image { preview[key] = cg }
    }

    var timeChanged: Bool { guard let sp = shot.span else { return true }; return abs(sp.0 - start) > 0.001 || abs((sp.1 ?? sp.0) - end) > 0.001 }
    /// The shots just before and after, and whether this slot overlaps them or leaves a gap.
    var neighbourNotes: [String] {
        guard let shots = tm.trailer?.shots else { return [] }
        let timed = shots.compactMap { s in s.span.map { (s.id, $0.0, $0.1 ?? $0.0) } }.filter { $0.0 != shot.id }
        var out: [String] = []
        if let prev = timed.filter({ $0.1 < start }).max(by: { $0.1 < $1.1 }) {
            let d = start - prev.2
            out.append(abs(d) < 0.05 ? "Starts right as \(prev.0) ends (\(fmtTime(prev.2)))" : d < 0 ? String(format: "%@ overlaps this shot by %.1f s (%@ ends %@)", prev.0, -d, prev.0, fmtTime(prev.2)) : String(format: "Gap of %.1f s after %@ (ends %@)", d, prev.0, fmtTime(prev.2)))
        }
        if let next = timed.filter({ $0.1 > start }).min(by: { $0.1 < $1.1 }) {
            let d = next.1 - end
            out.append(abs(d) < 0.05 ? "Hands over to \(next.0) at \(fmtTime(next.1))" : d < 0 ? String(format: "This shot overlaps %@ by %.1f s (%@ starts %@)", next.0, -d, next.0, fmtTime(next.1)) : String(format: "Gap of %.1f s before %@ (starts %@)", d, next.0, fmtTime(next.1)))
        }
        return out
    }
    func load() {
        let sp = shot.span; start = sp?.0 ?? 0; end = sp?.1 ?? (sp?.0 ?? 0)
        let p = shot.videoPlan; inPoint = p.inPoint; outPoint = p.outPoint ?? (tm.videoLengths[shot.id] ?? 0); endMode = p.end; volume = p.volume
    }
    func save(_ key: String, _ v: Any?) { if store.editShot(shot.id, key, v) { tm.reload(store) } }
    func saveTime() {
        guard end > start else { store.say("End must be after start"); return }
        save("time", "\(fmtTime(start))-\(fmtTime(end))")
    }
    func play(from t: Double) { tm.audio.seek(t); tm.watching = true }
}
