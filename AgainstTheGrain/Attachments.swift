import SwiftUI
import ImageIO

// MARK: - Attachments: the images a prompt needs, in order, each with what it's for and where it is

/// One image to attach with a prompt. A nil url is one that doesn't exist yet (the sketch, before it's dropped in).
struct PromptAttachment: Hashable {
    var url: URL?
    var role: String
    var name: String { url?.lastPathComponent ?? "not made yet" }
}

/// A folded list of a prompt's attachments: "Image 1: file", its role, and a button that shows it in Finder.
struct AttachmentList: View {
    let groups: [(String, [PromptAttachment])]      // ("B&W attachments", [...]), ("Color attachments", [...])
    @State var open = ProcessInfo.processInfo.arguments.contains("-snapshot")   // open in -snapshot captures
    var body: some View {
        let shown = groups.filter { !$0.1.isEmpty }
        if !shown.isEmpty {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown, id: \.0) { label, refs in
                        if shown.count > 1 || label != "Attachments" { Eyebrow(label, color: .soft) }
                        ForEach(Array(refs.enumerated()), id: \.offset) { i, r in AttachmentRow(n: i + 1, a: r) }
                    }
                }.padding(.top, 4)
            } label: {
                Text("Attachments (\(shown.map { "\($0.1.count)\(shown.count > 1 ? " " + String($0.0.split(separator: " ")[0]) : "")" }.joined(separator: ", ")))")
            }
            .font(.system(size: 11)).foregroundStyle(Color.soft)
        }
    }
}

/// "Image 1: file.png 🔍", then its role. Missing files show in red. Only drawn when the list is open.
struct AttachmentRow: View {
    let n: Int
    let a: PromptAttachment
    var body: some View {
        let exists = a.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text("Image \(n): \(a.name)").font(.system(size: 11, weight: .semibold)).foregroundStyle(exists ? Color.ink : Color.red2)
                if !exists { Text("missing").font(.system(size: 10)).foregroundStyle(Color.red2) }
                if let u = a.url, exists { RevealButton(url: u) }
            }
            Text(a.role).font(.system(size: 11)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shows a file in Finder, selected.
struct RevealButton: View {
    let url: URL
    var label: String? = nil
    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
            if let label { Label(label, systemImage: "magnifyingglass") } else { Image(systemName: "magnifyingglass") }
        }
        .buttonStyle(.plain).foregroundStyle(Color.soft).help("Show \(url.lastPathComponent) in Finder")
    }
}

extension Store {
    /// The file behind one of your image slots, if it's filled.
    func userFile(_ key: String) -> URL? { state.images[key].map { userDir.appendingPathComponent($0) } }
    var locationsDir: URL { kitchen.appendingPathComponent("ART/Locations") }
    func lockedDesign(_ folder: String) -> URL? {
        let u = kitchen.appendingPathComponent("ART/Characters/\(folder)/\(folder) - Locked Design.png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// A scene's attachments: for the sketch, the location picture it's drawn from (or edited from) and the plate it sits on;
    /// for the painting, the approved sketch (or, for an edit, the picture it starts from).
    func sceneAttachments(_ e: Episode, _ s: Storyboard) -> (sketch: [PromptAttachment], paint: [PromptAttachment]) {
        var sketch: [PromptAttachment] = []
        if let r = s.ref { sketch.append(PromptAttachment(url: URL(fileURLWithPath: r), role: s.isEdit ? "the picture this edit starts from: keep everything not named in the prompt" : "the location: the same camera, layout and furniture, redrawn in pencil")) }
        if let pk = s.plateKey, let k = plateShownKey(pk) {
            sketch.append(PromptAttachment(url: userFile(k), role: "the \(pk) plate: the background this scene sits on"))
        }
        let paint: [PromptAttachment] = s.isEdit
            ? sketch
            : [PromptAttachment(url: userFile(sceneSketchKey(e, s)), role: "the approved pencil sketch of \(s.id): the only source of content, camera, layout and poses")]
        return (sketch, paint)
    }
    func plateAttachments(_ p: PlateInfo) -> (sketch: [PromptAttachment], paint: [PromptAttachment]) {
        ([PromptAttachment(url: locationsDir.appendingPathComponent(p.file), role: "the location picture: the same camera and layout, redrawn in pencil")],
         [PromptAttachment(url: userFile("plate:\(p.id)"), role: "the approved pencil sketch of \(p.id): color it exactly as drawn")])
    }

    // MARK: done ticks: "trailer:T01", "e2b14"
    func isDone(_ key: String) -> Bool { state.done?[key] == true }
    func setDone(_ key: String, _ on: Bool) {
        var m = state.done ?? [:]; m[key] = on ? true : nil; state.done = m; save()
    }
}

/// All / Not done / Done, for the trailer shots and the episode beats.
enum DoneFilter: String, CaseIterable, Identifiable {
    case all = "All", todo = "Not done", done = "Done"
    var id: String { rawValue }
    func keeps(_ done: Bool) -> Bool { self == .all || (self == .done) == done }
}

/// The Done tick on a card.
struct DoneToggle: View {
    @EnvironmentObject var store: Store
    let key: String
    var compact = false              // on a picture: the tick alone, on a dark chip
    var body: some View {
        let on = store.isDone(key)
        Button { store.setDone(key, !on) } label: {
            if compact {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(on ? Color.done : .white.opacity(0.85)).padding(3).background(.black.opacity(0.6), in: Circle())
            } else {
                Label("Done", systemImage: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? Color.done : Color.soft)
            }
        }
        .buttonStyle(.plain).help(on ? "Marked done. Click to mark not done" : "Mark done")
    }
}

// MARK: - Pictures loaded off the main thread

/// Decoded card pictures, shared by every view, so scrolling never decodes on the main thread.
final class PictureCache {
    static let shared = PictureCache()
    private let cache = NSCache<NSString, CGImage>()
    init() { cache.countLimit = 300 }
    func get(_ k: String) -> CGImage? { cache.object(forKey: k as NSString) }
    func set(_ k: String, _ v: CGImage) { cache.setObject(v, forKey: k as NSString) }
    /// `version` is the store's imageVersion, so a replaced file is read again (no file checks while drawing).
    static func key(_ url: URL, _ crop: [Double]?, _ maxPixel: Int?, _ version: Int) -> String {
        "\(url.path)|\(crop ?? [])|\(maxPixel ?? 0)|\(version)"
    }
    /// Reads (and crops: [x0, y0, x1, y1] of 0...1) a picture, shrunk to maxPixel; nil maxPixel is full size.
    static func load(_ url: URL, crop: [Double]?, maxPixel: Int?) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true]
        let cg: CGImage?
        // a crop is cut from a larger copy so it stays sharp
        let size = crop != nil ? maxPixel.map { $0 * 2 } : maxPixel
        if let size {
            opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
            opts[kCGImageSourceThumbnailMaxPixelSize] = size
            cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        } else { cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary) }
        guard let cg, let r = crop, r.count == 4 else { return cg }
        let w = Double(cg.width), h = Double(cg.height)
        return cg.cropping(to: CGRect(x: r[0] * w, y: r[1] * h, width: (r[2] - r[0]) * w, height: (r[3] - r[1]) * h).integral)
    }
}

/// A picture in a fixed 16:9 box: the same size before and after it loads, so lists never re-measure while scrolling.
/// Panels fill the box; `fit` shows the whole picture (crops keep their own shape).
struct PanelImage: View {
    let url: URL?
    var crop: [Double]? = nil
    var maxPixel: Int? = 1000
    var fit = false
    var missing = ""
    var region: [Double]? = nil      // show just this part ([x0, y0, x1, y1]): a shot's camera framing
    var version = 0
    var box = true                   // false: fill whatever frame it's given (a montage tile) instead of its own 16:9 box
    @State private var cg: CGImage?
    @State private var loadedKey = ""

    var body: some View {
        let key = url.map { PictureCache.key($0, crop, maxPixel, version) } ?? ""
        // a picture already decoded shows at once (no blank frame when a card comes back into view)
        let shown = (loadedKey == key ? cg : nil) ?? (key.isEmpty ? nil : PictureCache.shared.get(key))
        Color(hex: 0x2a2520)
            .aspectRatio(box ? 16 / 9 : nil, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: box ? nil : .infinity)
            .overlay {
                if let cg = shown {
                    if let region, !isFull(region) { Framed(cg: cg, region: region) }
                    else {
                        let img = Image(decorative: cg, scale: 1).resizable()
                        if fit { img.scaledToFit() } else { img.scaledToFill() }
                    }
                } else if url == nil {
                    Text(missing).font(.system(size: 11)).foregroundStyle(Color.soft).multilineTextAlignment(.center).padding(6)
                }
            }
            .clipped()
            .task(id: key) {
                guard let url else { cg = nil; loadedKey = key; return }
                if let hit = PictureCache.shared.get(key) { cg = hit; loadedKey = key; return }
                let (c, m) = (crop, maxPixel)
                let img = await Task.detached(priority: .userInitiated) { PictureCache.load(url, crop: c, maxPixel: m) }.value
                if let img { PictureCache.shared.set(key, img) }
                cg = img; loadedKey = key
            }
    }
}
