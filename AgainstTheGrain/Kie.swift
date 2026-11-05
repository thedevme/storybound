import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - One-click Kie generation (the same calls as the skill's atg.py: upload, createTask, recordInfo)
// Nothing is sent until you press OK on the "Is this right?" sheet. The key is read from
// ~/.claude/skills/generate/.env when a run starts and is never shown or logged.

/// One picture to make: a shot's B&W (always 1K) or color (always 4K) panel, from the exported prompts.json as-is.
struct GenJob: Identifiable, Equatable {
    var id: String { shot + ":" + step }
    let shot: String
    let name: String
    let step: String            // "bw" or "color"
    let prompt: String
    let refs: [PromptAttachment]
    let out: URL                // <ID>-sketch.png or <ID>-painting.png in the shot's panel folder
    var changes: [String]? = nil   // an Edit: the change lines (the picture is redrawn from the current one)
    var stateKey: String? = nil    // from the Beats page: the picture slot the result goes in
    var res: String { step == "bw" ? "1K" : "4K" }
    var credits: Int { step == "bw" ? 6 : 16 }
    var model: String { refs.isEmpty ? "gpt-image-2-5-sunburst-text-to-image" : "gpt-image-2-5-sunburst-image-to-image" }
}
let creditDollars = 0.005

enum KieError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// Talks to Kie. Every call reads the key fresh; nothing about it is printed.
enum Kie {
    static func key() throws -> String {
        let env = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/skills/generate/.env")
        guard let text = try? String(contentsOf: env, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("KIE_API_KEY=") }) else { throw KieError.message("KIE_API_KEY not found in ~/.claude/skills/generate/.env") }
        return String(line.dropFirst("KIE_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"\r"))
    }
    static func call(_ url: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var r = URLRequest(url: URL(string: url)!, timeoutInterval: 60)
        r.setValue("Bearer \(try key())", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, _) = try await URLSession.shared.data(for: r)
        guard let out = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw KieError.message("Kie sent something unreadable") }
        if let code = out["code"] as? Int, code != 200 { throw KieError.message("Kie \(code): \(out["msg"] as? String ?? "")") }
        return out
    }
    /// The account balance in credits (a free call).
    static func balance() async throws -> Double {
        let out = try await call("https://api.kie.ai/api/v1/chat/credit")
        if let n = out["data"] as? Double { return n }
        if let n = out["data"] as? Int { return Double(n) }
        throw KieError.message("No balance in Kie's answer")
    }
    /// Uploads one reference image (a ~2000 px copy if it's over 9.5 MB; the original is untouched).
    static func upload(_ file: URL) async throws -> String {
        let src = try refCopy(file)
        var r = URLRequest(url: URL(string: "https://kieai.redpandaai.co/api/file-stream-upload")!, timeoutInterval: 120)
        r.httpMethod = "POST"
        r.setValue("Bearer \(try key())", forHTTPHeaderField: "Authorization")
        let b = "atg-\(UUID().uuidString)"
        r.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        add("--\(b)\r\nContent-Disposition: form-data; name=\"uploadPath\"\r\n\r\natg-refs\r\n")
        add("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(src.lastPathComponent)\"\r\nContent-Type: image/png\r\n\r\n")
        body.append(try Data(contentsOf: src)); add("\r\n--\(b)--\r\n")
        let (d, _) = try await URLSession.shared.upload(for: r, from: body)
        guard let out = try JSONSerialization.jsonObject(with: d) as? [String: Any], let data = out["data"] as? [String: Any],
              let u = data["downloadUrl"] as? String else { throw KieError.message("Upload failed for \(file.lastPathComponent)") }
        return u
    }
    static func refCopy(_ f: URL) throws -> URL {
        let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= 9_500_000 else { return f }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("atg-ref-\(f.deletingPathExtension().lastPathComponent).png")
        guard let cg = PictureCache.load(f, crop: nil, maxPixel: 2000),
              let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw KieError.message("Couldn't shrink \(f.lastPathComponent)") }
        CGImageDestinationAddImage(dst, cg, nil); CGImageDestinationFinalize(dst)
        return out
    }
}

/// Runs jobs four at a time and reports each one's progress by job id.
/// Where one run is.
enum RunPhase: Equatable {
    case queued
    case uploading(Int, Int)       // refs sent so far, of how many
    case waiting(Date)             // Kie is drawing; since when
    case downloading
    case done(Date)
    case failed(String)            // Kie's failMsg
    var isActive: Bool { switch self { case .done, .failed: return false; default: return true } }
}

@MainActor
final class KieRunner: ObservableObject {
    @Published var status: [String: String] = [:]       // job id -> what it's doing (the short line on cards)
    @Published var failed: [String: String] = [:]       // job id -> Kie's failMsg
    @Published var running: Set<String> = []
    @Published var phase: [String: RunPhase] = [:]      // job id -> where it is, for the side panel
    @Published var lastRun: [GenJob] = []               // the latest run, in order (the panel's run list)

    func run(_ jobs: [GenJob], done: @escaping (GenJob) -> Void) {
        lastRun = jobs
        for j in jobs { failed[j.id] = nil; status[j.id] = "Waiting…"; running.insert(j.id); phase[j.id] = .queued }
        Task {
            await withTaskGroup(of: Void.self) { g in
                var started = 0
                for j in jobs {
                    if started >= 4 { await g.next() }
                    started += 1
                    g.addTask { await self.one(j, done: done) }
                }
            }
        }
    }

    private func one(_ j: GenJob, done: @escaping (GenJob) -> Void) async {
        do {
            status[j.id] = "Uploading refs (0/\(j.refs.count))"
            var urls: [String] = []
            for (i, r) in j.refs.enumerated() {
                phase[j.id] = .uploading(i, j.refs.count); status[j.id] = "Uploading refs (\(i)/\(j.refs.count))"
                guard let u = r.url else { throw KieError.message("\(r.name) is missing") }
                urls.append(try await Kie.upload(u))
            }
            phase[j.id] = .uploading(j.refs.count, j.refs.count)
            var input: [String: Any] = ["prompt": j.prompt, "aspect_ratio": "16:9", "resolution": j.res]
            if !urls.isEmpty { input["input_urls"] = urls }
            let created = try await Kie.call("https://api.kie.ai/api/v1/jobs/createTask", body: ["model": j.model, "input": input])
            guard let task = (created["data"] as? [String: Any])?["taskId"] as? String else { throw KieError.message("No task id from Kie") }
            let t0 = Date()
            phase[j.id] = .waiting(t0)
            for _ in 0..<150 {
                let e = Int(Date().timeIntervalSince(t0)); status[j.id] = String(format: "Waiting on Kie %d:%02d", e / 60, e % 60)
                try await Task.sleep(nanoseconds: 8_000_000_000)
                let q = (try await Kie.call("https://api.kie.ai/api/v1/jobs/recordInfo?taskId=\(task)"))["data"] as? [String: Any] ?? [:]
                let state = q["state"] as? String
                if state == "success" {
                    var r = q["resultJson"]
                    if let s = r as? String { r = try? JSONSerialization.jsonObject(with: Data(s.utf8)) }
                    guard let link = ((r as? [String: Any])?["resultUrls"] as? [String])?.first, let u = URL(string: link) else { throw KieError.message("No picture in Kie's answer") }
                    status[j.id] = "Downloading…"; phase[j.id] = .downloading
                    let (tmp, _) = try await URLSession.shared.download(from: u)
                    try save(tmp, j)
                    log(j, task: task, credits: q["creditsConsumed"])
                    status[j.id] = nil; running.remove(j.id); phase[j.id] = .done(Date()); done(j)
                    return
                }
                if state == "fail" { throw KieError.message((q["failMsg"] as? String) ?? "Kie said it failed") }
            }
            throw KieError.message("Timed out here; task \(task) may still finish")
        } catch {
            status[j.id] = nil; running.remove(j.id); failed[j.id] = error.localizedDescription; phase[j.id] = .failed(error.localizedDescription)
        }
    }

    /// The new picture goes in place; the old one moves to _previous/ beside it, timestamped, never deleted.
    private func save(_ tmp: URL, _ j: GenJob) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: j.out.path) {
            let prev = j.out.deletingLastPathComponent().appendingPathComponent("_previous")
            try fm.createDirectory(at: prev, withIntermediateDirectories: true)
            try fm.moveItem(at: j.out, to: prev.appendingPathComponent("\(j.out.deletingPathExtension().lastPathComponent)-\(Int(Date().timeIntervalSince1970)).png"))
        }
        try fm.moveItem(at: tmp, to: j.out)
    }
    /// The same run log atg.py writes: _data/<ID>.json beside the panels.
    private func log(_ j: GenJob, task: String, credits: Any?) {
        let dir = j.out.deletingLastPathComponent().appendingPathComponent("_data")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rec: [String: Any] = ["id": j.shot, "task": task, "model": j.model, "res": j.res, "credits": credits ?? j.credits,
                                  "refs": j.refs.compactMap { $0.url?.path }, "prompt": j.prompt]
        if let c = j.changes { rec["step"] = j.step == "bw" ? "edit-bw" : "edit-color"; rec["changes"] = c }
        if let d = try? JSONSerialization.data(withJSONObject: rec, options: [.prettyPrinted]) { try? d.write(to: dir.appendingPathComponent("\(j.shot).json")) }
    }
}

extension TrailerModel {
    /// The job for a shot's B&W or color panel, straight from prompts.json. Nil when there's no prompt for it.
    func job(_ store: Store, _ id: String, _ step: String) -> GenJob? {
        if let tile = tile(id) {
            // a flashback tile: its prompt from montage-prompts.json, saved into its own storyboard folder
            guard let p = tilePrompts[id], let text = step == "bw" ? p.bw : p.color else { return nil }
            let refs = (p.refs?[step] ?? []).map { PromptAttachment(url: URL(fileURLWithPath: $0.file), role: $0.role) }
            return GenJob(shot: id, name: tile.label, step: step, prompt: text, refs: refs,
                          out: tile.dir.appendingPathComponent(step == "bw" ? "\(id)-sketch.png" : "\(id)-painting.png"))
        }
        guard let s = trailer?.shots.first(where: { $0.id == id }), let p = prompts[id] else { return nil }
        let text = step == "bw" ? p.bw : p.color
        guard let text else { return nil }
        let refs = (p.refs?[step] ?? []).map { PromptAttachment(url: URL(fileURLWithPath: $0.file), role: $0.role) }
        let out = store.trailerPanels.appendingPathComponent(step == "bw" ? (s.keep_file ?? "\(s.id)-sketch.png") : "\(s.id)-painting.png")
        return GenJob(shot: s.id, name: s.name, step: step, prompt: text, refs: refs, out: out)
    }
    /// Color is painted from the sketch: it needs the sketch first.
    func canColor(_ id: String) -> Bool { files[id]?.sketch != nil }
}

/// Generate B&W / Generate Color (or Regenerate) next to a shot's copy buttons. They open the "Is this right?" sheet.
struct GenerateButtons: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let id: String
    var body: some View {
        let busy = tm.kie.running.contains("\(id):bw") || tm.kie.running.contains("\(id):color")
        HStack(spacing: 6) {
            if let j = tm.job(store, id, "bw") {
                Button(tm.files[id]?.sketch == nil ? "Generate B&W" : "Regenerate B&W") { tm.confirming = [j] }
                    .help("1K black-and-white from the full prompt, redrawn from scratch, 6 credits. Shows what will be sent first")
            }
            if tm.files[id]?.sketch != nil {
                Button("Edit B&W") { tm.editing = EditRequest(ids: [id], step: "bw") }
                    .help("Change only what you type; the rest of the current sketch stays. 1K, 6 credits")
            }
            if let j = tm.job(store, id, "color") {
                Button(tm.files[id]?.painting == nil ? "Generate Color" : "Regenerate Color") { tm.confirming = [j] }
                    .disabled(!tm.canColor(id))
                    .help(tm.canColor(id) ? "4K color from the sketch, 16 credits. Shows what will be sent first" : "Needs the B&W sketch first: color is painted from it")
            }
            if tm.files[id]?.painting != nil {
                Button("Edit Color") { tm.editing = EditRequest(ids: [id], step: "color") }
                    .help("Change only what you type; the rest of the current painting stays. 4K, 16 credits")
            }
        }
        .controlSize(.small).disabled(busy)
    }
}

/// The shot's run status over its picture: what it's doing, or Kie's failMsg with Retry.
struct GenStatus: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    @ObservedObject var kie: KieRunner
    let shot: String
    var body: some View {
        let ids = ["\(shot):bw", "\(shot):color"]
        if let s = ids.compactMap({ kie.status[$0] }).first {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(s).font(.system(size: 11, weight: .semibold)) }
                .padding(.horizontal, 10).padding(.vertical, 6).background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
        } else if let id = ids.first(where: { kie.failed[$0] != nil }), let msg = kie.failed[id] {
            VStack(spacing: 6) {
                Text("Failed (no credits spent): \(msg)").font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(3)
                Button("Retry…") { if let j = tm.job(store, shot, String(id.split(separator: ":")[1])) { tm.confirming = [j] } }.controlSize(.small)
            }
            .padding(8).background(Color.red2.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).padding(10)
        }
    }
}

/// "Is this right?": every shot, the exact prompt, every ref with its role, model, resolution, credits, dollars and
/// the Kie balance. Nothing is sent until OK.
struct GenConfirmSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let jobs: [GenJob]
    @State var balance: String = "checking…"
    var body: some View {
        let credits = jobs.map(\.credits).reduce(0, +)
        VStack(alignment: .leading, spacing: 12) {
            Text("Is this right?").font(.serif(26))
            Text("\(jobs.count) picture\(jobs.count == 1 ? "" : "s") · \(credits) credits · $\(String(format: "%.2f", Double(credits) * creditDollars)) · Kie balance: \(balance)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gold)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(jobs) { j in JobSummary(job: j, open: jobs.count == 1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("Runs 4 at a time. Each picture swaps in as it lands; any old one moves to _previous/.").font(.system(size: 11)).foregroundStyle(Color.soft)
                Spacer()
                Button("Cancel", role: .cancel) { tm.confirming = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    let js = jobs; tm.confirming = nil
                    tm.startRun(js, store)
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.gold)
            }
        }
        .padding(24).frame(width: 760, height: 640).background(Color.panel).foregroundStyle(Color.ink)
        .task {
            do { balance = String(format: "%.0f credits", try await Kie.balance()) } catch { balance = "unavailable (\(error.localizedDescription))" }
        }
    }
}

struct JobSummary: View {
    let job: GenJob
    @State var open: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Pill(text: job.shot, color: .gold, dark: true)
                Text(job.name).font(.system(size: 13, weight: .semibold))
                Text("· \(job.step == "bw" ? "B&W" : "Color") · \(job.res) · \(job.credits) credits ($\(String(format: "%.2f", Double(job.credits) * creditDollars)))")
                    .font(.system(size: 11)).foregroundStyle(Color.soft)
                Spacer()
                Text(job.model).font(.system(size: 10)).foregroundStyle(Color.mute)
            }
            Text("Saves as \(job.out.lastPathComponent)").font(.system(size: 10)).foregroundStyle(Color.mute)
            // every attachment, in order, wrapping onto more rows
            Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: job.refs.count, by: 5)), id: \.self) { row in
                    GridRow(alignment: .top) {
                        ForEach(Array(job.refs.enumerated()).filter { $0.offset >= row && $0.offset < row + 5 }, id: \.offset) { i, r in
                            VStack(alignment: .leading, spacing: 2) {
                                PanelImage(url: r.url, maxPixel: 300, fit: true, missing: "missing").frame(width: 124).clipShape(RoundedRectangle(cornerRadius: 4))
                                Text("Image \(i + 1)").font(.system(size: 10, weight: .bold))
                                Text(r.role).font(.system(size: 9)).foregroundStyle(Color.soft).lineLimit(4).frame(width: 124, alignment: .leading)
                            }
                        }
                    }
                }
            }
            if job.refs.isEmpty { Text("No attachments (text to image)").font(.system(size: 11)).foregroundStyle(Color.soft) }
            DisclosureGroup("The exact prompt", isExpanded: $open) {
                Text(job.prompt).font(.system(size: 11)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .padding(8).background(Color.dark, in: RoundedRectangle(cornerRadius: 6))
            }.font(.system(size: 11))
        }
        .padding(10).background(Color.card, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Shown while shots are picked (⌘-click or the card's checkbox): generate them all at once.
struct GenerateSelectedBar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    var body: some View {
        let ids = ((tm.trailer?.shots.map(\.id) ?? []) + tm.tiles.map(\.id)).filter { tm.picked.contains($0) }
        let bw = ids.compactMap { tm.job(store, $0, "bw") }
        let color = ids.filter { tm.canColor($0) }.compactMap { tm.job(store, $0, "color") }
        HStack(spacing: 12) {
            Text("\(ids.count) selected").font(.system(size: 13, weight: .semibold))
            Button("Generate B&W (\(bw.count))") { tm.confirming = bw }.disabled(bw.isEmpty)
            Button("Generate Color (\(color.count))") { tm.confirming = color }.disabled(color.isEmpty)
                .help("Only shots that already have their sketch")
            let eb = ids.filter { tm.files[$0]?.sketch != nil }, ec = ids.filter { tm.files[$0]?.painting != nil }
            Button("Edit B&W (\(eb.count))") { tm.editing = EditRequest(ids: eb, step: "bw") }.disabled(eb.isEmpty)
                .help("One set of changes on every picked sketch")
            Button("Edit Color (\(ec.count))") { tm.editing = EditRequest(ids: ec, step: "color") }.disabled(ec.isEmpty)
                .help("One set of changes on every picked painting")
            Spacer()
            Button("Clear") { tm.picked = [] }
        }
        .controlSize(.small).padding(.horizontal, 20).padding(.vertical, 10)
        .background(Color.panel).overlay(alignment: .top) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}

// MARK: - Edit: change only what you type, keep the rest of the current picture (atg.py fix_jobs)

struct EditRequest: Equatable { var ids: [String]; var step: String }

/// atg.py's FIX_TAIL, word for word, and the color edit's tail.
let editTailBW = "Everything else stays exactly as it is: the camera, the framing, every person, prop and fixture, and the black-and-white pencil sketch style. "
    + "Every person keeps hair, clothes, ears, no mouth, black mitten hands, the same rounded black shoes and no pants showing. "
    + "Strictly black, white and gray. Output 16:9."
let editTailColor = "Everything else stays exactly as it is: the camera, the framing, every person, prop and fixture, every color and the hand-drawn 2D ink-and-watercolor cartoon style. "
    + "Every person keeps hair, clothes, ears, no mouth, black mitten hands, the same rounded black shoes and no pants showing. No photorealism, no 3D. Output 16:9."

/// The edit prompt, built the way fix_jobs builds it.
func editPrompt(_ id: String, _ changes: [String], extras: [PromptAttachment], color: Bool) -> String {
    let head = extras.isEmpty ? "Same picture as the attached image, with these changes only:" : "Same picture as Image 1, with these changes only:"
    let roles = extras.isEmpty ? "" : "Image 1: the current panel \(id), the picture to edit.\n"
        + extras.enumerated().map { "Image \($0.offset + 2): \($0.element.role).\n" }.joined()
    return roles + head + "\n" + changes.map { "- " + $0 }.joined(separator: "\n") + "\n" + (color ? editTailColor : editTailBW) + "\n"
}

extension TrailerModel {
    /// An edit of a shot's current sketch (1K) or painting (4K): Image 1 is that file, then any extra images.
    func editJob(_ store: Store, _ id: String, _ step: String, changes: [String], extras: [PromptAttachment]) -> GenJob? {
        guard trailer?.shots.contains(where: { $0.id == id }) == true || tile(id) != nil,
              let current = step == "bw" ? files[id]?.sketch : files[id]?.painting else { return nil }
        let refs = [PromptAttachment(url: current, role: "the current panel \(id): the picture to edit")] + extras
        return GenJob(shot: id, name: displayName(id), step: step, prompt: editPrompt(id, changes, extras: extras, color: step == "color"),
                      refs: refs, out: current, changes: changes)
    }
}

/// The Edit sheet: your changes (one per line), optional extra images with their roles, then the same
/// "Is this right?" summary. Nothing is sent until OK.
struct EditSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let request: EditRequest
    @State var text = ""
    @State var extras: [PromptAttachment] = []
    @State var target = false
    @State var balance = "checking…"
    var changes: [String] { text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    var body: some View {
        let jobs = changes.isEmpty ? [] : request.ids.compactMap { tm.editJob(store, $0, request.step, changes: changes, extras: extras) }
        let credits = jobs.map(\.credits).reduce(0, +)
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit \(request.step == "bw" ? "B&W" : "Color"): \(request.ids.joined(separator: ", "))").font(.serif(24))
            Text("Only these changes; the rest of each current \(request.step == "bw" ? "sketch" : "painting") stays. \(request.step == "bw" ? "1K, 6" : "4K, 16") credits each.")
                .font(.system(size: 12)).foregroundStyle(Color.soft)
            Eyebrow("Changes, one per line")
            TextEditor(text: $text).font(.system(size: 12)).frame(height: 90).scrollContentBackground(.hidden).padding(4)
                .background(Color.dark, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.line))
            Eyebrow("Extra images (optional)")
            VStack(alignment: .leading, spacing: 6) {
                ForEach(extras.indices, id: \.self) { i in
                    HStack(spacing: 8) {
                        PanelImage(url: extras[i].url, maxPixel: 200, fit: true).frame(width: 80).clipShape(RoundedRectangle(cornerRadius: 4))
                        Text("Image \(i + 2)").font(.system(size: 11, weight: .bold))
                        TextField("Role, e.g. Andre's locked design: colors only", text: Binding(get: { extras[i].role }, set: { extras[i].role = $0 }))
                            .textFieldStyle(.roundedBorder).font(.system(size: 11))
                        Button(role: .destructive) { extras.remove(at: i) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }
                }
                Text("Drop reference images here").font(.system(size: 11)).foregroundStyle(Color.soft)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(target ? Color.gold : Color.line, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                    .dropDestination(for: URL.self) { urls, _ in
                        extras += urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }.map { PromptAttachment(url: $0, role: "") }
                        return true
                    } isTargeted: { target = $0 }
            }
            Divider()
            Text("Is this right? \(jobs.count) picture\(jobs.count == 1 ? "" : "s") · \(credits) credits · $\(String(format: "%.2f", Double(credits) * creditDollars)) · Kie balance: \(balance)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gold)
            ScrollView { VStack(alignment: .leading, spacing: 10) { ForEach(jobs) { JobSummary(job: $0, open: jobs.count == 1) } } }
            HStack {
                if extras.contains(where: { $0.role.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text("Give every extra image a role.").font(.system(size: 11)).foregroundStyle(Color.red2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { tm.editing = nil }.keyboardShortcut(.cancelAction)
                Button("OK") { tm.editing = nil; tm.startRun(jobs, store) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.gold)
                    .disabled(jobs.isEmpty || extras.contains { $0.role.trimmingCharacters(in: .whitespaces).isEmpty })
            }
        }
        .padding(24).frame(width: 780, height: 720).background(Color.panel).foregroundStyle(Color.ink)
        .task { do { balance = String(format: "%.0f credits", try await Kie.balance()) } catch { balance = "unavailable (\(error.localizedDescription))" } }
    }
}

// MARK: - A run's progress in the side panel

extension TrailerModel {
    /// Sends the jobs and shows them in the side panel: a single run opens its shot or tile; a bigger one shows the run list.
    func startRun(_ jobs: [GenJob], _ store: Store) {
        kie.run(jobs) { [weak self] j in
            if let k = j.stateKey { store.adoptGenerated(k, j.out) }
            self?.refreshFiles(store); store.refreshFiles()
        }
        if jobs.first?.stateKey != nil { return }      // from the Beats page: its panel shows the run
        if let first = jobs.first { selected = first.shot }
        wantsPanel += 1
    }
}

/// The run's status over the panel's picture: Uploading refs (n/m) → Waiting on Kie (m:ss, polling) → Downloading →
/// Done (the new picture is in) or Failed (Kie's failMsg, Retry).
struct RunStatusOverlay: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    @ObservedObject var kie: KieRunner
    let id: String                       // the shot or tile
    var body: some View {
        let ids = ["\(id):bw", "\(id):color"]
        if let jid = ids.first(where: { kie.phase[$0]?.isActive == true }) ?? ids.first(where: { kie.phase[$0] != nil && recent(kie.phase[$0]!) }),
           let p = kie.phase[jid] {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 8) {
                    Text(jid.hasSuffix(":bw") ? "B&W" : "Color").font(.system(size: 10, weight: .bold)).tracking(2).foregroundStyle(Color.gold)
                    line(p, now: ctx.date)
                    if case .failed = p {
                        Button("Retry…") { if let j = tm.job(store, id, String(jid.split(separator: ":")[1])) { tm.confirming = [j] } }.controlSize(.small)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(background(p), in: RoundedRectangle(cornerRadius: 10)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
    /// Done and Failed stay up for a minute after they happen (failures until retried).
    func recent(_ p: RunPhase) -> Bool { if case .done(let d) = p { return Date().timeIntervalSince(d) < 60 }; if case .failed = p { return true }; return false }
    func background(_ p: RunPhase) -> Color {
        switch p { case .failed: return Color.red2.opacity(0.9); case .done: return Color.done.opacity(0.9); default: return Color.black.opacity(0.75) }
    }
    @ViewBuilder func line(_ p: RunPhase, now: Date) -> some View {
        switch p {
        case .queued: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Queued (4 run at a time)") }.font(.system(size: 13, weight: .semibold))
        case .uploading(let n, let m): HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Uploading refs (\(n)/\(m))") }.font(.system(size: 13, weight: .semibold))
        case .waiting(let t0):
            let s = Int(now.timeIntervalSince(t0))
            VStack(spacing: 3) {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(String(format: "Waiting on Kie %d:%02d", s / 60, s % 60)).monospacedDigit() }
                    .font(.system(size: 13, weight: .semibold))
                Text("polling every 8 s").font(.system(size: 10)).opacity(0.8)
            }
        case .downloading: HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Downloading") }.font(.system(size: 13, weight: .semibold))
        case .done: Label("Done: the new picture is in", systemImage: "checkmark.circle.fill").font(.system(size: 13, weight: .semibold))
        case .failed(let msg): Text("Failed (no credits spent): \(msg)").font(.system(size: 12)).multilineTextAlignment(.center).lineLimit(4)
        }
    }
}

/// The latest run with more than one picture: every item and where it is. Click one to show it.
struct RunList: View {
    @EnvironmentObject var tm: TrailerModel
    @ObservedObject var kie: KieRunner
    var body: some View {
        if kie.lastRun.count > 1 {
            VStack(alignment: .leading, spacing: 4) {
                let left = kie.lastRun.filter { kie.phase[$0.id]?.isActive == true }.count
                Eyebrow("This run · \(kie.lastRun.count - left) of \(kie.lastRun.count) finished")
                ForEach(kie.lastRun) { j in
                    Button { tm.selected = j.shot } label: {
                        HStack(spacing: 6) {
                            Text(j.shot).font(.system(size: 11, weight: .bold)).frame(width: 52, alignment: .leading)
                            Text(j.step == "bw" ? "B&W" : "Color").font(.system(size: 10)).foregroundStyle(Color.soft).frame(width: 34, alignment: .leading)
                            Text(Self.short(kie.phase[j.id])).font(.system(size: 11)).foregroundStyle(color(kie.phase[j.id])).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 3).padding(.horizontal, 6)
                        .background(tm.selected == j.shot ? Color.gold.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(10).background(Color.card, in: RoundedRectangle(cornerRadius: 10))
        }
    }
    static func short(_ p: RunPhase?) -> String {
        switch p {
        case .queued?: return "Queued"
        case .uploading(let n, let m)?: return "Uploading refs (\(n)/\(m))"
        case .waiting(let t0)?: let s = Int(Date().timeIntervalSince(t0)); return String(format: "Waiting on Kie %d:%02d", s / 60, s % 60)
        case .downloading?: return "Downloading"
        case .done?: return "Done"
        case .failed(let m)?: return "Failed: \(m)"
        case nil: return ""
        }
    }
    func color(_ p: RunPhase?) -> Color { if case .failed? = p { return .red2 }; if case .done? = p { return .done }; return .ink }
}
