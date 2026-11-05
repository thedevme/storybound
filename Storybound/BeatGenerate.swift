import SwiftUI

// MARK: - Generate from the Beats page
// A beat's picture belongs to its scene (or shared plate), so that's what gets made: every beat in it shows the result.
// Same runner, credits and "Is this right?" sheet as the trailer buttons. Nothing is sent until OK on that sheet.

/// One picture's slots and prompts: a scene, or the shared plate a plate scene is.
struct SceneArt: Identifiable {
    let id: String              // unique across episodes: e2-S2-08, plate-T1 DAY
    let name: String
    let sketchKey: String, paintKey: String
    let sketchPrompt: String
    let sketchRefs: [PromptAttachment], paintRefs: [PromptAttachment]
    let beats: [Int]
    let scenes: Int?            // a shared plate: how many scenes sit on it
}

extension Store {
    /// Craig's exact colorize prompt, sent word for word, the same one the trailer's color buttons use.
    static let colorMaster: String? = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/skills/against-the-grain/colorize-master-exact.txt"), encoding: .utf8)

    /// Why this beat has nothing to generate, or nil when it has.
    func noGenerateReason(_ e: Episode, _ b: Beat) -> String? {
        guard let s = storyboard(e, b) else { return "This beat has no storyboard prompt, so there's nothing to generate." }
        if s.isEdit { return "This scene is an edit of an existing picture, not a new drawing. Its prompt is below." }
        if s.type == "plate", let pk = s.plateKey, plates.first(where: { $0.id == pk })?.storyboardPrompt == nil { return "The \(pk) plate has no prompt yet, so there's nothing to generate." }
        return nil
    }
    /// What generating these beats would send: beats in one scene share a picture; a beat with no storyboard prompt makes its own.
    func pickedJobs(_ e: Episode, _ picked: [Beat]) -> (pictures: Int, bw: [GenJob], color: [GenJob]) {
        var seen = Set<String>(), pictures = 0, bw: [GenJob] = [], color: [GenJob] = []
        for b in picked {
            if let a = sceneArt(e, b) {
                guard seen.insert(a.id).inserted else { continue }
                pictures += 1; bw.append(bwJob(a)); if let c = colorJob(a) { color.append(c) }
            } else {
                pictures += 1; bw.append(ownBWJob(e, b, prompt: ownPrompt(e, b), refs: ownRefs(e, b)))
                if let c = ownColorJob(e, b) { color.append(c) }
            }
        }
        return (pictures, bw, color)
    }
    func sceneArt(_ e: Episode, _ b: Beat) -> SceneArt? {
        guard noGenerateReason(e, b) == nil, let s = storyboard(e, b) else { return nil }
        if s.type == "plate", let pk = s.plateKey, let p = plates.first(where: { $0.id == pk }), let prompt = p.storyboardPrompt {
            let refs = plateAttachments(p)
            return SceneArt(id: "plate-\(pk)", name: "Shared plate · \(p.name)", sketchKey: "plate:\(pk)", paintKey: "plate-paint:\(pk)",
                            sketchPrompt: prompt, sketchRefs: refs.sketch, paintRefs: refs.paint, beats: s.beats, scenes: p.scenes)
        }
        let refs = sceneAttachments(e, s)
        return SceneArt(id: "e\(e.n)-\(s.id)", name: s.name, sketchKey: sceneSketchKey(e, s), paintKey: sceneKey(e, s),
                        sketchPrompt: s.prompt, sketchRefs: refs.sketch, paintRefs: refs.paint, beats: s.beats, scenes: nil)
    }
    func generatedFile(_ key: String) -> URL { userDir.appendingPathComponent(key.replacingOccurrences(of: ":", with: "_") + "-kie.png") }
    func bwJob(_ a: SceneArt) -> GenJob {
        GenJob(shot: a.id, name: a.name, step: "bw", prompt: a.sketchPrompt, refs: a.sketchRefs, out: generatedFile(a.sketchKey), stateKey: a.sketchKey)
    }
    /// Color is painted from the sketch: nil until the sketch is in.
    func colorJob(_ a: SceneArt) -> GenJob? {
        guard hasImage(a.sketchKey), let master = Store.colorMaster else { return nil }
        return GenJob(shot: a.id, name: a.name, step: "color", prompt: master, refs: a.paintRefs, out: generatedFile(a.paintKey), stateKey: a.paintKey)
    }
    // A beat with no storyboard prompt makes its own picture: a sketch slot, and its "this beat only" slot for the painting.
    func ownSketchKey(_ e: Episode, _ b: Beat) -> String { "beat-sketch:\(keyBeat(e, b))" }
    /// What a beat's run is called: its scene's, or its own.
    func genID(_ e: Episode, _ b: Beat) -> String { sceneArt(e, b)?.id ?? "e\(e.n)-b\(b.n)" }
    /// The prompt you last sent for this beat, or the style lock plus the beat's notes.
    func ownPrompt(_ e: Episode, _ b: Beat) -> String {
        let saved = prompt(ownSketchKey(e, b))
        if !saved.isEmpty { return saved }
        return (sketchStyle + "\n\nThe picture: \(b.what)\nThe narration over it: \(b.text)").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The locked design of anyone named in the beat. The sheet can take these off or add more.
    func ownRefs(_ e: Episode, _ b: Beat) -> [PromptAttachment] {
        let words = (b.text + " " + b.what).lowercased()
        return (season?.cast ?? []).compactMap { p in
            guard let last = p.name.split(separator: " ").last, words.contains(last.lowercased()),
                  let folder = designFolder(p.name), let u = lockedDesign(folder) else { return nil }
            return PromptAttachment(url: u, role: "\(p.name)'s locked design: face, hair, clothes and build")
        }
    }
    func ownBWJob(_ e: Episode, _ b: Beat, prompt: String, refs: [PromptAttachment]) -> GenJob {
        let roles = refs.enumerated().map { "Image \($0.offset + 1): \($0.element.role)\n" }.joined()
        let key = ownSketchKey(e, b)
        return GenJob(shot: "e\(e.n)-b\(b.n)", name: "Beat \(b.n)", step: "bw", prompt: roles + prompt, refs: refs, out: generatedFile(key), stateKey: key)
    }
    /// Color for a beat's own sketch, with the same exact prompt as everything else in this show.
    func ownColorJob(_ e: Episode, _ b: Beat) -> GenJob? {
        let key = ownSketchKey(e, b)
        guard hasTrailer, hasImage(key), let master = Store.colorMaster else { return nil }
        return GenJob(shot: "e\(e.n)-b\(b.n)", name: "Beat \(b.n)", step: "color", prompt: master,
                      refs: [PromptAttachment(url: userFile(key), role: "the approved pencil sketch of beat \(b.n)")], out: generatedFile(keyBeat(e, b)), stateKey: keyBeat(e, b))
    }
    /// Puts a finished picture in its slot. A picture already there moves to user/_previous, never deleted.
    func adoptGenerated(_ key: String, _ file: URL) {
        guard file.deletingLastPathComponent().standardizedFileURL == userDir.standardizedFileURL else {
            say("A picture finished for another project. It's saved in that project's folder as \(file.lastPathComponent)."); return
        }
        let fm = FileManager.default
        if let old = state.images[key], old != file.lastPathComponent {
            let prev = userDir.appendingPathComponent("_previous")
            try? fm.createDirectory(at: prev, withIntermediateDirectories: true)
            try? fm.moveItem(at: userDir.appendingPathComponent(old), to: prev.appendingPathComponent(old))
        }
        state.images[key] = file.lastPathComponent
        // a new picture for one beat starts whole: the framing it had was for the old picture
        // (a sketch behind a finished picture isn't showing yet, so that picture keeps its framing)
        if key.hasPrefix("beat-sketch:") {
            let beat = String(key.dropFirst("beat-sketch:".count))
            if !hasImage(beat) { state.frames?[beat] = nil }
        } else { state.frames?[key] = nil }
        imageCache[key] = nil; imageCache["card:" + key] = nil
        save(); imageVersion += 1; say("New picture is in")
    }
}

/// Generate B&W / Generate Color on the Artwork tab, with what they'll make.
struct BeatGenerateButtons: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let e: Episode; let b: Beat
    var body: some View {
        let art = store.sceneArt(e, b)
        VStack(alignment: .leading, spacing: 6) {
            BeatCardGenerate(e: e, b: b, long: true)
            Text(art.map { a in a.scenes.map { "Replaces the shared plate used by \($0) scenes." } ?? "Makes one picture for \(a.beats.count == 1 ? "this beat" : "all \(a.beats.count) beats in this scene")." }
                 ?? "Makes a picture for this beat only. You check its prompt first.")
                .font(.system(size: 11)).foregroundStyle(Color.benchSoft).fixedSize(horizontal: false, vertical: true)
            SceneRunStatus(kie: tm.kie, e: e, b: b, id: store.genID(e, b))
            // a new sketch doesn't take over from a finished picture, so it shows here for checking
            if art == nil, store.hasImage(store.keyBeat(e, b)), let sketch = store.userFile(store.ownSketchKey(e, b)) {
                PanelImage(url: sketch, maxPixel: 800, fit: true, version: store.imageVersion).clipShape(RoundedRectangle(cornerRadius: 6))
                Text("New sketch. The finished picture stays on this beat until you generate color.")
                    .font(.system(size: 11)).foregroundStyle(Color.benchSoft).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct BusyWhileRunning: ViewModifier {
    @ObservedObject var kie: KieRunner
    let id: String
    func body(content: Content) -> some View { content.disabled(kie.running.contains("\(id):bw") || kie.running.contains("\(id):color")) }
}

/// What the run is doing, or Kie's message with Retry.
struct SceneRunStatus: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    @ObservedObject var kie: KieRunner
    let e: Episode; let b: Beat; let id: String
    var body: some View {
        let ids = ["\(id):bw", "\(id):color"]
        if let s = ids.compactMap({ kie.status[$0] }).first {
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(s).font(.system(size: 11, weight: .semibold)) }
        } else if let jid = ids.first(where: { kie.failed[$0] != nil }), let msg = kie.failed[jid] {
            VStack(alignment: .leading, spacing: 4) {
                Text("Failed: \(msg)").font(.system(size: 11)).foregroundStyle(Color.red2).fixedSize(horizontal: false, vertical: true)
                Button("Retry…") {
                    let bw = jid.hasSuffix(":bw")
                    if let a = store.sceneArt(e, b) { tm.confirming = bw ? [store.bwJob(a)] : store.colorJob(a).map { [$0] } }
                    else if bw { tm.beatPrompt = b.n } else { tm.confirming = store.ownColorJob(e, b).map { [$0] } }
                }.controlSize(.small)
            }
        }
    }
}

/// The small run note over a beat card's picture.
struct SceneRunBadge: View {
    @ObservedObject var kie: KieRunner
    let id: String
    var body: some View {
        if let s = ["\(id):bw", "\(id):color"].compactMap({ kie.status[$0] }).first {
            HStack(spacing: 6) { ProgressView().controlSize(.mini); Text(s).font(.system(size: 10, weight: .semibold)).lineLimit(1) }
                .padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
        }
    }
}

/// The tick on a beat card or row, for generating several at once. Every beat has one. A beat with no storyboard prompt
/// goes with its own prompt, and the confirm sheet shows what will be sent before anything runs.
struct BeatPickBox: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let e: Episode; let b: Beat
    var body: some View {
        let on = tm.beatPicks.contains(b.n)
        Button { if on { tm.beatPicks.remove(b.n) } else { tm.beatPicks.insert(b.n) } } label: {
            Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 13))
                .foregroundStyle(on ? Color.benchBlue : Color.benchSoft)
        }.buttonStyle(.plain).help("Pick this beat to generate it with others")
    }
}

/// Shown while beats are ticked. Beats in the same scene make one picture, so it counts both.
struct BeatGenerateBar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let e: Episode
    var body: some View {
        let picked = e.beats.filter { tm.beatPicks.contains($0.n) }
        let (pictures, bw, color) = store.pickedJobs(e, picked)
        HStack(spacing: 12) {
            Text("\(picked.count) beat\(picked.count == 1 ? "" : "s") · \(pictures) picture\(pictures == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
            Button("Generate B&W (\(bw.count))") { tm.confirming = bw }.disabled(bw.isEmpty)
            Button("Generate Color (\(color.count))") { tm.confirming = color }.disabled(color.isEmpty)
                .help("Only scenes that already have their sketch")
            Spacer()
            Button("Clear") { tm.beatPicks = [] }
        }
        .controlSize(.small).padding(.horizontal, 18).padding(.vertical, 10)
        .background(Color.benchCard).overlay(alignment: .top) { Rectangle().fill(Color.benchLine).frame(height: 1) }
    }
}

/// The two buttons on every beat's card and row and on the Artwork tab. A beat in a planned scene makes the scene's
/// picture from its storyboard prompt. Any other beat makes its own picture from a prompt you check first.
struct BeatCardGenerate: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let e: Episode; let b: Beat
    var long = false
    var body: some View {
        let art = store.sceneArt(e, b)
        let hasSketch = store.hasImage(art?.sketchKey ?? store.ownSketchKey(e, b))
        let hasPaint = store.hasImage(art?.paintKey ?? store.keyBeat(e, b))
        let color = art.flatMap { store.colorJob($0) } ?? (art == nil ? store.ownColorJob(e, b) : nil)
        let redo = long ? "Regenerate" : "Redo"
        HStack(spacing: 6) {
            Button("\(hasSketch ? redo : "Generate") B&W") {
                if let art { tm.confirming = [store.bwJob(art)] } else { tm.beatPrompt = b.n }
            }.help(art == nil ? "1K black-and-white for this beat only, 6 credits. You check the prompt first" : "1K black-and-white for every beat in this scene, 6 credits. Shows what will be sent first")
            Button("\(hasPaint ? redo : "Generate") Color") { tm.confirming = color.map { [$0] } }
                .disabled(color == nil)
                .help(color == nil ? "Needs a B&W sketch from these buttons first: color is painted from it" : "4K color, 16 credits. Shows what will be sent first")
        }
        .controlSize(.small).lineLimit(1)
        .modifier(BusyWhileRunning(kie: tm.kie, id: art?.id ?? store.genID(e, b)))
    }
}

/// A beat with no storyboard prompt: the prompt to check or write, its images, and the cost. Nothing is sent until OK.
struct BeatPromptSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    let e: Episode; let b: Beat
    @State var text = ""
    @State var refs: [PromptAttachment] = []
    @State var balance = "checking…"
    @State var target = false
    var body: some View {
        let blankRole = refs.contains { $0.role.trimmingCharacters(in: .whitespaces).isEmpty }
        VStack(alignment: .leading, spacing: 12) {
            Text("Beat \(String(format: "%02d", b.n)) · Generate B&W").font(.serif(26))
            Text(b.text).font(.system(size: 13)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
            Eyebrow("The prompt: style lock, then this beat's notes. Change anything")
            TextEditor(text: $text).font(.system(size: 12)).scrollContentBackground(.hidden).padding(6)
                .background(Color.dark, in: RoundedRectangle(cornerRadius: 6)).frame(maxHeight: .infinity)
            Eyebrow("Images to attach. Each role is sent as a line above the prompt")
            ForEach(refs.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    PanelImage(url: refs[i].url, maxPixel: 200, fit: true).frame(width: 64).clipShape(RoundedRectangle(cornerRadius: 4))
                    Text("Image \(i + 1)").font(.system(size: 11, weight: .bold))
                    TextField("What this image is for", text: Binding(get: { refs[i].role }, set: { refs[i].role = $0 })).textFieldStyle(.roundedBorder).font(.system(size: 11))
                    Button(role: .destructive) { refs.remove(at: i) } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            Text("Drop reference images here").font(.system(size: 11)).foregroundStyle(Color.soft)
                .frame(maxWidth: .infinity, minHeight: 34)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(target ? Color.gold : Color.line, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
                .dropDestination(for: URL.self) { urls, _ in refs += urls.map { PromptAttachment(url: $0, role: "") }; return true } isTargeted: { target = $0 }
            Divider()
            Text("Is this right? 1 picture · 1K · 6 credits · $\(String(format: "%.2f", 6 * creditDollars)) · Kie balance: \(balance)")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.gold)
            HStack {
                Text(blankRole ? "Give every image a role." : "This beat only. Other beats and any shared picture stay as they are.").font(.system(size: 11)).foregroundStyle(blankRole ? Color.red2 : Color.soft)
                Spacer()
                Button("Cancel", role: .cancel) { tm.beatPrompt = nil }.keyboardShortcut(.cancelAction)
                Button("OK") {
                    store.setPrompt(store.ownSketchKey(e, b), text)
                    let job = store.ownBWJob(e, b, prompt: text, refs: refs)
                    tm.beatPrompt = nil; tm.startRun([job], store)
                }.buttonStyle(.borderedProminent).tint(.gold)
                    .disabled(blankRole || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24).frame(width: 760, height: 680).background(Color.panel).foregroundStyle(Color.ink)
        .onAppear { text = store.ownPrompt(e, b); refs = store.ownRefs(e, b) }
        .task { do { balance = String(format: "%.0f credits", try await Kie.balance()) } catch { balance = "unavailable (\(error.localizedDescription))" } }
    }
}
