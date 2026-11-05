import SwiftUI
import AVFoundation
import ImageIO

// MARK: - The Season 1 trailer (the against-the-grain skill's productions/trailer/shots.json)

struct TrailerFile: Codable { var show: String; var subtitle: String; var audio: String; var audio_seconds: Double; var audio_original: String?; var shots: [TrailerShot] }
struct TrailerShot: Codable, Identifiable {
    var id: String; var name: String; var kind: String; var time: String
    var who: String; var line: String
    var note: String?
    var keep_file: String?                   // keep: the approved panel, unchanged
    var crop_of: String?; var crop: [Double]?   // crop: [x0, y0, x1, y1] of another shot's panel, 0...1
    var montage: [MontagePanel]?             // montage: Ep 1 panels, shuffled
    var graphic: String?                     // graphic: the title card's text
    var logo: String?                        // the title card: the logo it's built from; the app adds the subscribe line
    var scene: String?                       // what the panel shows
    var zoom: ShotZoom?                      // the camera move: start and end frames
    var transition: ShotTransition?          // how it hands over to the next shot
    var video: String?                       // a video for this shot's slot, relative to Kitchen
    var video_in: Double?                    // trim: where the video starts, seconds into the file
    var video_out: Double?                   // trim: where it stops
    var video_end: String?                   // when it ends before the slot: "hold" (default), "fade", "loop"
    var video_volume: Double?                // its sound in Watch trailer, 0-100 (nil = off)
    /// "0:13-0:17" → (13, 17); "0:44" → (44, nil); "(closing)" → nil.
    var span: (Double, Double?)? {
        let parts = time.split(separator: "-").map { String($0) }
        func secs(_ s: String) -> Double? {
            let p = s.trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard p.count == 2, let m = Double(p[0]), let s = Double(p[1]) else { return nil }
            return m * 60 + s
        }
        guard let a = parts.first.flatMap(secs) else { return nil }
        return (a, parts.count > 1 ? secs(parts[1]) : nil)
    }
}
struct MontagePanel: Codable, Hashable { var episode: String; var id: String }
/// A shot's prompts (productions/trailer/prompts.json, written by `atg.py export trailer`): the 1K pencil prompt,
/// the latest fix, the 4K colorize prompt, and the images to attach to each, in order.
struct TrailerPrompt: Codable { var bw: String?; var fix: String?; var color: String?; var refs: [String: [PromptRef]]? }
struct PromptRef: Codable, Hashable { var file: String; var role: String }

extension Store {
    var kitchen: URL { dataDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static var shotsFileOverride: URL?         // -frame-test works on a copy
    var trailerShotsURL: URL {
        Store.shotsFileOverride ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/against-the-grain/productions/trailer/shots.json")
    }
    var trailerPromptsURL: URL { trailerShotsURL.deletingLastPathComponent().appendingPathComponent("prompts.json") }
    func loadTrailerPrompts() -> [String: TrailerPrompt] {
        (try? Data(contentsOf: trailerPromptsURL)).flatMap { try? JSONDecoder().decode([String: TrailerPrompt].self, from: $0) } ?? [:]
    }
    func loadTrailer() -> TrailerFile? {
        (try? Data(contentsOf: trailerShotsURL)).flatMap { try? JSONDecoder().decode(TrailerFile.self, from: $0) }
    }
    var trailerPanels: URL { kitchen.appendingPathComponent("ART/Hand Drawn Storyboards/trailer") }
    /// A panel: the 4K painting once it's in, else the 1K sketch (like scenes).
    func panelURL(_ dir: URL, _ id: String) -> URL? {
        for n in ["\(id)-painting.png", "\(id)-sketch.png"] {
            let u = dir.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
    func trailerPanelURL(_ s: TrailerShot) -> URL? {
        if let k = s.keep_file {
            let painted = trailerPanels.appendingPathComponent(k.replacingOccurrences(of: "-sketch", with: "-painting"))
            if FileManager.default.fileExists(atPath: painted.path) { return painted }
            let u = trailerPanels.appendingPathComponent(k)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return panelURL(trailerPanels, s.id)
    }
    func montageURL(_ p: MontagePanel) -> URL? { panelURL(kitchen.appendingPathComponent("ART/Hand Drawn Storyboards/\(p.episode)"), p.id) }
    /// The logo laid over the trailer: the one you dropped on the Trailer page, else the Season 1 logo in ART/Logos.
    func trailerLogo(_ t: TrailerFile) -> Image? {
        if let i = image("trailer-logo") { return i }
        return logoURL.flatMap { fileImage($0, maxPixel: 1200) }
    }
    /// The Season 1 logo file, when you haven't dropped one of your own.
    var defaultLogoURL: URL { kitchen.appendingPathComponent("ART/Logos/Against the Grain - Season 1 Logo.png") }
    /// The trailer logo shows over these shots (the first and last by default). Never over a shot with a video:
    /// its title is in the video.
    func logoShots(_ t: TrailerFile) -> Set<String> {
        let videos = Set(t.shots.filter { $0.video != nil }.map(\.id))
        return Set(state.trailerLogo ?? ["T01", t.shots.last?.id ?? "T25"]).subtracting(videos)
    }
    func toggleLogo(_ t: TrailerFile, _ id: String) {
        var s = logoShots(t); if s.contains(id) { s.remove(id) } else { s.insert(id) }
        state.trailerLogo = t.shots.map(\.id).filter { s.contains($0) }; save()
    }
}

/// When each shot is on screen in the trailer recording. Shots that share one time range split it evenly;
/// a single time ("0:44") runs to the next shot; the closing shot runs from the last time to the end.
func trailerTimeline(_ t: TrailerFile) -> [String: (Double, Double)] {
    var out: [String: (Double, Double)] = [:]
    let timed = t.shots.compactMap { s in s.span.map { (s, $0.0, $0.1) } }
    let starts = timed.map(\.1).sorted()
    var groups: [String: [TrailerShot]] = [:]
    for (s, a, b) in timed {
        let end = b ?? (starts.first { $0 > a } ?? a + 1)
        groups["\(a)-\(end)", default: []].append(s)
        out[s.id] = (a, end)
    }
    for (_, g) in groups where g.count > 1 {
        guard let (a, b) = out[g[0].id] else { continue }
        let step = (b - a) / Double(g.count)
        for (i, s) in g.enumerated() { out[s.id] = (a + step * Double(i), a + step * Double(i + 1)) }
    }
    let lastEnd = out.values.map(\.1).max() ?? 0
    if let closing = t.shots.last(where: { $0.span == nil && $0.time.contains("closing") }) {
        out[closing.id] = (lastEnd, max(lastEnd + 1, t.audio_seconds))
    }
    return out
}
/// The shot on screen at a time: the latest start, and the shortest one when two start together.
func trailerShot(at time: Double, _ tl: [String: (Double, Double)]) -> String? {
    tl.filter { time >= $0.value.0 && time < $0.value.1 }
        .max { a, b in a.value.0 != b.value.0 ? a.value.0 < b.value.0 : (a.value.1 - a.value.0) > (b.value.1 - b.value.0) }?.key
}

/// A shot's two panels on disk: the 1K pencil sketch and the 4K painting.
struct PanelFiles {
    var sketch: URL?; var painting: URL?; var video: URL? = nil
    var shown: URL? { painting ?? sketch }
    /// The file the card shows, for Show in Finder: the video, else the painting, else the sketch.
    var reveal: URL? { video ?? shown }
}

extension Store {
    /// Both panels of every shot, and the Ep 1 panels the montage uses, read once (not while drawing).
    func trailerFiles(_ t: TrailerFile) -> [String: PanelFiles] {
        let fm = FileManager.default
        func at(_ dir: URL, _ name: String) -> URL? { let u = dir.appendingPathComponent(name); return fm.fileExists(atPath: u.path) ? u : nil }
        var out: [String: PanelFiles] = [:]
        for s in t.shots {
            out[s.id] = PanelFiles(sketch: at(trailerPanels, s.keep_file ?? "\(s.id)-sketch.png"), painting: at(trailerPanels, "\(s.id)-painting.png"),
                                   video: s.video.flatMap { at(kitchen, $0) })
            for p in s.montage ?? [] {
                let dir = kitchen.appendingPathComponent("ART/Hand Drawn Storyboards/\(p.episode)")
                let f = PanelFiles(sketch: at(dir, "\(p.id)-sketch.png"), painting: at(dir, "\(p.id)-painting.png"))
                out["\(p.episode)/\(p.id)"] = f; out[p.id] = f      // a tile is selectable by its own id too
            }
        }
        return out
    }
    /// The logo: yours if you dropped one on the Trailer page, else the Season 1 logo file (no file reads while drawing).
    var logoURL: URL? { userFile("trailer-logo") ?? defaultLogoURL }
    /// Saves a dropped picture as the shot's panel, `<ID>-sketch.png` or `<ID>-painting.png` in the trailer folder.
    /// Whatever was there moves to `_replaced/` first, so nothing is lost.
    @discardableResult
    func setTrailerPanel(_ s: TrailerShot, painting: Bool, from url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { say("That is not an image file."); return false }
        let name = painting ? "\(s.id)-painting.png" : (s.keep_file ?? "\(s.id)-sketch.png")
        let fm = FileManager.default, dst = trailerPanels.appendingPathComponent(name)
        do {
            try fm.createDirectory(at: trailerPanels, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try moveAside(dst) }
            if url.pathExtension.lowercased() == "png" { try fm.copyItem(at: url, to: dst) }
            else {
                // anything else is written out as a PNG, so the name stays <ID>-sketch.png
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let out = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil) else { say("Couldn't read that picture."); return false }
                CGImageDestinationAddImage(out, cg, nil)
                guard CGImageDestinationFinalize(out) else { say("Couldn't save \(name)."); return false }
            }
            refreshFiles(); say("Saved \(name)")
            return true
        } catch { say("Couldn't save \(name): \(error.localizedDescription)"); return false }
    }
    /// Takes a panel out of use: it moves to `_replaced/`, never deleted.
    func removeTrailerPanel(_ url: URL) {
        do { try moveAside(url); refreshFiles(); say("Moved \(url.lastPathComponent) to _replaced") }
        catch { say("Couldn't move it: \(error.localizedDescription)") }
    }
    private func moveAside(_ url: URL) throws {
        let dir = trailerPanels.appendingPathComponent("_replaced")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(stamp).png"))
    }
    /// True when a picture has real color in it (a painting), false for a black-and-white sketch.
    static func isColor(_ url: URL) -> Bool {
        guard let cg = PictureCache.load(url, crop: nil, maxPixel: 64), let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data), cg.bitsPerPixel >= 24 else { return true }
        let bpp = cg.bitsPerPixel / 8, n = cg.width * cg.height
        var total = 0
        for y in 0..<cg.height { for x in 0..<cg.width {
            let i = y * cg.bytesPerRow + x * bpp
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            total += max(r, g, b) - min(r, g, b)
        } }
        return Double(total) / Double(max(1, n)) > 10
    }
}

extension Notification.Name { static let trailerStep = Notification.Name("trailerStep") }

/// The playhead's time, kept apart so only the transport redraws while the trailer plays.
final class TrailerClock: ObservableObject { @Published var time: Double = 0 }

/// Plays the trailer recording and follows the shot under the playhead.
final class TrailerAudio: ObservableObject {
    @Published var current: String?          // the shot on screen; changes only when the shot changes
    @Published var playing = false
    let clock = TrailerClock()
    var timeline: [String: (Double, Double)] = [:]
    private var player: AVPlayer?
    private var observer: Any?
    func load(_ url: URL) {
        guard player == nil else { return }
        let p = AVPlayer(url: url); player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.update(t.seconds)
            if let d = p.currentItem?.duration, d.isNumeric, t.seconds >= d.seconds - 0.05, self.playing { self.playing = false }
        }
    }
    private func update(_ t: Double) {
        clock.time = t
        let now = trailerShot(at: t, timeline)
        if now != current { current = now }
    }
    /// A different recording: the old player goes, and the new one starts stopped at the top.
    func reload(_ url: URL) {
        stop()
        if let o = observer { player?.removeTimeObserver(o); observer = nil }
        player = nil; update(0); load(url)
    }
    func toggle() {
        guard let p = player else { return }
        if playing { p.pause(); playing = false; return }
        NotificationCenter.default.post(name: .readThroughStarted, object: nil)   // pauses the season player
        if let d = p.currentItem?.duration, d.isNumeric, clock.time >= d.seconds - 0.1 { seek(0) }
        p.play(); playing = true
    }
    func playerTime() -> Double? { player.map { $0.currentTime().seconds }.flatMap { $0.isFinite ? $0 : nil } }
    func seek(_ t: Double) { player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero); update(t) }
    func stop() { player?.pause(); if playing { playing = false } }
    var muted: Bool { get { player?.isMuted ?? false } set { player?.isMuted = newValue } }
    deinit { if let o = observer { player?.removeTimeObserver(o) } }
}

/// The trailer's shot list, prompts and panel files, the player and the selected shot. One for the app, so the shot's
/// panel and full-size picture use the window's own side panel and viewer, like beats.
@MainActor
final class TrailerModel: ObservableObject {
    @Published var trailer: TrailerFile?
    @Published var prompts: [String: TrailerPrompt] = [:]
    @Published var files: [String: PanelFiles] = [:]
    @Published var selected: String?
    @Published var watching = false        // the trailer playing full window, shot by shot
    @Published var picked: Set<String> = []   // shots ticked for "Generate selected"
    @Published var beatPicks: Set<Int> = []   // beats ticked on the Beats page
    @Published var beatPrompt: Int?           // the beat whose prompt sheet is open
    @Published var confirming: [GenJob]?      // the "Is this right?" sheet
    @Published var editing: EditRequest?      // the Edit sheet
    @Published var wantsPanel = 0             // bumps when a run starts, to open the side panel on it
    var lastPicked: String?
    @Published var tiles: [MontageTile] = []                  // the flashback's Ep 1 panels
    @Published var tilePrompts: [String: TrailerPrompt] = [:] // montage-prompts.json
    @Published var videoLengths: [String: Double] = [:]       // shot id -> its video's length, read once
    let audio = TrailerAudio()
    let kie = KieRunner()
    var shot: TrailerShot? { trailer?.shots.first { $0.id == selected } }
    func reload(_ store: Store) {
        trailer = store.loadTrailer(); prompts = store.loadTrailerPrompts(); tilePrompts = store.loadMontagePrompts(); store.refreshFiles()
        if let t = trailer {
            files = store.trailerFiles(t); audio.timeline = trailerTimeline(t); tiles = store.montageTiles(t)
            for s in t.shots { if let v = files[s.id]?.video, videoLengths[s.id] == nil {
                Task { if let d = try? await AVURLAsset(url: v).load(.duration).seconds, d.isFinite { videoLengths[s.id] = d } }
            } }
        }
    }
    func refreshFiles(_ store: Store) { if let t = trailer { files = store.trailerFiles(t) } }
}

struct TrailerView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var tm: TrailerModel
    @ObservedObject var audio: TrailerAudio
    @State var filter = DoneFilter.all

    var body: some View {
        let _ = store.imageVersion
        Group {
            if let t = tm.trailer {
                let shown = t.shots.filter { filter.keeps(store.isDone("trailer:\($0.id)")) }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            header(t)
                            // not lazy: 26 cards whose pictures load off the main thread into fixed 16:9 boxes,
                            // so the page's height never changes while you scroll
                            Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
                                ForEach(Array(stride(from: 0, to: shown.count, by: 2)), id: \.self) { i in
                                    GridRow(alignment: .top) {
                                        ForEach(shown[i..<min(i + 2, shown.count)]) { s in card(t, s).id(s.id) }
                                        if i + 1 >= shown.count { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                                    }
                                }
                            }
                            if shown.isEmpty { Text(filter == .done ? "Nothing marked done yet." : "Every shot is done.").foregroundStyle(Color.soft) }
                        }.padding(28).frame(maxWidth: 1500, alignment: .leading)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) { ExportStatusBar(); if !tm.picked.isEmpty { GenerateSelectedBar() } }
                    }
                    .sheet(isPresented: Binding(get: { tm.editing != nil }, set: { if !$0 { tm.editing = nil } })) {
                        if let r = tm.editing { EditSheet(request: r).environmentObject(store).environmentObject(tm) }
                    }
                    .onChange(of: audio.current) { _, id in if audio.playing, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
                    .onReceive(NotificationCenter.default.publisher(for: Snapshot.scrollTo)) { n in
                        if let id = n.object as? String { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .trailerStep)) { n in
                        // ← → move between shots, like beats
                        guard let d = n.object as? Int else { return }
                        let ids = shown.map(\.id)
                        let i = ids.firstIndex(of: tm.selected ?? "") ?? -1
                        let j = min(ids.count - 1, max(0, i + d))
                        if ids.indices.contains(j) { tm.selected = ids[j]; nav.inspector = true; withAnimation { proxy.scrollTo(ids[j], anchor: .center) } }
                    }
                }
                .onAppear { audio.load(store.kitchen.appendingPathComponent(t.audio)) }
                .onReceive(NotificationCenter.default.publisher(for: Snapshot.trailerAt)) { n in
                    // -snapshot only: play silently from this time so the page follows the shot
                    guard let at = n.object as? Double else { return }
                    audio.muted = true; audio.seek(at); if !audio.playing { audio.toggle() }
                }
            } else {
                VStack(spacing: 10) {
                    Text("No trailer shot list found").font(.serif(26))
                    Text(store.trailerShotsURL.path).foregroundStyle(Color.soft)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            tm.reload(store)
            NotificationCenter.default.post(name: .readThroughStarted, object: nil)   // the bottom player is the trailer's here: an episode that was playing pauses
        }
        .onChange(of: tm.wantsPanel) { _, _ in nav.inspector = true }      // a run just started: show it
        .onDisappear { audio.stop(); nav.viewing = false }
        .sheet(isPresented: Binding(get: { tm.confirming != nil }, set: { if !$0 { tm.confirming = nil } })) {
            if let jobs = tm.confirming { GenConfirmSheet(jobs: jobs).environmentObject(store).environmentObject(tm) }
        }
        .onReceive(NotificationCenter.default.publisher(for: Snapshot.select)) { n in tm.selected = n.object as? String }   // -snapshot only
        .navigationTitle("Season 1 Trailer")
        .navigationSubtitle(tm.trailer.map { t in
            "\(t.shots.count) shots · \(t.shots.filter { store.isDone("trailer:\($0.id)") }.count) done · \(clock(t.audio_seconds))"
        } ?? "")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) { ForEach(DoneFilter.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).help("Show every shot, only the ones left, or only the done ones")
            }
            ToolbarItem(placement: .navigation) {
                Picker("Episode", selection: Binding(get: { 0 }, set: { if $0 != 0 { nav.go(.ep, ep: $0) } })) {
                    ForEach((store.season?.eps ?? []).filter { $0.seasonN == 1 }) { x in Text("\(x.label) · \(x.title)").tag(x.n) }
                    Text(Tab.trailer.rawValue).tag(0)
                }.pickerStyle(.menu).help("Choose an episode or the trailer")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                PlayTrailerButton(audio: audio)
                Button { tm.watching = true } label: { Label("Watch trailer", systemImage: "play.rectangle") }
                    .help("Play the trailer full window: every shot with its camera move and transition, with the recording")
                TrailerExportMenu()
                Button { tm.reload(store); store.say("Shot list, prompts and panels reloaded") } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }.help("Read the shot list and prompts again and pick up new sketches and paintings")
                Button {
                    if tm.selected == nil { tm.selected = tm.trailer?.shots.first?.id }
                    nav.inspector.toggle()
                } label: { Label("Details", systemImage: "sidebar.right") }
                    .help("Show or hide the shot's details")
            }
        }
    }

    /// A click selects the shot; ⌘-click ticks it for "Generate selected"; ⇧-click ticks every shot from the last one.
    func pick(_ t: TrailerFile, _ id: String) {
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            if tm.picked.contains(id) { tm.picked.remove(id) } else { tm.picked.insert(id) }; tm.lastPicked = id
        } else if mods.contains(.shift), let last = tm.lastPicked, let a = t.shots.firstIndex(where: { $0.id == last }), let b = t.shots.firstIndex(where: { $0.id == id }) {
            for s in t.shots[min(a, b)...max(a, b)] { tm.picked.insert(s.id) }; tm.lastPicked = id
        } else { tm.selected = id; nav.inspector = true }
    }

    func card(_ t: TrailerFile, _ s: TrailerShot) -> some View {
        TrailerCard(shot: s, trailer: t, files: tm.files, span: audio.timeline[s.id], live: audio.current == s.id,
                    logo: store.logoShots(t).contains(s.id), prompt: tm.prompts[s.id], selected: tm.selected == s.id && nav.inspector,
                    tap: { pick(t, s.id) }, refresh: { tm.refreshFiles(store) }, reload: { tm.reload(store) }, tileTap: { pick(t, $0) })
    }

    /// The trailer's recording with a play button and the shot that's on screen, then the logo slot.
    func header(_ t: TrailerFile) -> some View {
        let shot = t.shots.first { $0.id == audio.current }
        return HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(t.show.capitalized) · \(t.subtitle.capitalized)").font(.serif(26))
                Text("Every shot in order. Each shows its 4K painting once it's in, else the pencil sketch. Click a shot for its details: the full picture, the sketch and painting slots (drop files on them), its prompts and attachments. Drop a picture on a card and it goes in the right slot: black-and-white as the sketch, color as the painting.")
                    .foregroundStyle(.secondary).frame(maxWidth: 640, alignment: .leading)
                TrailerProductionBoxes(t: t).padding(.vertical, 4)
                if let shot {
                    HStack(spacing: 6) { Eyebrow(shot.id); Eyebrow("· \(shot.name)", color: .soft) }
                    Text(shot.line).font(.body(16)).foregroundStyle(Color.ink)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Eyebrow("Logo"); Spacer(); if let u = store.logoURL { RevealButton(url: u) } }
                TruckImage(key: "trailer-logo", fallback: store.trailerLogo(t), label: "the Against the Grain logo", aspect: 16 / 9).frame(width: 300)
                Text("Shows over the shots marked Logo (the opening and the last shot to start). Toggle it on any shot.")
                    .font(.system(size: 11)).foregroundStyle(Color.soft).frame(width: 300, alignment: .leading)
            }.frame(width: 300)
        }
    }
}

/// The selected shot's panel in the window's side column, from the shared trailer model.
struct TrailerInspector: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    var body: some View {
        if let tile = tm.tile(tm.selected) {
            ScrollView { VStack(spacing: 0) { RunList(kie: tm.kie).padding([.horizontal, .top], 20); TileDetail(tile: tile) } }
                .background(Color.panel).foregroundStyle(Color.ink)
        } else if let t = tm.trailer, let s = tm.shot {
            TrailerShotDetail(shot: s, trailer: t, files: tm.files, prompt: tm.prompts[s.id], audio: tm.audio,
                              span: tm.audio.timeline[s.id], refresh: { tm.refreshFiles(store) })
        } else {
            Text("Click a shot").foregroundStyle(Color.soft).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Play, the time and the scrubber: the only part of the page that redraws as the trailer plays.
/// In the toolbar: play or pause the trailer recording, like an episode's Play button.
struct PlayTrailerButton: View {
    @ObservedObject var audio: TrailerAudio
    var body: some View {
        Button { audio.toggle() } label: {
            Label(audio.playing ? "Pause" : "Play", systemImage: audio.playing ? "pause.fill" : "play.fill")
        }.help(audio.playing ? "Pause (Space)" : "Play the trailer recording (Space)")
    }
}

/// In the shot panel: start the recording at this shot, or pause it while it's on this shot, like a beat's button.
struct PlayShotButton: View {
    @ObservedObject var audio: TrailerAudio
    let shot: String; let start: Double
    var body: some View {
        let here = audio.current == shot && audio.playing
        Button { if here { audio.toggle() } else { audio.seek(start); if !audio.playing { audio.toggle() } } } label: {
            Label(here ? "Pause" : "Play from here", systemImage: here ? "pause.fill" : "play.fill")
        }.controlSize(.small)
    }
}

struct TrailerTransport: View {
    @ObservedObject var audio: TrailerAudio
    @ObservedObject var clock: TrailerClock
    let length: Double
    var body: some View {
        HStack(spacing: 12) {
            Button { audio.toggle() } label: {
                Image(systemName: audio.playing ? "pause.fill" : "play.fill").font(.system(size: 16))
                    .frame(width: 40, height: 40).background(Color.gold, in: Circle()).foregroundStyle(Color.dark).contentShape(Circle())
            }.buttonStyle(.plain).help("Play or pause the trailer recording")
            Text("\(clock(clock.time)) / \(clock(length))").monospacedDigit().foregroundStyle(Color.soft)
            Slider(value: Binding(get: { clock.time }, set: { audio.seek($0) }), in: 0...length).frame(maxWidth: 320)
        }
    }
    func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}

/// The picture a shot shows: its painting or sketch, a crop of another shot, or the montage's Ep 1 panels.
struct ShotPicture: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    @EnvironmentObject var nav: Nav
    let shot: TrailerShot
    let trailer: TrailerFile
    let files: [String: PanelFiles]
    var maxPixel: Int? = 1000
    var tileTap: ((String) -> Void)? = nil
    var body: some View {
        switch shot.kind {
        case "montage":
            // the Ep 1 panels it shuffles through, in order (a plain grid: no lazy grid inside the page); click one to work on it
            // the tiles fill exactly the same 16:9 box as every other card's picture: 3 across, as many rows as needed
            let ps = tm.tiles.filter { t in (shot.montage ?? []).contains { $0.id == t.id } }
            let cols = 3, rows = max(1, (ps.count + cols - 1) / cols), gap: CGFloat = 4
            Color(hex: 0x2a2520).aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity)
                .overlay {
                    GeometryReader { g in
                        let w = (g.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols), h = (g.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                        ForEach(Array(ps.enumerated()), id: \.element.id) { i, tile in
                            TileView(tile: tile, tap: { tileTap?($0) ?? { tm.selected = $0; nav.inspector = true }($0) })
                                .frame(width: w, height: h).clipped()
                                .offset(x: CGFloat(i % cols) * (w + gap), y: CGFloat(i / cols) * (h + gap))
                        }
                    }
                }
        case "crop":
            PanelImage(url: shot.crop_of.flatMap { files[$0]?.shown }, crop: shot.crop, maxPixel: maxPixel, fit: true,
                       missing: "crop of \(shot.crop_of ?? "?") (not drawn yet)", version: store.imageVersion)
        default:
            if let v = files[shot.id]?.video {
                VideoThumb(url: v).revealOnHover(v).fileDrag(v)
            } else {
                let u = files[shot.id]?.shown
                PanelImage(url: u, maxPixel: maxPixel, fit: maxPixel == nil, missing: "\(shot.id) not drawn yet", region: shot.zoom?.start, version: store.imageVersion)
                    .revealOnHover(u).fileDrag(u)
            }
        }
    }
}

/// The logo over a shot, loaded off the main thread like the panels.
struct LogoOverlay: View {
    let url: URL?
    let version: Int
    var ready: CGImage? = nil        // already loaded (the export draws without waiting)
    @State private var cg: CGImage?
    var body: some View {
        ZStack { if let shown = ready ?? cg { Image(decorative: shown, scale: 1).resizable().scaledToFit() } }
            .task(id: "\(url?.path ?? "")|\(version)") {
                guard let url else { cg = nil; return }
                let k = PictureCache.key(url, nil, 1200, version)
                if let hit = PictureCache.shared.get(k) { cg = hit; return }
                cg = await Task.detached { PictureCache.load(url, crop: nil, maxPixel: 1200) }.value
                if let cg { PictureCache.shared.set(k, cg) }
            }
            .allowsHitTesting(false)
    }
}

/// One shot: its picture (with the logo on top where it's turned on), ID, name, time, speaker, line, prompts and Done.
struct TrailerCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    let trailer: TrailerFile
    let files: [String: PanelFiles]
    let span: (Double, Double)?
    let live: Bool
    let logo: Bool
    let prompt: TrailerPrompt?
    let selected: Bool
    let tap: () -> Void
    let refresh: () -> Void
    var reload: () -> Void = {}
    var tileTap: ((String) -> Void)? = nil
    @State var target = false

    var body: some View {
        let done = store.isDone("trailer:\(shot.id)")
        VStack(alignment: .leading, spacing: 8) {
            ShotPicture(shot: shot, trailer: trailer, files: files, tileTap: tileTap)
                .overlay { if logo { LogoOverlay(url: store.logoURL, version: store.imageVersion).padding(.horizontal, 60).padding(.vertical, 30) } }
                .overlay(alignment: .bottom) {
                    if shot.logo != nil {
                        Text("SUBSCRIBE FOR EPISODE ONE").font(.system(size: 11, weight: .bold)).tracking(3)
                            .foregroundStyle(Color.dark).padding(.bottom, 10)
                    }
                }
                .overlay(alignment: .topTrailing) { if done { Pill(text: "DONE", color: .done).padding(8) } }
                .overlay(alignment: .topLeading) { if shot.kind != "montage" { PickBox(id: shot.id).padding(8) } }   // a montage's tiles are picked one by one
                .overlay { GenStatus(kie: tm.kie, shot: shot.id) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(target ? Color.gold : .clear, lineWidth: 2.5))
                .contentShape(Rectangle())
                .onTapGesture(perform: tap)
                .fileDrop(targeted: $target) { url in
                    // a video goes in the video slot; black-and-white in the sketch slot, color in the painting slot
                    if let t = UTType(filenameExtension: url.pathExtension), t.conforms(to: .movie) {
                        if store.setTrailerVideo(shot, from: url) { reload() }
                        return
                    }
                    guard isDrawn else { store.say("\(shot.id) is made in the app, not drawn"); return }
                    let color = Store.isColor(url)
                    if store.setTrailerPanel(shot, painting: color, from: url) { refresh() }
                }
                .help(isDrawn ? "Click for details. Drop a sketch or painting here" : "Click for details")
            HStack(spacing: 6) {
                Pill(text: shot.id, color: Color.gold, dark: true)
                Pill(text: shot.kind.capitalized, color: kindColor(shot.kind))
                Text(shot.time).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(Color.soft)
                if let span { Text("· \(String(format: "%.1f", span.1 - span.0)) s").font(.system(size: 11)).foregroundStyle(Color.mute) }
                if let z = shot.zoom, !z.isStill { Image(systemName: "camera.viewfinder").font(.system(size: 11)).foregroundStyle(Color.gold).help("Has a camera move") }
                if let tr = shot.transition, let k = TransitionKind(rawValue: tr.type), k != .cut {
                    Text("→ \(k.label) \(String(format: "%.1f", tr.duration))s").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.gold)
                }
                if files[shot.id]?.video != nil { Image(systemName: "film").font(.system(size: 11)).foregroundStyle(Color.gold).help("Plays a video") }
                Spacer()
                DoneToggle(key: "trailer:\(shot.id)")
                if shot.video == nil {
                    Toggle("Logo", isOn: Binding(get: { logo }, set: { _ in store.toggleLogo(trailer, shot.id) }))
                        .toggleStyle(.checkbox).controlSize(.small).font(.system(size: 11)).help("Show the logo over this shot")
                }
            }
            if shot.kind == "montage" {
                Text("From the Episode 1 storyboard (~/Kitchen/ART/Hand Drawn Storyboards/ep01-the-walkout). Click a panel to work on it.")
                    .font(.system(size: 11)).foregroundStyle(Color.soft)
            }
            if shot.video != nil { VideoStatusLine(shot: shot, span: span) }
            Text(shot.name).font(.serif(20)).onTapGesture(perform: tap)
            if !shot.who.isEmpty { Eyebrow(shot.who, color: .soft) }
            Text(shot.line).font(.body(15))
            if let g = shot.graphic { Text(g).font(.system(size: 12)).foregroundStyle(Color.soft) }
            if let n = shot.note { Text(n).font(.system(size: 11)).foregroundStyle(Color.mute) }
            if let prompt { TrailerPromptRow(prompt: prompt, id: shot.id).padding(.top, 4) }
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)   // as tall as its row
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected || live ? Color.gold : Color.line, lineWidth: selected ? 2.5 : live ? 3 : 1))
    }
    var isDrawn: Bool { shot.kind == "draw" || shot.kind == "keep" }
}

func kindColor(_ k: String) -> Color {
    switch k {
    case "draw": return Color.built
    case "keep": return Color.done
    case "crop": return Color.reuse
    case "graphic": return Color.gpt
    case "montage": return Color.plate
    default: return Color.mute
    }
}

/// The selected shot, like a beat's panel: the picture (View full image), the sketch and painting slots, the prompts
/// with their attachments, Done, and Play from here.
struct TrailerShotDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var tm: TrailerModel
    let shot: TrailerShot
    let trailer: TrailerFile
    let files: [String: PanelFiles]
    let prompt: TrailerPrompt?
    let audio: TrailerAudio
    let span: (Double, Double)?
    let refresh: () -> Void

    var scroll = true          // false: just the content (drawn off-screen by -verify)
    @State var moveOpen = false
    /// A drawn picture, not a video or a montage: it can be framed.
    var frameable: Bool { (shot.kind == "draw" || shot.kind == "keep") && files[shot.id]?.video == nil }
    var body: some View {
        if scroll { ScrollView { content }.background(Color.panel).foregroundStyle(Color.ink) } else { content }
    }
    var content: some View {
            VStack(alignment: .leading, spacing: 12) {
                RunList(kie: tm.kie)
                HStack(spacing: 6) {
                    Eyebrow("Trailer · \(shot.id) · \(shot.kind)"); Spacer(); DoneToggle(key: "trailer:\(shot.id)")
                }
                Text(shot.name).font(.serif(24))
                if !shot.who.isEmpty { Eyebrow(shot.who, color: .soft) }
                Text(shot.line).font(.body(18)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    if let span {
                        PlayShotButton(audio: audio, shot: shot.id, start: span.0)
                    }
                    Text(shot.time).font(.system(size: 12)).monospacedDigit().foregroundStyle(Color.soft)
                }
                if frameable {
                    // the same control as an episode beat: drag, pinch or slide, saved when you let go
                    ShotFraming(shot: shot, url: files[shot.id]?.shown)
                } else {
                    ShotPicture(shot: shot, trailer: trailer, files: files, maxPixel: 1600)
                        .overlay { RunStatusOverlay(kie: tm.kie, id: shot.id) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = true } }
                }
                Button { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = true } } label: {
                    Label("View full image", systemImage: "arrow.up.left.and.arrow.down.right")
                }.controlSize(.small).help("Show the whole picture in the window (Esc closes, ← → change shot)")

                if shot.kind == "draw" || shot.kind == "keep" {
                    HStack(alignment: .top, spacing: 10) {
                        PanelSlot(title: "B&W sketch", url: files[shot.id]?.sketch, name: shot.keep_file ?? "\(shot.id)-sketch.png") { url in
                            if store.setTrailerPanel(shot, painting: false, from: url) { refresh() }
                        } remove: { u in store.removeTrailerPanel(u); refresh() }
                        PanelSlot(title: "Color painting", url: files[shot.id]?.painting, name: "\(shot.id)-painting.png") { url in
                            if store.setTrailerPanel(shot, painting: true, from: url) { refresh() }
                        } remove: { u in store.removeTrailerPanel(u); refresh() }
                    }
                    if frameable {
                        DisclosureGroup("Add a camera move (optional)", isExpanded: Binding(get: { moveOpen || (shot.zoom.map { !$0.isStill } ?? false) }, set: { moveOpen = $0 })) {
                            ZoomEditor(shot: shot, url: files[shot.id]?.shown, length: span.map { $0.1 - $0.0 } ?? 3).padding(.top, 6)
                        }
                        .font(.system(size: 12, weight: .semibold))
                    } else if files[shot.id]?.video != nil {
                        Text("This shot plays a video, so framing and camera moves don't apply.").font(.system(size: 11)).foregroundStyle(Color.soft)
                    }
                    TransitionEditor(shot: shot)
                    VideoControls(shot: shot)
                } else if shot.kind == "crop", let src = shot.crop_of {
                    Box(title: "Made in the app") {
                        Text("A crop of \(src): drop pictures on \(src) and this follows.").font(.system(size: 12)).foregroundStyle(Color.soft)
                        if let u = files[src]?.shown { RevealButton(url: u, label: "Show \(u.lastPathComponent) in Finder").font(.system(size: 12)) }
                    }
                } else if shot.kind == "montage" {
                    Box(title: "From the Episode 1 storyboard") {
                        Text("~/Kitchen/ART/Hand Drawn Storyboards/ep01-the-walkout. Click a panel to draw, paint, replace or edit it.")
                            .font(.system(size: 11)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
                        ForEach(tm.tiles.filter { t in (shot.montage ?? []).contains { $0.id == t.id } }) { tile in
                            HStack(spacing: 6) {
                                Button(tile.label) { tm.selected = tile.id }.buttonStyle(.link).font(.system(size: 12, weight: .semibold))
                                if let u = tm.files[tile.id]?.shown { Text(u.lastPathComponent).font(.system(size: 11)).foregroundStyle(Color.soft); RevealButton(url: u) }
                                else { Text("missing").font(.system(size: 11)).foregroundStyle(Color.red2) }
                            }
                        }
                    }
                }
                if let prompt { Box(title: "Prompts") { TrailerPromptRow(prompt: prompt, id: shot.id) } }
                if let sc = shot.scene { Box(title: "What it shows") { Text(sc).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) } }
                if let n = shot.note { Text(n).font(.system(size: 12)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of a shot's two panels: its picture, or a drop target when it's empty. Drop or click to replace;
/// the old file moves to `_replaced/`.
struct PanelSlot: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let title: String
    let url: URL?
    let name: String
    let set: (URL) -> Void
    let remove: (URL) -> Void
    @State var target = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Eyebrow(title)
                Spacer()
                if let url { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.done).font(.system(size: 11)); RevealButton(url: url) }
            }
            PanelImage(url: url, maxPixel: 700, fit: true, missing: "Drop \(name) here, or click to choose", version: store.imageVersion)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(target ? Color.gold : Color.line, style: StrokeStyle(lineWidth: target ? 2.5 : 1.5, dash: url == nil ? [5] : [])))
                .contentShape(Rectangle())
                .onTapGesture { nav.choose([.image]) { set($0) } }
                .fileDrop(targeted: $target) { set($0) }
            HStack(spacing: 6) {
                Button("Replace…") { nav.choose([.image]) { set($0) } }
                if let url { Button("Remove", role: .destructive) { remove(url) }.help("Moves \(url.lastPathComponent) to _replaced (not deleted)") }
            }.controlSize(.small)
            Text(name).font(.system(size: 10)).foregroundStyle(Color.mute)
        }.frame(maxWidth: .infinity)
    }
}

extension TrailerViewer {
    /// The panels' file dates, so a montage reloads when one of its panels really changes.
    static func stamps(_ urls: [URL?]) -> String {
        urls.map { u in u.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }.map { String($0.timeIntervalSince1970) } ?? "-" }.joined(separator: ",")
    }
}

/// The shot's picture filling the window, exactly as the card shows it (logo and title line included), at full
/// resolution so it can be zoomed: pinch or the mouse wheel, drag to pan, double-click, Fit. Esc or the X closes it.
struct TrailerViewer: View {
    @EnvironmentObject var store: Store
    let shot: TrailerShot
    let trailer: TrailerFile
    let files: [String: PanelFiles]
    let close: () -> Void
    var body: some View {
        let logo = store.logoShots(trailer).contains(shot.id)
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                Group {
                    if let v = files[shot.id]?.video { FullVideo(url: v) }
                    else if shot.kind == "montage" {
                        // the panels drawn into one big picture, so it zooms like any other
                        let panels = (shot.montage ?? []).map { files["\($0.episode)/\($0.id)"]?.shown }
                        ZoomableImage(url: nil, render: { Store.montageImage(panels) }, key: panels.map { $0?.path ?? "-" }.joined(separator: "|") + "|\(Self.stamps(panels))", version: store.imageVersion)
                    }
                    else {
                        let src = shot.kind == "crop" ? shot.crop_of.flatMap { files[$0]?.shown } : files[shot.id]?.shown
                        ZoomableImage(url: src, crop: shot.kind == "crop" ? shot.crop : nil,
                                      compose: Store.titleComposer(logo: logo ? store.logoURL : nil, subscribe: shot.logo != nil),
                                      key: "\(logo)|\(shot.logo != nil)|\(logo ? store.logoURL?.path ?? "" : "")", version: store.imageVersion)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Eyebrow("Trailer · \(shot.id) · \(shot.name)")
                    Text(shot.line).font(.body(18)).lineLimit(2)
                }.frame(maxWidth: 1100)
            }.padding(.horizontal, 40).padding(.top, 54).padding(.bottom, 24)
        }
        .overlay(alignment: .topTrailing) { ViewerControls(url: files[shot.id]?.reveal, close: close) }
    }
}

extension Store {
    /// A montage's panels as one 4K picture: 3 across, each filling its cell (like the card).
    static func montageImage(_ panels: [URL?]) -> CGImage? {
        let w = 3840, h = 2160, gap = 16, cols = 3, rows = max(1, (panels.count + cols - 1) / cols)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.16, green: 0.145, blue: 0.125, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cw = (w - gap * (cols - 1)) / cols, ch = (h - gap * (rows - 1)) / rows
        for (i, u) in panels.enumerated() {
            guard let u, let cg = PictureCache.load(u, crop: nil, maxPixel: 2000) else { continue }
            let cell = CGRect(x: (i % cols) * (cw + gap), y: h - ((i / cols) + 1) * ch - (i / cols) * gap, width: cw, height: ch)
            let s = max(cell.width / CGFloat(cg.width), cell.height / CGFloat(cg.height))
            let dw = CGFloat(cg.width) * s, dh = CGFloat(cg.height) * s
            ctx.saveGState(); ctx.clip(to: cell)
            ctx.draw(cg, in: CGRect(x: cell.midX - dw / 2, y: cell.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
    /// Draws the logo (fitted with the card's margins) and the title card's subscribe line onto a full-size picture,
    /// so the full-screen view matches the card. Nil when there's nothing to add.
    static func titleComposer(logo: URL?, subscribe: Bool) -> ((CGImage) -> CGImage)? {
        guard logo != nil || subscribe else { return nil }
        return { base in
            let w = base.width, h = base.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return base }
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
            if let logo, let l = PictureCache.load(logo, crop: nil, maxPixel: max(w, h)) {
                // the card's margins: 60 of ~560 points across, 30 of ~315 down
                let box = CGRect(x: Double(w) * 0.107, y: Double(h) * 0.095, width: Double(w) * 0.786, height: Double(h) * 0.81)
                let s = min(box.width / Double(l.width), box.height / Double(l.height))
                let lw = Double(l.width) * s, lh = Double(l.height) * s
                ctx.draw(l, in: CGRect(x: box.midX - lw / 2, y: box.midY - lh / 2, width: lw, height: lh))
            }
            if subscribe {
                let font = NSFont.systemFont(ofSize: Double(w) * 0.0196, weight: .bold)
                let text = NSAttributedString(string: "SUBSCRIBE FOR EPISODE ONE", attributes: [.font: font, .kern: Double(w) * 0.0054,
                                                                                            .foregroundColor: NSColor(red: 0.10, green: 0.09, blue: 0.08, alpha: 1)])
                let line = CTLineCreateWithAttributedString(text)
                let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                ctx.textPosition = CGPoint(x: (Double(w) - width) / 2, y: Double(h) * 0.032 + Double(font.descender * -1))
                CTLineDraw(line, ctx)
            }
            return ctx.makeImage() ?? base
        }
    }
}

/// A trailer shot's prompts with Copy buttons, and the images to attach to each, in order with their roles.
struct TrailerPromptRow: View {
    let prompt: TrailerPrompt
    var id: String? = nil          // the shot or tile the Generate buttons work on
    var groups: [(String, [PromptAttachment])] {
        func list(_ k: String) -> [PromptAttachment] { (prompt.refs?[k] ?? []).map { PromptAttachment(url: URL(fileURLWithPath: $0.file), role: $0.role) } }
        return [("B&W attachments", list("bw")), ("Color attachments", list("color"))]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let t = prompt.bw { CopyButton(text: t, title: "Copy B&W prompt") }
                if let t = prompt.fix { CopyButton(text: t, title: "Copy fix prompt") }
                if let t = prompt.color { CopyButton(text: t, title: "Copy color prompt") }
            }
            if let id { GenerateButtons(id: id) }
            AttachmentList(groups: groups)
        }
    }
}

/// The tick on a card for "Generate selected".
struct PickBox: View {
    @EnvironmentObject var tm: TrailerModel
    let id: String
    var body: some View {
        let on = tm.picked.contains(id)
        Button { if on { tm.picked.remove(id) } else { tm.picked.insert(id) }; tm.lastPicked = id } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? Color.gold : .white.opacity(0.8)).padding(3).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain).help("Pick this shot to generate it with others (⌘-click or ⇧-click a card too)")
    }
}
