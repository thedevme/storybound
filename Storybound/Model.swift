import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// One scene's storyboard prompt (episode-stories/_viewer/storyboards.json, written by build_storyboards.py).
struct Storyboard: Codable, Identifiable {
    var id: String; var name: String; var type: String; var plate: String; var wide: String
    var beats: [Int]; var prompt: String
    var paintPrompt: String?        // the watercolor prompt: the series STYLE LOCK plus the scene
    var zooms: [String: BeatPlan]?
    var plateKey: String?           // the shared plate this scene sits on (T1 DAY, T3 NIGHT ...)
    var ref: String?                // Ep 1: the location painting the scene is drawn from, or the picture an edit starts from
    var edit: Bool?                 // made by editing that picture: no sketch step
    var isEdit: Bool { edit == true }
    var isPoseDrop: Bool { type == "pose" }
}
/// A beat's planned zoom into its scene, and the pose for a pose drop.
struct BeatPlan: Codable {
    var scale: Double?; var x: Double?; var y: Double?; var type: String?; var pose: String?
    var look: String?; var why: String?
    /// The planned zoom as a frame the app can show and save.
    var frame: BeatFrame? { guard let scale, let x, let y else { return nil }; return BeatFrame(scale: scale, x: x, y: y).clamped() }
}
struct StoryboardFile: Codable { var styleLock: String; var paintStyleLock: String?; var episodes: [String: [Storyboard]]; var plates: [PlateInfo]? }
/// A shared background plate: drop it once on the Plates page and every scene on it shows it.
struct PlateInfo: Codable, Identifiable {
    var id: String; var name: String; var file: String; var scenes: Int; var beats: Int
    var storyboardPrompt: String?; var paintingPrompt: String?
}

/// The season scene review (episode-stories/_viewer/review.json, written by build_review.py).
struct ReviewFile: Codable { var summary: [ReviewRow]; var decisions: [Decision]; var report: String }
struct ReviewRow: Codable, Identifiable {
    var ep: Int; var title: String; var paintedNow: String; var poseNow: String; var paintedProposed: String; var poseProposed: String; var change: String
    var id: Int { ep }
}
struct Decision: Codable, Identifiable {
    var n: Int; var title: String; var question: String; var detail: String; var recommend: String; var craig: Bool
    var id: Int { n }
}

// MARK: - Season data (episode-stories/_viewer/season.json, written by build_story_viewer.py)

/// One season of a project. Characters, locations, food and the rest of the library belong to the project, so every season shares them.
struct SeasonInfo: Codable, Identifiable, Hashable { var n: Int; var title: String; var id: Int { n } }

struct Season: Codable {
    var seasons: [SeasonInfo]? = nil
    var eps: [Episode]
    var cast: [Person]
    var food: [Dish]
    var truck: Truck
}

struct Episode: Codable, Identifiable {
    var n: Int
    var title: String
    var made: Bool
    var logline: String
    var summary: [[String]]
    var sections: [Section]
    var beats: [Beat]
    var gpt: [GPTImage]
    var built: [Still]
    var prep: [Prep]
    var audio: String?
    var timing: [[Double]]?
    var words: Int
    var ends: String
    var season: Int? = nil      // which season it's in; none means the first
    var numberInSeason: Int? = nil   // worked out when the file loads; n stays the id everything is saved under
    var id: Int { n }
    var seasonN: Int { season ?? 1 }
    var number: Int { numberInSeason ?? n }
    /// "Episode 3", or "S2 Episode 3" past the first season, where the same number would otherwise repeat.
    var label: String { seasonN > 1 ? "S\(seasonN) Episode \(number)" : "Episode \(number)" }
    var minutes: String { String(format: "%.1f", Double(words) / 150) }
    var gptCount: Int { gpt.reduce(0) { $0 + ($1.count ?? 1) } }
}

struct Section: Codable, Identifiable {
    var span: String
    var title: String
    var opts: [SectionOption]
    var id: String { span }
    var range: ClosedRange<Int> {
        let p = span.replacingOccurrences(of: "–", with: "-").split(separator: "-").compactMap { Int($0) }
        let lo = p.first ?? 0
        return lo...max(lo, p.last ?? lo)         // a new episode with no beats has the span "1-0"
    }
}

struct SectionOption: Codable {
    var t: String
    var new: String
    var rec: Bool
    var beats: [[String]]
    var up: String
    var `catch`: String
}

struct Beat: Codable, Identifiable {
    var n: Int
    var text: String
    var kind: String
    var img: String
    var what: String
    var thumb: String?
    var id: Int { n }
    var wordCount: Int { text.split(separator: " ").count }
}

struct GPTImage: Codable, Identifiable {
    var id: String
    var name: String
    var beats: String
    var kind: String
    var view: String
    var shows: String
    var zooms: [String]
    var attach: [String]
    var watch: [String]
    var why: String
    var count: Int?
}

struct Still: Codable, Identifiable {
    var id: String
    var name: String
    var beats: String
    var opts: [String]
    var looks: String
    var doing: String
    var why: String
    var choices: [String] { opts.isEmpty ? [looks] : opts }
}

struct Prep: Codable, Identifiable {
    var id: String
    var name: String
    var use: String
    var looks: String
    var why: String
}

struct Person: Codable, Identifiable {
    var name: String
    var eps: String
    var status: String
    var look: String
    var heat: [Int]
    var id: String { name }
}

struct Dish: Codable, Identifiable {
    var name: String
    var eps: String
    var who: String
    var look: String
    var heat: [Int]
    var id: String { name }
}

struct Truck: Codable {
    var layout: String
    var views: [[String]]
}

// MARK: - Things you add (saved as files in _viewer/user/)

struct UserState: Codable {
    var stills: [String: Int] = [:]      // "still:N:ID" -> chosen option
    var made: [String: Bool] = [:]       // make-list ticks
    var images: [String: String] = [:]   // image key -> file name in user/
    var audio: [String: String] = [:]    // "audio:eN" -> file name in user/
    var truckLayout: String? = nil       // your edit of the truck layout text
    var truckViews: [[String]]? = nil    // your edit of the truck views: [id, name, text]
    var frames: [String: BeatFrame]? = nil   // "eNbN" -> how that beat zooms into its picture
    var answers: [String: String]? = nil     // scene review: decision number -> your answer
    var holds: [String: Bool]? = nil         // scene review: fixes you said to hold
    var autoZoom: [String: AutoZoomResult]? = nil   // "eNbN" -> what auto-zoom found (or found missing) in the picture
    var motion: [String: BeatMotion]? = nil         // "eNbN" -> your move and transition for the video (else the suggestion)
    var lines: [String: String]? = nil              // "eNbN" -> your edit of that beat's line
    var recordedLines: [String: [String: String]]? = nil   // "eN" -> the lines as they were when the recording was synced
    var syncTimes: [String: [[Double]]]? = nil       // "eN" -> [beat, start, end] heard in the recording
    var alignedTimes: [String: [[Double]]]? = nil    // "eN" -> the times as synced, kept once you move a cut: where each line's words really are
    var syncNotes: [String: String]? = nil           // "eN" -> how the last sync went
    var heard: [String: [HeardWord]]? = nil          // "eN" -> every word heard in the recording, with its time
    var cutBase: [String: [String: Double]]? = nil   // "eN" -> beat -> where the app last put that cut; a cut anywhere else was set by hand
    var wordMethod: [String: Int]? = nil             // "eN" -> how those times were found; below wordMethodNow, they're listened for again
    var prompts: [String: String]? = nil             // image key -> your prompt for that slot ("food-sketch:…", "food:…")
    var trailerLogo: [String]? = nil                 // trailer shots that show the logo over them (nil = T01 and T25)
    var done: [String: Bool]? = nil                  // "trailer:T01", "e2b14" -> you marked it done
}

/// How a beat shows its picture: zoom (1 = the whole frame) and the point it centers on (0...1 across and down).
struct BeatFrame: Codable, Equatable {
    var scale = 1.0
    var x = 0.5
    var y = 0.5
    /// Keeps the zoom between 1× and 4× and the picture filling the frame (no empty edges).
    func clamped() -> BeatFrame {
        var f = self
        f.scale = min(4, max(1, f.scale))
        let h = 0.5 / f.scale
        f.x = min(1 - h, max(h, f.x)); f.y = min(1 - h, max(h, f.y))
        return f
    }
    var isFull: Bool { scale <= 1.001 }
}

enum Kind {
    static func label(_ k: String) -> String {
        switch k {
        case "gpt": return "Painted (ChatGPT)"
        case "built": return "Still (I build)"
        case "done": return "Done"
        case "plate": return "Plate"
        case "reuse": return "Reuse"
        default: return k
        }
    }
}

/// Reads an image file with ImageIO and hands it to SwiftUI.
/// Loads a picture decoded up front, so scrolling never decodes it. Cards and panels get a copy at most
/// `maxPixel` wide (a 5K plate shrunk to 2400 px); pass nil for the full-size file (the full-screen viewer).
func loadImage(_ url: URL, maxPixel: Int? = 2400) -> Image? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    var opts: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true, kCGImageSourceCreateThumbnailWithTransform: true]
    let cg: CGImage?
    if let maxPixel {
        opts[kCGImageSourceCreateThumbnailFromImageAlways] = true
        opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
        cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    } else {
        cg = CGImageSourceCreateImageAtIndex(src, 0, opts as CFDictionary)
    }
    return cg.map { Image(decorative: $0, scale: 1) }
}

// MARK: - The store

final class Store: ObservableObject {
    @Published var season: Season?
    @Published var projects: [BenchProject] = []
    @Published var projectEpisodes: [String: Int] = [:]   // project id -> how many episodes it has
    @Published var projectSeasons: [String: [String]] = [:]   // project id -> its season titles, when the file lists them
    @Published var storyboards: [Int: [Storyboard]] = [:]
    @Published var plates: [PlateInfo] = []
    @Published var sketchStyle = ""          // the pencil storyboard style lock
    @Published var paintStyle = ""           // the series watercolor STYLE LOCK
    @Published var review: ReviewFile?
    @Published var state = UserState()
    @Published var syncing: [Int: String] = [:]     // episode -> what the beat sync is doing
    var retimeUndo: [Int: (times: [[Double]]?, base: [String: Double]?)] = [:]   // what Undo puts back after a re-time
    var wordJob: Task<Void, Never>? = nil            // the recording being listened to for word times; they run one at a time
    var originalLines: [Int: [Int: String]] = [:]   // each episode's lines as written, before your edits
    @Published var loadError: String?
    @Published var toast: String?
    @Published var imageVersion = 0      // bumps when an image changes, so views reload
    let folderKey = "projectFolder"
    var imageCache: [String: Image?] = [:]   // a nil entry remembers a missing file, so it isn't looked for again
    func cached(_ k: String, _ load: () -> Image?) -> Image? {
        if let hit = imageCache[k] { return hit }
        let i = load(); imageCache[k] = .some(i); return i
    }

    var folder: URL {
        get {
            if let p = Store.defaults.string(forKey: folderKey) { return URL(fileURLWithPath: p) }
            return Store.kitchenFolder
        }
        set { Store.defaults.set(newValue.path, forKey: folderKey) }
    }
    var dataDir: URL { folder.appendingPathComponent("_viewer") }
    var userDir: URL { dataDir.appendingPathComponent("user") }
    var stateURL: URL { userDir.appendingPathComponent("state.json") }

    init() { load(); loadProjects() }

    func load() {
        loadError = nil
        do {
            let data = try Data(contentsOf: dataDir.appendingPathComponent("season.json"))
            var loaded = try JSONDecoder().decode(Season.self, from: data)
            var seen: [Int: Int] = [:]
            for i in loaded.eps.indices { let k = loaded.eps[i].seasonN; seen[k, default: 0] += 1; loaded.eps[i].numberInSeason = seen[k] }
            season = loaded
        } catch {
            season = nil
            loadError = "Couldn't read \(dataDir.appendingPathComponent("season.json").path).\n\(error.localizedDescription)"
        }
        if let d = try? Data(contentsOf: dataDir.appendingPathComponent("storyboards.json")),
           let f = try? JSONDecoder().decode(StoryboardFile.self, from: d) {
            storyboards = Dictionary(uniqueKeysWithValues: f.episodes.compactMap { k, v in Int(k).map { ($0, v) } })
            plates = f.plates ?? []
            sketchStyle = f.styleLock; paintStyle = f.paintStyleLock ?? ""
        } else { storyboards = [:]; plates = [] }
        review = (try? Data(contentsOf: dataDir.appendingPathComponent("review.json"))).flatMap { try? JSONDecoder().decode(ReviewFile.self, from: $0) }
        try? FileManager.default.createDirectory(at: userDir, withIntermediateDirectories: true)
        // a project with no saved state starts empty, so one project's images and notes never carry into another
        if let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(UserState.self, from: d) { state = s } else { state = UserState() }
        syncing = [:]
        originalLines = [:]; applyLineEdits()
        imageCache.removeAll(); imageVersion += 1
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(state) { try? d.write(to: stateURL) }
    }

    func say(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in if self?.toast == msg { self?.toast = nil } }
    }

    // MARK: ids and keys (the same scheme as the browser viewer)
    static func ids(_ img: String) -> [String] {
        img.components(separatedBy: CharacterSet(charactersIn: " +,→")).filter { !$0.isEmpty }
    }
    /// The still with this id; a range id like "B1–B5" covers B1, B2, B3, B4 and B5.
    func stillFor(_ e: Episode, id t: String) -> Still? {
        e.built.first { s in
            if s.id == t { return true }
            let ends = s.id.components(separatedBy: "–")
            guard ends.count == 2, let lo = Int(ends[0].filter(\.isNumber)), let hi = Int(ends[1].filter(\.isNumber)),
                  let n = Int(t.filter(\.isNumber)), t.first == ends[0].first else { return false }
            return (lo...hi).contains(n)
        }
    }
    func knownId(_ e: Episode, _ t: String) -> Bool { e.gpt.contains { $0.id == t } || stillFor(e, id: t) != nil }
    func primaryId(_ e: Episode, _ b: Beat) -> String { Store.ids(b.img).first { knownId(e, $0) } ?? b.img }
    func keyImg(_ e: Episode, _ id: String) -> String { "e\(e.n):\(id)" }
    func keyBeat(_ e: Episode, _ b: Beat) -> String { "e\(e.n)b\(b.n)" }
    func optKey(_ e: Episode, _ id: String, _ i: Int) -> String { "e\(e.n):\(id):opt\(i)" }
    func stillKey(_ e: Episode, _ id: String) -> String { "still:\(e.n):\(id)" }
    /// The still a beat shows, only if that still lists the beat (a painted image can share a still's code).
    func stillOf(_ e: Episode, _ b: Beat) -> Still? {
        for t in Store.ids(b.img) { if let s = stillFor(e, id: t), Store.beatNumbers(s.beats).contains(b.n) { return s } }
        return nil
    }
    /// "7, 17, 25" or "41 to 46" or "64–72" → the beat numbers.
    static func beatNumbers(_ text: String) -> Set<Int> {
        var out = Set<Int>()
        let parts = text.replacingOccurrences(of: " to ", with: "-").replacingOccurrences(of: "–", with: "-").split(separator: ",")
        for p in parts {
            let ends = p.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if ends.count == 2, ends[0] <= ends[1] { out.formUnion(ends[0]...ends[1]) } else if let n = ends.first { out.insert(n) }
        }
        return out
    }
    func chosen(_ e: Episode, _ s: Still) -> Int { state.stills[stillKey(e, s.id)] ?? 0 }
    func picked(_ e: Episode, _ s: Still) -> Bool { state.stills[stillKey(e, s.id)] != nil || state.images[keyImg(e, s.id)] != nil }
    func choose(_ e: Episode, _ s: Still, _ i: Int) {
        state.stills[stillKey(e, s.id)] = i; save(); say("Still \(s.id): option \(["A", "B", "C"][min(i, 2)])")
    }

    // MARK: framing
    func frame(_ e: Episode, _ b: Beat) -> BeatFrame? { state.frames?[keyBeat(e, b)] }
    /// How the beat shows its picture: your framing if you set one, otherwise the plan's zoom for this beat.
    /// A beat with its own picture ("This beat only") shows it whole unless you framed it: the plan's zoom was for the scene.
    func shownFrame(_ e: Episode, _ b: Beat) -> BeatFrame? {
        if hasImage(keyBeat(e, b)) { return frame(e, b) }
        return frame(e, b) ?? storyboard(e, b)?.zooms?[String(b.n)]?.frame
    }
    func setFrame(_ e: Episode, _ b: Beat, _ f: BeatFrame?) {
        var m = state.frames ?? [:]
        m[keyBeat(e, b)] = (f?.isFull ?? true) ? nil : f?.clamped()
        state.frames = m; save()
    }

    // MARK: images
    func hasImage(_ key: String) -> Bool { state.images[key] != nil }
    func image(_ key: String) -> Image? {
        guard let f = state.images[key] else { return nil }
        return cached(key) { loadImage(userDir.appendingPathComponent(f)) }
    }
    /// The beat's picture at full size: the 1920px built still when there is one, else what the card shows.
    func fullPicture(_ e: Episode, _ b: Beat) -> Image? {
        if userImage(e, b) == nil, (stillOf(e, b).map { chosen(e, $0) == 0 } ?? true) {
            let still = cached("full:\(e.n)-\(b.n)") {
                let dir = dataDir.deletingLastPathComponent().appendingPathComponent(String(format: "stills/ep%02d", e.n))
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                return files.first(where: { $0.hasSuffix(String(format: "-b%02d.png", b.n)) }).flatMap { loadImage(dir.appendingPathComponent($0), maxPixel: nil) }
            }
            if let still { return still }
        }
        // your picture or the plate, at full size, not the card's copy
        if let url = pictureURL(e, b), url.path.hasPrefix(userDir.path), let i = cached("full:" + url.path, { loadImage(url, maxPixel: nil) }) { return i }
        return picture(e, b)
    }
    /// The shared plate under this beat's scene, if you've dropped one in on the Plates page.
    func plateKey(_ e: Episode, _ b: Beat) -> String? { storyboard(e, b)?.plateKey }
    func plateImage(_ e: Episode, _ b: Beat) -> Image? { plateKey(e, b).flatMap { plateShownKey($0) }.flatMap { image($0) } }
    /// A plate has two slots: the pencil sketch ("plate:ID") and the painting ("plate-paint:ID"). Scenes show the painting once it's in.
    func plateShownKey(_ id: String) -> String? {
        hasImage("plate-paint:\(id)") ? "plate-paint:\(id)" : hasImage("plate:\(id)") ? "plate:\(id)" : nil
    }
    func plateHasAny(_ id: String) -> Bool { plateShownKey(id) != nil }
    /// The file behind a beat's picture: your image, the built still, the plate, or the thumbnail.
    func pictureURL(_ e: Episode, _ b: Beat) -> URL? {
        for k in [keyBeat(e, b)] + sceneKeys(e, b) + Store.ids(b.img).map({ keyImg(e, $0) }) + [keyImg(e, b.img)] + (plateKey(e, b).flatMap { plateShownKey($0) }.map { [$0] } ?? []) {
            if let f = state.images[k] { return userDir.appendingPathComponent(f) }
        }
        let still = dataDir.appendingPathComponent("stills/e\(e.n)-b\(b.n).jpg")
        if FileManager.default.fileExists(atPath: still.path) { return still }
        return b.thumb.map { dataDir.appendingPathComponent("thumbs/\($0).jpg") }
    }
    /// The file behind the picture a beat's full-screen view shows, in the same order as `fullPicture` and the card:
    /// the 1920 px built still, your option mockup, then whatever `pictureURL` finds.
    func fullPictureURL(_ e: Episode, _ b: Beat) -> URL? {
        if userImage(e, b) == nil {
            if stillOf(e, b).map({ chosen(e, $0) == 0 }) ?? true {
                let dir = dataDir.deletingLastPathComponent().appendingPathComponent(String(format: "stills/ep%02d", e.n))
                let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
                if let f = files.first(where: { $0.hasSuffix(String(format: "-b%02d.png", b.n)) }) { return dir.appendingPathComponent(f) }
            }
            if let s = stillOf(e, b), let f = state.images[optKey(e, s.id, chosen(e, s))] { return userDir.appendingPathComponent(f) }
        }
        return pictureURL(e, b)
    }
    /// Finds each beat's zoom in the scene's picture on this Mac, and notes what's missing. Fills only beats you
    /// haven't framed, unless `all` is true.
    func autoZoom(_ e: Episode, _ s: Storyboard, all: Bool = false) async {
        guard let first = s.beats.lazy.compactMap({ n in e.beats.first { $0.n == n } }).first,
              let url = pictureURL(e, first), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { say("No picture to zoom into"); return }
        let todo = s.beats.compactMap { n in e.beats.first { $0.n == n } }.filter { all || frame(e, $0) == nil }
        guard !todo.isEmpty else { say("Every beat here is already framed"); return }
        let results = await AutoZoom.run(image: cg, beats: todo.map { b in (b.n, s.zooms?[String(b.n)]?.look ?? b.what, s.zooms?[String(b.n)]?.frame) })
        var notes = state.autoZoom ?? [:]
        for r in results {
            guard let b = e.beats.first(where: { $0.n == r.beat }) else { continue }
            notes[keyBeat(e, b)] = r
            if let f = r.frame { setFrame(e, b, f) }
        }
        state.autoZoom = notes; save(); imageVersion += 1
        let missing = results.filter { !$0.found }.count
        say(missing == 0 ? "Zoomed \(results.count) beats" : "Zoomed \(results.count - missing), \(missing) not found")
    }
    func autoNote(_ e: Episode, _ b: Beat) -> AutoZoomResult? { state.autoZoom?[keyBeat(e, b)] }
    /// A character's locked design from Kitchen/ART/Characters, as a small thumbnail.
    func characterArt(_ folder: String) -> Image? {
        let ck = "art:" + folder
        if let hit = imageCache[ck] { return hit }
        let url = dataDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ART/Characters/\(folder)/\(folder) - Locked Design.png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 900] as CFDictionary) else { return nil }
        let i = Image(decorative: cg, scale: 1); imageCache[ck] = .some(i); return i
    }
    /// The storyboard for the scene this beat belongs to, if one is planned.
    func storyboard(_ e: Episode, _ b: Beat) -> Storyboard? { storyboards[e.n]?.first { $0.beats.contains(b.n) } }
    func thumb(_ k: String?) -> Image? {
        guard let k else { return nil }
        return cached("thumb:" + k) { loadImage(dataDir.appendingPathComponent("thumbs/\(k).jpg")) }
    }
    /// The chapter title card for section i of an episode (made by build_title_cards.py).
    func titleCard(_ e: Episode, _ i: Int) -> Image? {
        let k = "title:\(e.n)-\(i)"
        return cached(k) { loadImage(dataDir.appendingPathComponent("titles/e\(e.n)-\(i).jpg")) }
    }
    var plan: Image? { loadImage(dataDir.appendingPathComponent("plan.png")) }
    /// One picture for every beat in a scene of the new plan (Ep 2 on), each beat with its own zoom.
    func sceneKey(_ e: Episode, _ s: Storyboard) -> String { "scene:e\(e.n):\(s.id)" }
    func sceneKey(_ e: Episode, _ b: Beat) -> String? { storyboard(e, b).map { sceneKey(e, $0) } }
    /// A scene has two slots like a plate: the painting ("scene:…") and the pencil sketch ("scene-sketch:…").
    /// Its beats show the painting once it's in, and the sketch until then.
    func sceneSketchKey(_ e: Episode, _ s: Storyboard) -> String { "scene-sketch:e\(e.n):\(s.id)" }
    func sceneKeys(_ e: Episode, _ b: Beat) -> [String] { ["beat-sketch:\(keyBeat(e, b))"] + (storyboard(e, b).map { [sceneKey(e, $0), sceneSketchKey(e, $0)] } ?? []) }
    func userImage(_ e: Episode, _ b: Beat) -> Image? {
        if let i = image(keyBeat(e, b)) { return i }
        for k in sceneKeys(e, b) { if let i = image(k) { return i } }
        for t in Store.ids(b.img) { if let i = image(keyImg(e, t)) { return i } }
        return image(keyImg(e, b.img))
    }
    func isYours(_ e: Episode, _ b: Beat) -> Bool {
        hasImage(keyBeat(e, b)) || sceneKeys(e, b).contains(where: hasImage) || Store.ids(b.img).contains { hasImage(keyImg(e, $0)) } || hasImage(keyImg(e, b.img))
    }
    /// A small copy of one of your images for the beat cards: decoded once at 1400 px, so the grid scrolls without
    /// resampling 4K plates. The panel and viewer still use the larger copies.
    func cardImage(_ key: String) -> Image? {
        guard let f = state.images[key] else { return nil }
        return cached("card:" + key) { loadImage(userDir.appendingPathComponent(f), maxPixel: 1400) }
    }
    /// What a beat card shows: the same picture as picture(e, b), from the small card copies.
    func cardPicture(_ e: Episode, _ b: Beat) -> Image? {
        for k in [keyBeat(e, b)] + sceneKeys(e, b) + Store.ids(b.img).map({ keyImg(e, $0) }) + [keyImg(e, b.img)] where hasImage(k) {
            return cardImage(k)
        }
        if let s = stillOf(e, b), let i = image(optKey(e, s.id, chosen(e, s))) { return i }
        if (stillOf(e, b).map { chosen(e, $0) == 0 } ?? true), let i = builtStill(e, b) { return i }
        if let k = plateKey(e, b).flatMap({ plateShownKey($0) }), let i = cardImage(k) { return i }
        return thumb(b.thumb)
    }
    func picture(_ e: Episode, _ b: Beat) -> Image? {
        if let i = userImage(e, b) { return i }
        if let s = stillOf(e, b), let i = image(optKey(e, s.id, chosen(e, s))) { return i }
        if (stillOf(e, b).map { chosen(e, $0) == 0 } ?? true), let i = builtStill(e, b) { return i }
        if let i = plateImage(e, b) { return i }
        return thumb(b.thumb)
    }
    /// True when the beat needs people painted in but is only showing an empty location: the shared plate or the
    /// location's reference picture. Plate beats (no cast) never count.
    func isLocationOnly(_ e: Episode, _ b: Beat) -> Bool {
        if userImage(e, b) != nil { return false }
        if let s = stillOf(e, b), image(optKey(e, s.id, chosen(e, s))) != nil { return false }
        if (stillOf(e, b).map { chosen(e, $0) == 0 } ?? true), builtStill(e, b) != nil { return false }
        if let s = storyboard(e, b) { return s.type != "plate" }
        return b.kind == "gpt"
    }
    /// The finished still made for this beat (option A), by build_ep01_stills.py and its siblings.
    func builtStill(_ e: Episode, _ b: Beat) -> Image? {
        let k = "built:\(e.n)-\(b.n)"
        return cached(k) { loadImage(dataDir.appendingPathComponent("stills/e\(e.n)-b\(b.n).jpg")) }
    }
    func setImage(_ key: String, from url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { say("That is not an image file."); return }
        let safe = key.replacingOccurrences(of: ":", with: "_")
        let name = "\(safe)-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.lowercased())"
        do {
            if let old = state.images[key] { try? FileManager.default.removeItem(at: userDir.appendingPathComponent(old)) }
            try FileManager.default.copyItem(at: url, to: userDir.appendingPathComponent(name))
            // a new picture for one beat starts whole: the framing it had was for the scene's picture
            if key.range(of: #"^e\d+b\d+$"#, options: .regularExpression) != nil { state.frames?[key] = nil }
            state.images[key] = name; imageCache[key] = nil; imageCache["card:" + key] = nil; save(); imageVersion += 1; say("Image added")
        } catch { say("Couldn't save the image: \(error.localizedDescription)") }
    }
    /// The image you added that this beat is showing, and where it lives: this beat only, every beat using its
    /// picture, or the shared plate. Built stills and thumbnails aren't yours to remove.
    func shownImageSource(_ e: Episode, _ b: Beat) -> (key: String, label: String, beats: Int)? {
        if hasImage(keyBeat(e, b)) { return (keyBeat(e, b), "this beat only", 1) }
        if hasImage("beat-sketch:\(keyBeat(e, b))") { return ("beat-sketch:\(keyBeat(e, b))", "this beat only (the sketch)", 1) }
        if let s = storyboard(e, b), hasImage(sceneKey(e, s)) { return (sceneKey(e, s), "every beat in scene \(s.id) (the painting)", s.beats.count) }
        if let s = storyboard(e, b), hasImage(sceneSketchKey(e, s)) { return (sceneSketchKey(e, s), "every beat in scene \(s.id) (the sketch)", s.beats.count) }
        for t in Store.ids(b.img) + [b.img] where hasImage(keyImg(e, t)) {
            return (keyImg(e, t), "every beat using \(t)", e.beats.filter { Store.ids($0.img).contains(t) || $0.img == t }.count)
        }
        if let p = plateKey(e, b), let k = plateShownKey(p) {
            return (k, "the \(p) plate\(k.hasPrefix("plate-paint") ? " painting" : " sketch")", plates.first { $0.id == p }?.beats ?? 0)
        }
        return nil
    }
    func removeImage(_ key: String) {
        if let f = state.images[key] { try? FileManager.default.removeItem(at: userDir.appendingPathComponent(f)) }
        state.images[key] = nil; imageCache[key] = nil; imageCache["card:" + key] = nil; save(); imageVersion += 1; say("Image removed")
    }
    /// Your prompt for an image slot, kept beside its picture in state.json.
    func prompt(_ key: String) -> String { state.prompts?[key] ?? "" }
    func setPrompt(_ key: String, _ text: String) {
        var m = state.prompts ?? [:]
        m[key] = text.isEmpty ? nil : text
        state.prompts = m; save()
    }
    /// A picture on disk, outside user/ (the trailer storyboard panels), as a card-sized copy.
    func fileImage(_ url: URL, maxPixel: Int = 1400) -> Image? {
        cached("file:\(maxPixel):" + url.path) { loadImage(url, maxPixel: maxPixel) }
    }
    /// Forgets cached copies of files outside user/, so redrawn panels show up.
    func refreshFiles() {
        for k in imageCache.keys where k.hasPrefix("file:") { imageCache[k] = nil }
        imageVersion += 1
    }

    // MARK: audio
    func audioKey(_ e: Episode) -> String { "audio:e\(e.n)" }
    func isOwnAudio(_ e: Episode) -> Bool { state.audio[audioKey(e)] != nil }
    func audioURL(_ e: Episode) -> URL? {
        if let f = state.audio[audioKey(e)] { return userDir.appendingPathComponent(f) }
        if let a = e.audio { let u = folder.appendingPathComponent(a); return FileManager.default.fileExists(atPath: u.path) ? u : nil }
        return nil
    }
    func setAudio(_ e: Episode, from url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { say("That is not an audio file."); return }
        let name = "audio-e\(e.n)-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.lowercased())"
        do {
            if let old = state.audio[audioKey(e)] { try? FileManager.default.removeItem(at: userDir.appendingPathComponent(old)) }
            try FileManager.default.copyItem(at: url, to: userDir.appendingPathComponent(name))
            state.audio[audioKey(e)] = name
            state.syncTimes?["e\(e.n)"] = nil; state.alignedTimes?["e\(e.n)"] = nil; state.syncNotes?["e\(e.n)"] = nil
            save(); say("Recording added to \(e.label). Syncing the beats to it…")
            Task { @MainActor in await syncBeats(e) }
        } catch { say("Couldn't save the audio: \(error.localizedDescription)") }
    }
    func removeAudio(_ e: Episode) {
        if let f = state.audio[audioKey(e)] { try? FileManager.default.removeItem(at: userDir.appendingPathComponent(f)) }
        state.audio[audioKey(e)] = nil; state.cutBase?["e\(e.n)"] = nil; state.heard?["e\(e.n)"] = nil; state.syncTimes?["e\(e.n)"] = nil; state.alignedTimes?["e\(e.n)"] = nil; state.syncNotes?["e\(e.n)"] = nil; save(); say("Your recording removed")
    }
    /// [start, end] per beat: the episode's measured timings, or by word count for a recording you dropped in.
    func beatTimes(_ e: Episode, duration: Double) -> [(Double, Double)] {
        // the times heard in the recording when you've synced it
        if let s = state.syncTimes?["e\(e.n)"] {
            var m: [Int: (Double, Double)] = [:]
            for r in s where r.count >= 3 { m[Int(r[0])] = (r[1], r[2]) }
            // beats added after the sync sit at the end of the recording, at no length, until it's synced again
            if let top = m.keys.max(), e.beats.allSatisfy({ m[$0.n] != nil || $0.n > top }) {
                let end = m[top]!.1
                return e.beats.map { m[$0.n] ?? (end, end) }
            }
        }
        if let t = e.timing, !isOwnAudio(e) {
            var m: [Int: (Double, Double)] = [:]
            for r in t where r.count >= 3 { m[Int(r[0])] = (r[1], r[2]) }
            return e.beats.map { m[$0.n] ?? (0, 0) }
        }
        let w = e.beats.map { Double(max(3, $0.wordCount)) }; let tot = w.reduce(0, +)
        var t = 0.0
        return w.map { x in let a = t; t += duration * x / tot; return (a, t) }
    }

    // MARK: backup
    func backup(to dir: URL) {
        let dst = dir.appendingPathComponent("Season-1-viewer-backup-\(Int(Date().timeIntervalSince1970))")
        do { try FileManager.default.copyItem(at: userDir, to: dst); say("Backed up to \(dst.lastPathComponent)") }
        catch { say("Backup failed: \(error.localizedDescription)") }
    }
    func restore(from dir: URL) {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("state.json").path) else { say("That folder isn't a viewer backup."); return }
        do {
            let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for i in items {
                let d = userDir.appendingPathComponent(i.lastPathComponent)
                try? FileManager.default.removeItem(at: d); try FileManager.default.copyItem(at: i, to: d)
            }
            load(); say("Restored")
        } catch { say("Restore failed: \(error.localizedDescription)") }
    }
}
