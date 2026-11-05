import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - The T17a flashback's tiles: Episode 1 storyboard panels, each one workable like a shot

/// One tile of a montage shot: an Episode 1 panel ("S1-G2", "The wok") in its storyboard folder.
struct MontageTile: Identifiable, Hashable {
    let id: String              // "S1-G2"
    let episode: String         // "ep01-the-walkout"
    let name: String            // "The wok"
    let dir: URL                // where its -sketch.png and -painting.png live
    /// "Ep 1 · panel G2 · The wok"
    var label: String {
        let ep = Int(episode.dropFirst(2).prefix(2)).map { "Ep \($0)" } ?? episode
        let panel = id.split(separator: "-").last.map(String.init) ?? id
        return "\(ep) · panel \(panel)\(name.isEmpty ? "" : " · " + name)"
    }
    var folderNote: String { "From the Episode \(Int(episode.dropFirst(2).prefix(2)) ?? 1) storyboard (~/Kitchen/ART/Hand Drawn Storyboards/\(episode))" }
}

extension Store {
    /// The panel names (ep01-board/names.json: "S1-G2": "The wok").
    func panelNames() -> [String: String] {
        let u = kitchen.appendingPathComponent("_work/_run-files/ep01-board/names.json")
        return (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }
    /// The montage tiles' prompts (productions/trailer/montage-prompts.json, the same shape as prompts.json).
    func loadMontagePrompts() -> [String: TrailerPrompt] {
        let u = trailerShotsURL.deletingLastPathComponent().appendingPathComponent("montage-prompts.json")
        return (try? Data(contentsOf: u)).flatMap { try? JSONDecoder().decode([String: TrailerPrompt].self, from: $0) } ?? [:]
    }
    func montageTiles(_ t: TrailerFile) -> [MontageTile] {
        let names = panelNames()
        return t.shots.flatMap { $0.montage ?? [] }.map {
            MontageTile(id: $0.id, episode: $0.episode, name: names[$0.id] ?? "", dir: kitchen.appendingPathComponent("ART/Hand Drawn Storyboards/\($0.episode)"))
        }
    }
    /// Saves a dropped picture as `dst` (a PNG); whatever was there moves to `_replaced/` beside it first.
    @discardableResult
    func setPanelFile(_ dst: URL, from url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { say("That is not an image file."); return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dst.path) { try moveAsideFile(dst) }
            if url.pathExtension.lowercased() == "png" { try fm.copyItem(at: url, to: dst) }
            else {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
                      let out = CGImageDestinationCreateWithURL(dst as CFURL, UTType.png.identifier as CFString, 1, nil) else { say("Couldn't read that picture."); return false }
                CGImageDestinationAddImage(out, cg, nil)
                guard CGImageDestinationFinalize(out) else { say("Couldn't save \(dst.lastPathComponent)."); return false }
            }
            refreshFiles(); say("Saved \(dst.lastPathComponent)")
            return true
        } catch { say("Couldn't save \(dst.lastPathComponent): \(error.localizedDescription)"); return false }
    }
    /// Moves a file into `_replaced/` in its own folder (never deleted).
    func moveAsideFile(_ url: URL) throws {
        let dir = url.deletingLastPathComponent().appendingPathComponent("_replaced")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970)).png"))
    }
}

extension TrailerModel {
    func tile(_ id: String?) -> MontageTile? { tiles.first { $0.id == id } }
    /// What a shot or tile is called on the Generate and Edit sheets.
    func displayName(_ id: String) -> String { trailer?.shots.first { $0.id == id }?.name ?? tile(id)?.label ?? id }
}

/// A montage tile on the card: its picture with a plain label, a pick box, and "Missing: Generate B&W" when it isn't drawn.
struct TileView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let tile: MontageTile
    let tap: (String) -> Void
    var body: some View {
        let u = tm.files[tile.id]?.shown
        PanelImage(url: u, maxPixel: 500, missing: "Missing: Generate B&W", version: store.imageVersion, box: false)
            .revealOnHover(u).fileDrag(u)
            .overlay(alignment: .bottomLeading) {
                Text(tile.label).font(.system(size: 8, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal, 3).padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading).background(.black.opacity(0.65)).foregroundStyle(.white)
            }
            .overlay(alignment: .topTrailing) { PickBox(id: tile.id).scaleEffect(0.8).padding(2) }
            .overlay { GenStatus(kie: tm.kie, shot: tile.id).scaleEffect(0.8) }
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(tm.selected == tile.id ? Color.gold : .clear, lineWidth: 2))
            .contentShape(Rectangle())
            .onTapGesture { tap(tile.id) }
            .help("\(tile.label): click for its sketch, painting, prompts and Generate")
    }
}

/// A tile's panel, like a shot's: the picture (full screen), B&W and color slots with drop to replace, Show in Finder,
/// the prompts with their attachments, and Generate / Regenerate / Edit.
struct TileDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var tm: TrailerModel
    let tile: MontageTile
    var body: some View {
        let f = tm.files[tile.id]
        return VStack(alignment: .leading, spacing: 12) {
            Eyebrow("Trailer · T17a flashback · \(tile.id)")
            Text(tile.label).font(.serif(22))
            Text(tile.folderNote).font(.system(size: 11)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
            PanelImage(url: f?.shown, maxPixel: 1600, missing: "Missing: Generate B&W below", version: store.imageVersion)
                .overlay { RunStatusOverlay(kie: tm.kie, id: tile.id) }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onTapGesture { if f?.shown != nil { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = true } } }
            if f?.shown != nil {
                Button { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = true } } label: {
                    Label("View full image", systemImage: "arrow.up.left.and.arrow.down.right")
                }.controlSize(.small)
            }
            HStack(alignment: .top, spacing: 10) {
                PanelSlot(title: "B&W sketch", url: f?.sketch, name: "\(tile.id)-sketch.png") { u in
                    if store.setPanelFile(tile.dir.appendingPathComponent("\(tile.id)-sketch.png"), from: u) { tm.refreshFiles(store) }
                } remove: { u in try? store.moveAsideFile(u); store.refreshFiles(); tm.refreshFiles(store) }
                PanelSlot(title: "Color painting", url: f?.painting, name: "\(tile.id)-painting.png") { u in
                    if store.setPanelFile(tile.dir.appendingPathComponent("\(tile.id)-painting.png"), from: u) { tm.refreshFiles(store) }
                } remove: { u in try? store.moveAsideFile(u); store.refreshFiles(); tm.refreshFiles(store) }
            }
            if let p = tm.tilePrompts[tile.id] {
                Box(title: "Prompts") { TrailerPromptRow(prompt: p, id: tile.id) }
            } else {
                Text("No prompt for \(tile.id) in montage-prompts.json").font(.system(size: 11)).foregroundStyle(Color.soft)
            }
            Text("Saves into \(tile.episode)/ as \(tile.id)-sketch.png and \(tile.id)-painting.png; old pictures go to _previous/, run logs to _data/.")
                .font(.system(size: 11)).foregroundStyle(Color.mute).fixedSize(horizontal: false, vertical: true)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tile's picture filling the window, zoomable.
struct TileViewer: View {
    @EnvironmentObject var store: Store
    let tile: MontageTile
    let url: URL?
    let close: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                ZoomableImage(url: url, version: store.imageVersion).frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack(spacing: 14) { Eyebrow("Trailer · T17a · \(tile.label)") }.frame(maxWidth: 1100)
            }.padding(.horizontal, 40).padding(.top, 54).padding(.bottom, 24)
        }
        .overlay(alignment: .topTrailing) { ViewerControls(url: url, close: close) }
    }
}
