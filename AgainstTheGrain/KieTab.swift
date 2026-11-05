import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The Kie tab: type any prompt, pick the model and settings, submit. Exactly the typed prompt is sent; nothing is added.
// One for the whole app, whichever project is open. Pictures save to Kitchen/ART/Kie with a .json beside each holding its prompt and settings.

enum KieChoice: String, CaseIterable, Identifiable, Codable {
    case nano = "Nano Banana", gpt = "GPT"
    var id: String { rawValue }
    func modelID(hasRefs: Bool) -> String {
        switch self {
        case .nano: return "nano-banana-2"
        case .gpt: return hasRefs ? "gpt-image-2-5-sunburst-image-to-image" : "gpt-image-2-5-sunburst-text-to-image"
        }
    }
    /// The `input` Kie gets. The two models name their reference images differently.
    func input(prompt: String, res: String, aspect: String, urls: [String]) -> [String: Any] {
        var out: [String: Any] = ["prompt": prompt, "aspect_ratio": aspect, "resolution": res]
        switch self {
        case .nano: out["output_format"] = "png"; if !urls.isEmpty { out["image_input"] = urls }
        case .gpt: if !urls.isEmpty { out["input_urls"] = urls }
        }
        return out
    }
}

/// A finished picture and what made it (the .json beside the picture).
struct KieResult: Codable, Identifiable, Equatable {
    var id: String { file }
    let file: String
    let prompt: String
    let choice: KieChoice
    let model: String
    let res: String
    let aspect: String
    let refs: [String]
    let credits: String?
    let task: String
    let date: Date
}

/// A submit still going, or one that failed.
struct KieRun: Identifiable {
    let id = UUID()
    let title: String
    var status: String
    var failed = false
    var step = 0                 // 0 sending, 1 in line at Kie, 2 making it, 3 downloading
    var percent: Double? = nil   // only when Kie reports one
    var started = Date()
    static let steps = ["Sending", "In line", "Making", "Downloading"]
}

enum KieMode: String, CaseIterable { case generate = "Generate", edit = "Edit", animate = "Animate" }
struct KiePreset: Codable, Identifiable, Hashable {
    var name: String; var note: String; var icon: String = "bookmark"; var text: String
    var id: String { name }
    /// Each one adds its sentence to the prompt box, where you can read and change it. Nothing is added after that.
    static let builtIn = [
        KiePreset(name: "Scene continuation", note: "Keep style & character", icon: "arrow.triangle.turn.up.right.diamond", text: "Continue the same scene from the attached image. Keep the art style and character exactly as drawn."),
        KiePreset(name: "Different angles", note: "Same scene, new view", icon: "cube", text: "Show the same scene from a different camera angle. Keep the character, setting and art style exactly the same."),
        KiePreset(name: "Another variation", note: "New take on the reference", icon: "square.on.square", text: "Make another variation of the reference image. Keep the same subject, style, colors and overall composition, and change only small details so it reads as a fresh take on the same image."),
        KiePreset(name: "Expression study", note: "Emotions & reactions", icon: "face.smiling", text: "Keep the character exactly as drawn and change only the facial expression and posture to show the emotion described."),
        KiePreset(name: "Lighting variations", note: "Try different moods", icon: "sun.max", text: "Keep the composition exactly the same and change only the lighting and mood."),
        KiePreset(name: "Storyboard panel", note: "Cinematic framing", icon: "rectangle.on.rectangle", text: "Draw this as one cinematic storyboard panel, full frame, with no text, borders or labels."),
        KiePreset(name: "Clean background", note: "Character on neutral", icon: "person.crop.rectangle", text: "Keep the character exactly as drawn on a plain neutral background, with no props or scenery."),
    ]
}

@MainActor
final class KieStudio: ObservableObject {
    static let shared = KieStudio()      // one for the app, so runs and the typed prompt survive switching tabs
    static let ratios = ["16:9", "9:16", "1:1", "3:2", "2:3", "4:3", "3:4", "21:9"]

    @Published var prompt = ""
    @Published var choice = KieChoice.gpt
    @Published var res = "1K"
    @Published var aspect = "16:9"
    @Published var refs: [URL] = []
    @Published var runs: [KieRun] = []
    @Published var results: [KieResult] = []
    @Published var shown: KieResult?
    @Published var balance: Double?
    @Published var balanceFailed = false
    @Published var mode = KieMode.generate
    @Published var count = 1                      // how many separate jobs one Generate sends
    @Published var useRefs = true                 // off: the reference images stay here but aren't sent
    @Published var editSource: URL?               // the Edit tab's picture: sent as Image 1
    @Published var query = ""
    @Published var oldestFirst = false
    @Published var favorites: [String] = UserDefaults.standard.stringArray(forKey: "kieFavoritePresets") ?? [] { didSet { UserDefaults.standard.set(favorites, forKey: "kieFavoritePresets") } }
    @Published var myPresets: [KiePreset] = (UserDefaults.standard.data(forKey: "kieMyPresets").flatMap { try? JSONDecoder().decode([KiePreset].self, from: $0) }) ?? [] {
        didSet { if let d = try? JSONEncoder().encode(myPresets) { UserDefaults.standard.set(d, forKey: "kieMyPresets") } }
    }
    var folder: URL?

    func url(_ r: KieResult) -> URL? { folder?.appendingPathComponent(r.file) }

    func load() {
        guard let folder else { return }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        results = files.filter { $0.pathExtension == "json" }
            .compactMap { (try? Data(contentsOf: $0)).flatMap { try? dec.decode(KieResult.self, from: $0) } }
            .sorted { $0.date > $1.date }
        if shown == nil { shown = results.first }
    }

    func refreshBalance() {
        Task {
            if let b = try? await Kie.balance() { balance = b; balanceFailed = false } else { balanceFailed = true }
        }
    }

    /// What this submit should cost: the last real price for these settings, else the prices seen so far. Nil when unknown.
    var estimate: Int? {
        if let last = results.first(where: { $0.choice == choice && $0.res == res }), let c = last.credits, let n = Double(c) { return Int(n.rounded()) }
        switch (choice, res) {
        case (.gpt, "1K"): return 6
        case (.gpt, "4K"): return 16
        case (.nano, "1K"): return 8
        default: return nil
        }
    }

    var canSubmit: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (mode != .edit || editSource != nil) }
    /// Exactly what Generate sends: the picture being edited first, then the references if they're on.
    var sentRefs: [URL] { (mode == .edit ? [editSource].compactMap { $0 } : []) + (useRefs ? refs : []) }
    var shownResults: [KieResult] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? results : results.filter { $0.prompt.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        return oldestFirst ? hits.reversed() : hits
    }
    /// Puts a finished picture's prompt and settings back in the form.
    /// Moves a picture and its .json to the Trash, so it can be put back from there. Returns why it couldn't.
    func remove(_ r: KieResult) -> String? {
        guard let u = url(r) else { return "No Kie folder" }
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: u.path) { try fm.trashItem(at: u, resultingItemURL: nil) }
            let record = u.deletingPathExtension().appendingPathExtension("json")
            if fm.fileExists(atPath: record.path) { try fm.trashItem(at: record, resultingItemURL: nil) }
        } catch { return error.localizedDescription }
        let at = results.firstIndex(of: r) ?? 0
        results.removeAll { $0 == r }
        if shown == r { shown = results.indices.contains(at) ? results[at] : results.last }
        refs.removeAll { $0 == u }
        if editSource == u { editSource = nil }
        return nil
    }

    func use(_ r: KieResult) {
        prompt = r.prompt; choice = r.choice; res = r.res; aspect = r.aspect; mode = .generate
        refs = r.refs.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func addRefs(_ urls: [URL]) {
        refs += urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true && !refs.contains($0) }
    }

    func submit() {
        guard canSubmit else { return }
        let (p, c, r, a, f) = (prompt, choice, res, aspect, sentRefs)
        let batch = (0..<max(1, count)).map { _ in KieRun(title: "\(c.rawValue) · \(r) · \(a)", status: "Starting…") }
        runs.insert(contentsOf: batch, at: 0)
        let ids = batch.map(\.id)
        Task {
            // the references upload once, one at a time (parallel uploads of big files can fail), and every job shares them
            var urls: [String] = []
            do {
                for (i, u) in f.enumerated() {
                    for id in ids { say(id, "Uploading image \(i + 1) of \(f.count)") }
                    urls.append(try await Kie.upload(u))
                }
            } catch {
                for id in ids { say(id, error.localizedDescription, failed: true) }
                return
            }
            for id in ids { Task { await go(id, prompt: p, choice: c, res: r, aspect: a, refs: f, urls: urls) } }
        }
    }

    func dismiss(_ id: UUID) { runs.removeAll { $0.id == id } }
    private func say(_ id: UUID, _ s: String, failed: Bool = false, step: Int? = nil, percent: Double? = nil) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].status = s; runs[i].failed = failed
        if let step { runs[i].step = step }
        if let percent { runs[i].percent = percent }
    }

    private func go(_ id: UUID, prompt: String, choice: KieChoice, res: String, aspect: String, refs: [URL], urls: [String]) async {
        do {
            let model = choice.modelID(hasRefs: !urls.isEmpty)
            let created = try await Kie.call("https://api.kie.ai/api/v1/jobs/createTask",
                                             body: ["model": model, "input": choice.input(prompt: prompt, res: res, aspect: aspect, urls: urls)])
            guard let task = (created["data"] as? [String: Any])?["taskId"] as? String else { throw KieError.message("No task id from Kie") }
            say(id, "Sent to Kie", step: 1)
            for _ in 0..<300 {
                try await Task.sleep(nanoseconds: 4_000_000_000)
                // a dropped connection while checking isn't a failed picture: keep checking, the job is already paid for
                guard let q = (try? await Kie.call("https://api.kie.ai/api/v1/jobs/recordInfo?taskId=\(task)"))?["data"] as? [String: Any] else { continue }
                let state = q["state"] as? String
                // Kie's own word for where the job is, and a percent if it gives one
                let told = (q["progress"] as? Double) ?? (q["progress"] as? Int).map(Double.init) ?? (q["progress"] as? String).flatMap { Double($0.replacingOccurrences(of: "%", with: "")) }
                if state == "generating" { say(id, "Kie is making it", step: 2, percent: told) }
                else if state == "waiting" || state == "queuing" { say(id, "In line at Kie", step: 1, percent: told) }
                if state == "success" {
                    var r = q["resultJson"]
                    if let s = r as? String { r = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
                    guard let link = ((r as? [String: Any])?["resultUrls"] as? [String])?.first, let u = URL(string: link) else { throw KieError.message("No picture in Kie's answer") }
                    say(id, "Downloading the picture", step: 3)
                    let (tmp, _) = try await URLSession.shared.download(from: u)
                    let credits = q["creditsConsumed"].map { "\($0)" }
                    try keep(tmp, ext: u.pathExtension, prompt: prompt, choice: choice, model: model, res: res, aspect: aspect, refs: refs, credits: credits, task: task)
                    dismiss(id); refreshBalance()
                    return
                }
                if state == "fail" { throw KieError.message((q["failMsg"] as? String) ?? "Kie said it failed") }
            }
            throw KieError.message("Stopped waiting. Task \(task) may still finish on Kie.")
        } catch {
            say(id, error.localizedDescription, failed: true); refreshBalance()
        }
    }

    /// Moves a finished picture into the folder, writes its .json, and shows it.
    func keep(_ tmp: URL, ext: String, prompt: String, choice: KieChoice, model: String, res: String, aspect: String, refs: [URL], credits: String?, task: String) throws {
        guard let folder else { throw KieError.message("No Kie folder") }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "kie-\(stamp.string(from: Date()))-\(task.suffix(6))"
        let file = base + "." + (["png", "jpg", "jpeg", "webp"].contains(ext.lowercased()) ? ext.lowercased() : "png")
        try fm.moveItem(at: tmp, to: folder.appendingPathComponent(file))
        let result = KieResult(file: file, prompt: prompt, choice: choice, model: model, res: res, aspect: aspect,
                               refs: refs.map(\.path), credits: credits, task: task, date: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted]
        try enc.encode(result).write(to: folder.appendingPathComponent(base + ".json"))
        results.insert(result, at: 0); shown = result
    }
}

/// The big picture: the whole image at whatever shape it is, as large as the space allows.
struct KiePicture: View {
    let url: URL
    @State private var loaded: (url: URL, cg: CGImage)?
    var body: some View {
        let key = PictureCache.key(url, nil, 2400, 0)
        let cg = loaded?.url == url ? loaded?.cg : PictureCache.shared.get(key)
        Group {
            if let cg { Image(decorative: cg, scale: 1).resizable().scaledToFit() } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            if let hit = PictureCache.shared.get(key) { loaded = (url, hit); return }
            let u = url
            guard let img = await Task.detached(priority: .userInitiated, operation: { PictureCache.load(u, crop: nil, maxPixel: 2400) }).value else { return }
            PictureCache.shared.set(key, img); loaded = (url, img)
        }
    }
}
