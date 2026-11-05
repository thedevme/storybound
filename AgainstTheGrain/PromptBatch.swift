import SwiftUI

/// The prompts still to run, as one JSON list to paste into Claude or feed a GPT image script.
/// Still to run: a painted scene or episode plate with no picture of its own, and a shared plate whose slot is empty.
/// Pose drops are left out: they're a plate with a pose placed on it, not a new picture.
extension Store {
    enum PromptKind: String { case sketch, painting }

    struct PromptItem: Encodable {
        var id: String; var episode: Int?; var name: String; var kind: String
        var beats: [Int]; var file: String; var size: String; var prompt: String
        var attach: [String]? = nil  // files to send with the prompt: the approved sketch (paintings), the location picture, or the picture an edit starts from
        var folder = ""             // the episode's folder: ART/Hand Drawn Storyboards/ep02-the-listing (sketches) or ART/Painted Scenes/… (paintings)
        var path = ""               // folder + file: where to save it
    }

    /// Where an episode's images are saved: sketches in ART/Hand Drawn Storyboards/ep02-the-listing, paintings in
    /// ART/Painted Scenes/ep02-the-listing. A shared plate goes with the first episode that needs it.
    func episodeFolder(_ n: Int, _ kind: PromptKind) -> String {
        let title = season?.eps.first { $0.n == n }?.title ?? ""
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let art = dataDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ART")
        return art.appendingPathComponent(kind == .sketch ? "Hand Drawn Storyboards" : "Painted Scenes")
            .appendingPathComponent(String(format: "ep%02d-", n) + slug).path
    }

    /// The sketch a painting is made from, as a file path, or a note that there isn't one yet.
    func sketchFile(_ key: String) -> String {
        state.images[key].map { userDir.appendingPathComponent($0).path } ?? "NO SKETCH YET: make and drop the sketch first"
    }

    func remainingPrompts(_ eps: [Episode], _ kind: PromptKind) -> [PromptItem] {
        var items: [PromptItem] = [], platesNeeded: [String] = [], plateEp: [String: Int] = [:]
        for e in eps {
            for s in (storyboards[e.n] ?? []).sorted(by: { ($0.beats.first ?? 0) < ($1.beats.first ?? 0) }) where !s.isPoseDrop {
                // a plate scene on a shared plate is the shared plate itself
                if s.type == "plate", let pk = s.plateKey {
                    if !platesNeeded.contains(pk) { platesNeeded.append(pk); plateEp[pk] = e.n }
                    continue
                }
                if kind == .sketch && s.isEdit { continue }   // an edit starts from its picture, not a sketch
                if hasImage(sceneKey(e, s)) || (kind == .sketch && hasImage(sceneSketchKey(e, s))) || s.beats.contains(where: { n in e.beats.first { $0.n == n }.map { hasImage(keyBeat(e, $0)) } ?? false }) { continue }
                let prompt = kind == .sketch ? s.prompt : (s.paintPrompt ?? paintStyle + "\n\nWide shot, 16:9. " + s.wide)
                items.append(PromptItem(id: s.id, episode: e.n, name: s.name, kind: s.type == "plate" ? "episode plate" : "painted scene", beats: s.beats,
                                        file: "\(s.id)-\(kind.rawValue).png", size: "1536x1024", prompt: prompt,
                                        attach: kind == .sketch ? s.ref.map { [$0] }
                                            : s.isEdit ? [s.ref ?? ""] : [sketchFile(sceneSketchKey(e, s))] + (s.ref.map { [$0] } ?? [])))
                // the scene paints its characters onto a shared plate: that plate is needed too
                if let pk = s.plateKey, !platesNeeded.contains(pk) { platesNeeded.append(pk); plateEp[pk] = e.n }
            }
            // pose drops need their plate as well
            for s in storyboards[e.n] ?? [] where s.isPoseDrop {
                if let pk = s.plateKey, !platesNeeded.contains(pk) { platesNeeded.append(pk); plateEp[pk] = e.n }
            }
        }
        let slot = kind == .sketch ? "plate:" : "plate-paint:"
        let plateItems = platesNeeded.compactMap { id -> PromptItem? in
            guard let p = plates.first(where: { $0.id == id }), !hasImage(slot + id),
                  let prompt = kind == .sketch ? p.storyboardPrompt : p.paintingPrompt else { return nil }
            return PromptItem(id: "PLATE \(id)", episode: plateEp[id], name: p.name, kind: "shared plate", beats: [],
                              file: id.replacingOccurrences(of: " ", with: "-") + "-\(kind.rawValue).png", size: "1536x1024", prompt: prompt,
                              attach: kind == .painting ? [sketchFile("plate:\(id)")] : nil)
        }
        return (plateItems + items).map { item in
            var it = item
            if let n = it.episode { it.folder = episodeFolder(n, kind); it.path = it.folder + "/" + it.file }
            return it
        }
    }

    func promptBatchText(_ eps: [Episode], _ kind: PromptKind) -> String {
        let items = remainingPrompts(eps, kind)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        let json = (try? enc.encode(items)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let what = kind == .sketch ? "pencil storyboard" : "ink-and-watercolor painting"
        return """
        \(projectName): \(items.count) \(what) prompts still to make (\(eps.count == 1 ? "Episode \(eps[0].n)" : "Episodes \(eps.map(\.n).min() ?? 0) to \(eps.map(\.n).max() ?? 0)")).
        Make one image per item with the GPT image API: use "prompt" exactly as written, at "size", and send every file in "attach" with it (the location picture to draw from), and save it at "path" (the episode's folder plus "file"). Create the folder if it doesn't exist. Shared plates are saved with the first episode that needs them.\(kind == .painting ? "\nEach painting is an edit of the first file in \"attach\" (its approved sketch, or for an Ep 1 edit the picture it starts from): send every file in \"attach\" as an input image, the first one first. Skip any item whose attach says NO SKETCH YET." : "")
        Shared plates come first: they're empty backgrounds that many scenes reuse.

        \(json)
        """
    }
}

/// One kind of prompt in the Prompts box: how many are left, and a Copy button for all of them.
struct PromptCopyRow: View {
    @EnvironmentObject var store: Store
    let eps: [Episode]; let kind: Store.PromptKind; let label: String; let count: Int
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 13, weight: .semibold))
            Text(count == 0 ? "all in" : "\(count) left").font(.system(size: 12)).foregroundStyle(count == 0 ? Color.done : Color.soft)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.promptBatchText(eps, kind), forType: .string)
                store.say("\(count) \(kind == .sketch ? "sketch" : "painting") prompts copied")
            } label: { Label("Copy", systemImage: "doc.on.doc") }
            .buttonStyle(.bordered).disabled(count == 0)
        }
    }
}

/// A Copy menu for every prompt still to run in these episodes.
struct PromptBatchMenu: View {
    @EnvironmentObject var store: Store
    let eps: [Episode]
    var body: some View {
        let _ = store.imageVersion
        let sketch = store.remainingPrompts(eps, .sketch).count, paint = store.remainingPrompts(eps, .painting).count
        Menu {
            Button("Storyboard (pencil) prompts · \(sketch)") { copy(.sketch, sketch) }.disabled(sketch == 0)
            Button("Painting (watercolor) prompts · \(paint)") { copy(.painting, paint) }.disabled(paint == 0)
        } label: { Label("Copy prompts", systemImage: "doc.on.doc") }
        .fixedSize()
        .help("Copies every prompt that doesn't have a picture yet as one list, ready to paste into Claude for a GPT image batch")
    }
    func copy(_ kind: Store.PromptKind, _ n: Int) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.promptBatchText(eps, kind), forType: .string)
        store.say("\(n) prompts copied")
    }
}

// MARK: - Every picture an episode needs, with where it goes

extension Store {
    /// One picture to make: a shared plate (sketch and painting slots) or a scene (one slot for the whole scene).
    struct PictureSlot: Identifiable {
        var id: String            // "T3 DAY" or "S2-08"
        var episode: Int?
        var name: String
        var isPlate: Bool
        var beats: [Int]
        var sketchPrompt: String
        var paintPrompt: String
        var key: String           // the painting slot
        var sketchKey: String     // the pencil sketch slot
        var isEdit = false        // Ep 1 edits start from an existing picture, so they have no sketch
        var sketchRefs: [PromptAttachment] = []   // the images each prompt needs, in order
        var paintRefs: [PromptAttachment] = []
    }

    /// The plates and painted scenes these episodes need, plates first. Pose drops need only their plate.
    func pictureSlots(_ eps: [Episode]) -> [PictureSlot] {
        var plateIDs: [String] = [], scenes: [PictureSlot] = []
        for e in eps {
            for s in (storyboards[e.n] ?? []).sorted(by: { ($0.beats.first ?? 0) < ($1.beats.first ?? 0) }) {
                if let pk = s.plateKey, !plateIDs.contains(pk) { plateIDs.append(pk) }
                if s.isPoseDrop || (s.type == "plate" && s.plateKey != nil) { continue }
                let refs = sceneAttachments(e, s)
                scenes.append(PictureSlot(id: s.id, episode: e.n, name: s.name, isPlate: false, beats: s.beats, sketchPrompt: s.prompt,
                                          paintPrompt: s.paintPrompt ?? paintStyle + "\n\nWide shot, 16:9. " + s.wide, key: sceneKey(e, s), sketchKey: sceneSketchKey(e, s), isEdit: s.isEdit,
                                          sketchRefs: refs.sketch, paintRefs: refs.paint))
            }
        }
        let plateSlots = plateIDs.compactMap { id -> PictureSlot? in
            guard let p = plates.first(where: { $0.id == id }) else { return nil }
            let refs = plateAttachments(p)
            return PictureSlot(id: id, episode: nil, name: p.name, isPlate: true, beats: [], sketchPrompt: p.storyboardPrompt ?? "",
                               paintPrompt: p.paintingPrompt ?? "", key: "plate-paint:\(id)", sketchKey: "plate:\(id)", sketchRefs: refs.sketch, paintRefs: refs.paint)
        }
        return plateSlots + scenes
    }

    /// Puts dropped files where their names say: "S2-08-painting.png" on scene S2-08, "T3-DAY-sketch.png" in the T3 DAY
    /// plate's sketch slot (anything else on a plate goes in its painting slot). Returns what went where and what didn't match.
    func place(_ urls: [URL], in eps: [Episode]) -> (placed: [String], unmatched: [String]) {
        let slots = pictureSlots(eps)
        let norm = { (s: String) in " " + s.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ") + " " }
        var placed: [String] = [], unmatched: [String] = []
        for url in urls {
            let name = norm(url.deletingPathExtension().lastPathComponent)
            // the longest matching id wins, so "T1 NIGHT COOLED" beats "T1 NIGHT"
            guard let slot = slots.filter({ name.contains(norm($0.id)) }).max(by: { $0.id.count < $1.id.count }) else {
                unmatched.append(url.lastPathComponent); continue
            }
            let sketch = name.contains(" SKETCH ") || name.contains(" STORYBOARD ") || name.contains(" PENCIL ")
            setImage(sketch ? slot.sketchKey : slot.key, from: url)
            placed.append("\(url.lastPathComponent) → \(slot.id) \(sketch ? "sketch" : "painting")")
        }
        return (placed, unmatched)
    }
}

/// On an episode page: one drop zone for a whole batch from ChatGPT, always open, then every plate and scene the
/// episode needs (folded until you open it), each with a Sketch and a Painting slot.
struct EpisodePictures: View {
    @EnvironmentObject var store: Store
    let e: Episode
    @State var open = false
    @State var target = false
    @State var report: (placed: [String], unmatched: [String])? = nil
    var body: some View {
        let _ = store.imageVersion
        let slots = store.pictureSlots([e])
        let painted = slots.filter { store.hasImage($0.key) }.count, sketched = slots.filter { store.hasImage($0.sketchKey) }.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("This episode's pictures").font(.serif(20))
                Text("\(slots.count) · \(sketched) sketched · \(painted) painted").font(.system(size: 12)).foregroundStyle(Color.soft)
                Spacer()
            }
            // the batch drop, always showing: many files at once, placed by their names
            HStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 22)).foregroundStyle(target ? Color.gold : Color.soft)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drop all the pictures ChatGPT made here").font(.system(size: 13, weight: .semibold))
                    Text("Files named like the copied list (S2-08-painting.png, T3-DAY-sketch.png) go straight to their slot. Anything else, open the list below and drop it on its slot.")
                        .font(.system(size: 11)).foregroundStyle(Color.soft)
                }
                Spacer()
            }
            .padding(14).frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(target ? Color.gold.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(target ? Color.gold : Color.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .dropDestination(for: URL.self) { urls, _ in report = store.place(urls, in: [e]); open = true; return true } isTargeted: { target = $0 }
            if let r = report {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(r.placed, id: \.self) { Text("✓ " + $0).font(.system(size: 11)) }
                    ForEach(r.unmatched, id: \.self) { Text("? \($0): no ID in its name. Drop it on its slot below.").font(.system(size: 11)).foregroundStyle(Color.gpt) }
                }
            }
            DisclosureGroup(isExpanded: $open) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: 14)], spacing: 14) {
                    ForEach(slots) { s in SlotCard(s: s) }
                }.padding(.top, 10)
            } label: {
                Text(open ? "Hide the plates and scenes" : "Show all \(slots.count) plates and scenes (\(slots.filter(\.isPlate).count) plates, \(slots.filter { !$0.isPlate }.count) scenes)")
                    .font(.system(size: 13, weight: .semibold))
                    .contentShape(Rectangle()).onTapGesture { withAnimation { open.toggle() } }
            }
        }
        .padding(16).background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
        .frame(maxWidth: 1100, alignment: .leading)
    }
}

/// One plate or scene: its id, name and beats, then Sketch and Painting side by side. Every slot has the same
/// buttons in the same place under its picture: copy its prompt, and remove what's in it.
struct SlotCard: View {
    @EnvironmentObject var store: Store
    let s: Store.PictureSlot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(s.isPlate ? "PLATE \(s.id)" : s.id).font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((s.isPlate ? Color.plate : Color.gold).opacity(0.18), in: Capsule())
                    .foregroundStyle(s.isPlate ? Color.plate : Color.gold)
                Text(s.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(s.isPlate ? "Shared plate" : "Beats \(s.beats.map(String.init).joined(separator: ", "))")
                    .font(.system(size: 11)).foregroundStyle(Color.soft).lineLimit(1)
            }
            HStack(alignment: .top, spacing: 10) {
                if s.isEdit {
                    VStack(alignment: .leading, spacing: 6) {
                        header("Sketch", key: nil, shown: false)
                        ZStack {
                            RoundedRectangle(cornerRadius: 10).fill(Color.bg.opacity(0.6))
                            Text("No sketch: this one edits an existing picture.\nIts painting prompt says which.")
                                .font(.system(size: 11)).foregroundStyle(Color.soft).multilineTextAlignment(.center).padding(10)
                        }.aspectRatio(16 / 9, contentMode: .fit)
                    }.frame(maxWidth: .infinity)
                } else {
                    slot("Sketch", key: s.sketchKey, prompt: s.sketchPrompt, shown: !store.hasImage(s.key) && store.hasImage(s.sketchKey), refs: s.sketchRefs)
                }
                slot("Painting", key: s.key, prompt: s.paintPrompt, shown: store.hasImage(s.key), refs: s.paintRefs)
            }
        }
        .padding(12).background(Color.bg.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    func header(_ title: String, key: String?, shown: Bool) -> some View {
        HStack(spacing: 6) {
            Eyebrow(title)
            if shown { Text("IN THE BEATS").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.gold) }
            Spacer()
            if let key, store.hasImage(key) { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.done).font(.system(size: 12)) }
        }
    }

    func slot(_ title: String, key: String, prompt: String, shown: Bool, refs: [PromptAttachment]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header(title, key: key, shown: shown)
            TruckImage(key: key, fallback: nil, label: "the \(title.lowercased())", aspect: 16 / 9)
            HStack(spacing: 6) {
                CopyButton(text: prompt, title: "Copy prompt")
                Spacer()
                Button(role: .destructive) { store.removeImage(key) } label: { Label("Remove", systemImage: "trash") }
                    .labelStyle(.iconOnly).help("Remove this \(title.lowercased())")
                    .opacity(store.hasImage(key) ? 1 : 0).disabled(!store.hasImage(key))
            }.buttonStyle(.bordered).controlSize(.small)
            AttachmentList(groups: [("Attachments", refs)])
        }.frame(maxWidth: .infinity)
    }
}
