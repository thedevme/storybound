import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared pieces for the list screens

fileprivate extension View {
    /// Card surface used by the characters, food and truck grids.
    func listCard() -> some View {
        self.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))
    }
}

/// Safe read of one cell of a truck "view" row.
fileprivate func truckCell(_ row: [String], _ i: Int) -> String { i < row.count ? row[i] : "" }

// MARK: - Heat strip

/// Ten cells, one per episode. Brighter gold means the thing shows up more in that episode.
struct HeatStrip: View {
    let h: [Int]
    var body: some View {
        let top = max(1, h.max() ?? 0)
        HStack(spacing: 3) {
            ForEach(0..<10, id: \.self) { i in
                let v = i < h.count ? h[i] : 0
                Text("\(i + 1)").font(.system(size: 10))
                    .frame(maxWidth: .infinity).frame(height: 22)
                    .background(v > 0 ? Color.gold.opacity(0.25 + 0.75 * Double(v) / Double(top)) : Color(hex: 0x2a2520),
                                in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(v > 0 ? Color.dark : Color(hex: 0x5a5046))
                    .help("Ep \(i + 1): \(v)")
            }
        }
    }
}

// MARK: - Characters

fileprivate struct CastStatusFilter: Identifiable {
    let label: String
    let status: String?
    var id: String { label }
}

fileprivate func castStatus(_ s: String) -> (text: String, color: Color) {
    switch s {
    case "Make": return ("Create this", Color.gpt)
    case "Locked": return ("Design exists", Color.done)
    case "None": return ("Not drawn", Color.plate)
    default: return (s, Color.mute)
    }
}

struct CastView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    @State var filter: String? = nil
    @State var adding = false

    var body: some View {
        let filters = [
            CastStatusFilter(label: "All", status: nil),
            CastStatusFilter(label: "Create these", status: "Make"),
            CastStatusFilter(label: "Design exists", status: "Locked"),
            CastStatusFilter(label: "Not drawn", status: "None"),
        ]
        let shown = season.cast.filter { filter == nil || $0.status == filter }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Orange means a new design to create. Green means the design already exists. Gray means never drawn. The strip shows how often each one comes up in each episode's narration.")
                    .foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 16)], spacing: 16) {
                    ForEach(shown) { p in
                        let st = castStatus(p.status)
                        VStack(alignment: .leading, spacing: 8) {
                            // the pencil sketch first, then the watercolor made from it
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Eyebrow("Sketch")
                                    TruckImage(key: "cast-sketch:\(p.name)", fallback: nil, label: "the sketch", aspect: 16 / 9)
                                    CopyButton(text: sketchPrompt(p), title: "Copy sketch prompt")
                                    AttachmentList(groups: [("Attachments", sketchRefs(p))])
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Eyebrow("Watercolor")
                                    TruckImage(key: "cast:\(p.name)", fallback: art(p), label: "the watercolor", aspect: 16 / 9)
                                    CopyButton(text: paintPrompt(p), title: "Copy watercolor prompt")
                                    AttachmentList(groups: [("Attachments", paintRefs(p))])
                                }
                            }
                            .padding(.bottom, 4)
                            Text(p.name).font(.serif(20))
                            Text(p.eps).font(.system(size: 12)).foregroundStyle(Color.soft)
                            HStack(spacing: 6) {
                                Pill(text: st.text, color: st.color)
                                Text(turnaround(p) ? "Front, side and back" : "Front view").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.soft)
                            }
                            Text(p.look).font(.system(size: 13))
                            if !p.heat.isEmpty { HeatStrip(h: p.heat).padding(.top, 4) }
                        }.listCard()
                    }
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .navigationTitle("Characters")
        .navigationSubtitle("\(shown.count) of \(season.cast.count)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $filter) {
                    ForEach(filters) { f in Text(f.label).tag(f.status) }
                }.pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add character", systemImage: "plus") }.help("Add a character to this project")
            }
        }
        .sheet(isPresented: $adding) { AddLibrarySheet(dish: false) }
    }
}

extension CastView {
    /// The main crew are seen from behind and side-on at their stations, so they get a turnaround: front, side and back.
    /// Everyone else is mostly seen facing us: front view only.
    func turnaround(_ p: Person) -> Bool { ["Jasmine", "Andre", "Lena"].contains(p.name) }
    func views(_ p: Person) -> String {
        turnaround(p)
            ? "three full-body views of the same character in a row: front view on the left, side view (facing right, in profile) in the middle, back view on the right. "
              + "Spread the three figures evenly across the full width, each centered in its own equal third, with large empty gaps between them; no overlap. "
              + "Same height and the same relaxed neutral standing pose in all three. The back view shows the back of the hair and headwear and how the apron ties"
            : "one full-body front view, centered, standing in a relaxed neutral pose, facing straight ahead"
    }
    /// The pencil design sheet prompt: the storyboard style, then this character.
    func sketchPrompt(_ p: Person) -> String {
        (store.sketchStyle + "\n\nCharacter design sheet, 16:9, plain white background: \(p.name), \(views(p)). \(p.look)").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The watercolor design sheet prompt: the series STYLE LOCK, then this character, painted from the attached sketch.
    func paintPrompt(_ p: Person) -> String {
        (store.paintStyle + "\n\nCharacter design sheet, 16:9, plain warm paper background: \(p.name), \(views(p)). "
            + "Paint over the attached pencil sketch exactly: same poses, proportions and clothing. \(p.look)").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// The sketch: the locked design, when there is one, for identity. The watercolor: the approved sketch, then the design for colors.
    func sketchRefs(_ p: Person) -> [PromptAttachment] {
        designFolder(p).flatMap { store.lockedDesign($0) }.map { [PromptAttachment(url: $0, role: "\(p.name)'s locked design: identity only (hair, headwear, face, clothing, build)")] } ?? []
    }
    func paintRefs(_ p: Person) -> [PromptAttachment] {
        [PromptAttachment(url: store.userFile("cast-sketch:\(p.name)"), role: "the approved pencil design sheet of \(p.name): paint over it exactly")]
            + (designFolder(p).flatMap { store.lockedDesign($0) }.map { [PromptAttachment(url: $0, role: "\(p.name)'s locked design: colors only")] } ?? [])
    }
    func designFolder(_ p: Person) -> String? { store.designFolder(p.name) }
    /// The characters with a locked design in Kitchen/ART/Characters.
    func art(_ p: Person) -> Image? {
        store.designFolder(p.name).flatMap { store.characterArt($0) }
    }
}

// MARK: - Food

struct FoodView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    @State var adding = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Like the characters: a pencil sketch first, then the watercolor painted from it. Drop a picture on a slot to add it; each slot keeps its own prompt. The strip shows which episodes the dish is in.")
                    .foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 16)], spacing: 16) {
                    ForEach(season.food) { d in
                        VStack(alignment: .leading, spacing: 8) {
                            // the pencil sketch first, then the watercolor made from it
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Eyebrow("Sketch")
                                    TruckImage(key: "food-sketch:\(d.name)", fallback: nil, label: "the sketch", aspect: 16 / 9)
                                    PromptField(key: "food-sketch:\(d.name)", title: "Copy sketch prompt")
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    Eyebrow("Watercolor")
                                    TruckImage(key: "food:\(d.name)", fallback: existing(d), label: "the watercolor", aspect: 16 / 9)
                                    PromptField(key: "food:\(d.name)", title: "Copy watercolor prompt")
                                    AttachmentList(groups: [("Attachments", [PromptAttachment(url: store.userFile("food-sketch:\(d.name)"), role: "the approved pencil sketch of the dish: color it exactly as drawn")])])
                                }
                            }
                            .padding(.bottom, 4)
                            Text(d.name).font(.serif(20))
                            Text("\(d.eps) · \(d.who)").font(.system(size: 12)).foregroundStyle(Color.soft)
                            Text(d.look).font(.system(size: 13))
                            if !d.heat.isEmpty { HeatStrip(h: d.heat).padding(.top, 4) }
                        }.listCard()
                    }
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .navigationTitle("Food")
        .navigationSubtitle("\(season.food.count) dishes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add dish", systemImage: "plus") }.help("Add a dish to this project")
            }
        }
        .sheet(isPresented: $adding) { AddLibrarySheet(dish: true) }
    }

    /// The dishes that already have a picture: the Meridian plate (prop 13) and the family-meal wok (k02).
    func existing(_ d: Dish) -> Image? {
        if d.name.contains("Meridian plate") { return store.thumb("p13") }
        if d.name.hasPrefix("Family meal") { return store.thumb("k02") }
        return nil
    }
}

/// An image slot's prompt, saved in state.json as you type, with a Copy button.
struct PromptField: View {
    @EnvironmentObject var store: Store
    let key: String
    let title: String
    @State var text = ""
    @State var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CopyButton(text: text, title: title).disabled(text.isEmpty)
                Button(open ? "Hide prompt" : (text.isEmpty ? "Write prompt" : "Edit prompt")) { open.toggle() }.controlSize(.small)
            }
            if open {
                TextEditor(text: $text).font(.system(size: 11)).frame(height: 140)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(Color(hex: 0x1a1714), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.line))
                    .onChange(of: text) { _, t in if t != store.prompt(key) { store.setPrompt(key, t) } }
            } else if !text.isEmpty {
                Text(summary).font(.system(size: 11)).foregroundStyle(Color.soft).lineLimit(2)
            }
        }
        .onAppear { text = store.prompt(key) }
    }
    /// The prompt's own line (the dish, or its colors), not the style lock every prompt starts with.
    var summary: String {
        let lines = text.split(separator: "\n").map(String.init)
        return lines.first { $0.hasPrefix("The dish:") || $0.hasPrefix("Food and vessel colors:") } ?? lines.last ?? ""
    }
}

// MARK: - Truck

// MARK: - Make list

fileprivate struct MakeRow: Identifiable {
    let key: String        // tick key, "ep:kind:id"
    let ep: Int
    let kind: String       // "prep", "gpt" or "built"
    let pid: String        // the ID shown on the pill
    let name: String
    let beats: String
    let desc: String
    let imgKey: String?    // where a finished image is kept (nil for prep)
    var id: String { key }
}

fileprivate func makeRows(_ season: Season, _ store: Store) -> [MakeRow] {
    var out: [MakeRow] = []
    for e in season.eps where !e.made {
        for p in e.prep {
            out.append(MakeRow(key: "\(e.n):prep:\(p.id)", ep: e.n, kind: "prep", pid: p.id,
                               name: p.name, beats: p.use, desc: p.looks, imgKey: nil))
        }
        for g in e.gpt {
            let c = g.count ?? 1
            out.append(MakeRow(key: "\(e.n):gpt:\(g.id)", ep: e.n, kind: "gpt", pid: g.id,
                               name: g.name + (c > 1 ? " (×\(c))" : ""), beats: g.beats, desc: g.shows,
                               imgKey: store.keyImg(e, g.id)))
        }
        for b in e.built {
            out.append(MakeRow(key: "\(e.n):built:\(b.id)", ep: e.n, kind: "built", pid: b.id,
                               name: b.name, beats: b.beats, desc: b.looks,
                               imgKey: store.keyImg(e, b.id)))
        }
    }
    return out
}

struct MakeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    @State var kind = "all"                  // all, prep, gpt or built
    @State var ep = 0                        // 0 = every episode

    var body: some View {
        let _ = store.imageVersion
        let rows = makeRows(season, store)
        let done = rows.filter { store.state.made[$0.key] == true }.count
        let shown = rows.filter { (kind == "all" || $0.kind == kind) && (ep == 0 || $0.ep == ep) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Tick things off as you make them. Drop a finished image on its Yours cell (or click Add) and it shows up on every beat that uses it. Back up your images from the File menu.")
                .foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
            Table(shown) {
                TableColumn("Done") { r in
                    Toggle("Done", isOn: Binding(get: { store.state.made[r.key] == true },
                                                 set: { store.state.made[r.key] = $0; store.save() }))
                        .labelsHidden()
                }.width(44)
                TableColumn("Ep") { r in Text("\(r.ep)").monospacedDigit() }.width(32)
                TableColumn("ID") { r in Text(r.pid).foregroundStyle(kindColor(r.kind)).fontWeight(.semibold) }.width(70)
                TableColumn("Yours") { r in YoursCell(row: r) }.width(70)
                TableColumn("What") { r in Text(r.name).fontWeight(.semibold).opacity(store.state.made[r.key] == true ? 0.45 : 1) }
                TableColumn("Beats") { r in Text(r.beats).foregroundStyle(.secondary) }.width(min: 90, ideal: 140)
                TableColumn("Description") { r in Text(r.desc).foregroundStyle(.secondary).help(r.desc) }
            }
        }
        .navigationTitle("Make list")
        .navigationSubtitle("\(done) of \(rows.count) done · \(rows.filter { $0.kind == "prep" }.count) make first · \(rows.filter { $0.kind == "gpt" }.count) ChatGPT · \(rows.filter { $0.kind == "built" }.count) built")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Kind", selection: $kind) {
                    Text("All").tag("all"); Text("Make first").tag("prep"); Text("ChatGPT").tag("gpt"); Text("I build").tag("built")
                }.pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Episode", selection: $ep) {
                    Text("Every episode").tag(0)
                    ForEach(season.eps.filter { !$0.made }) { e in Text("\(e.label)").tag(e.n) }
                }.pickerStyle(.menu)
            }
        }
    }

    func kindColor(_ k: String) -> Color { k == "gpt" ? .gpt : (k == "built" ? .built : .gold) }
}

/// The Yours cell: your finished image, or Add. Takes a dropped file.
fileprivate struct YoursCell: View {
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var store: Store
    let row: MakeRow
    @State var target = false
    var body: some View {
        if let k = row.imgKey {
            Group {
                if let im = store.image(k) {
                    im.resizable().scaledToFill().frame(width: 48, height: 27).clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Button("Add") { nav.choose([.image]) { store.setImage(k, from: $0) } }.controlSize(.small)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(target ? Color.gold : .clear, lineWidth: 2))
            .fileDrop(targeted: $target) { store.setImage(k, from: $0) }
        }
    }
}

// MARK: - Search

fileprivate let searchLimit = 400

fileprivate struct SearchHit: Identifiable {
    let epN: Int
    let epTitle: String
    let beatN: Int
    let text: String
    let img: String
    let scene: String       // "S2-13 · Wok toss, flame up the sides · T1 NIGHT", or "" with no scene planned
    var id: String { "\(epN)-\(beatN)" }
}

/// Matches the beat's line, its frame note, its picture code, and its scene: id (S2-13), name and plate (T1 NIGHT).
fileprivate func searchMatches(_ season: Season, _ store: Store, _ q: String) -> [SearchHit] {
    var out: [SearchHit] = []
    for e in season.eps {
        for b in e.beats {
            let sc = store.storyboard(e, b).map { [$0.id, $0.name, $0.plateKey ?? ""].filter { !$0.isEmpty }.joined(separator: " · ") } ?? ""
            let hay = b.text + " " + b.what + " " + b.img + " " + sc
            if hay.localizedCaseInsensitiveContains(q) {
                out.append(SearchHit(epN: e.n, epTitle: e.title, beatN: b.n, text: b.text, img: b.img, scene: sc))
            }
        }
    }
    return out
}

/// The beat text with every case-insensitive match marked gold.
fileprivate func highlighted(_ text: String, _ q: String) -> AttributedString {
    var out = AttributedString(text)
    guard !q.isEmpty else { return out }
    var start = text.startIndex
    while start < text.endIndex,
          let r = text.range(of: q, options: .caseInsensitive, range: start..<text.endIndex),
          !r.isEmpty {
        if let ar = Range(r, in: out) { out[ar].backgroundColor = Color.gold.opacity(0.35) }
        start = r.upperBound
    }
    return out
}

struct SearchView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    var body: some View {
        let q = nav.query.trimmingCharacters(in: .whitespaces)
        let hits: [SearchHit] = q.isEmpty ? [] : searchMatches(season, store, q)
        List {
            if hits.isEmpty {
                Text("No beat matches this search.").foregroundStyle(.secondary)
            }
            ForEach(hits.prefix(searchLimit)) { h in
                Button {
                    nav.query = ""
                    nav.go(.ep, ep: h.epN, beat: h.beatN)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Episode \(h.epN) · \(h.epTitle) · beat \(h.beatN) · \(h.img)").font(.caption).foregroundStyle(.secondary)
                        if !h.scene.isEmpty { Text(highlighted(h.scene, q)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gold) }
                        Text(highlighted(h.text, q)).font(.body(15))
                    }
                    .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .navigationTitle("Search")
        .navigationSubtitle(hits.count > searchLimit ? "\(hits.count) beats, showing \(searchLimit)" : "\(hits.count) beats mention “\(q)”")
    }
}

// MARK: - Scene review

/// The season scene review: the choices only you can make (type an answer), then the fixes Claude makes unless you hold them.
struct ReviewView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openURL) var openURL
    var body: some View {
        ScrollView {
            if let r = store.review {
                let mine = r.decisions.filter(\.craig), fixes = r.decisions.filter { !$0.craig }
                VStack(alignment: .leading, spacing: 16) {
                    Text("A check of every episode's scene plan, side by side. Answer the questions at the top; the fixes below happen unless you switch one to Hold. Your answers save here.")
                        .foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                    Table(r.summary) {
                        TableColumn("Episode") { Text("\($0.ep) · \($0.title)") }.width(min: 150, ideal: 170)
                        TableColumn("Painted now") { Text($0.paintedNow) }.width(90)
                        TableColumn("Painted after") { Text($0.paintedProposed).foregroundStyle(Color.gold) }.width(90)
                        TableColumn("Pose drops") { Text("\($0.poseNow) → \($0.poseProposed)") }.width(90)
                        TableColumn("What changes") { Text($0.change).lineLimit(3).font(.system(size: 12)) }
                    }
                    .frame(height: 330)

                    Text("Your choices (\(mine.filter { !(store.state.answers?[String($0.n)] ?? "").isEmpty }.count) of \(mine.count) answered)").font(.serif(22)).padding(.top, 8)
                    ForEach(mine) { d in
                        Box(title: "\(d.n) · \(d.title)") {
                            Text(d.question).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                            if !d.recommend.isEmpty { Text("Suggestion: \(d.recommend)").font(.system(size: 12)).foregroundStyle(Color.soft) }
                            TextField("Your answer", text: Binding(
                                get: { store.state.answers?[String(d.n)] ?? "" },
                                set: { var a = store.state.answers ?? [:]; a[String(d.n)] = $0; store.state.answers = a; store.save() }),
                                axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                        }.frame(maxWidth: 900, alignment: .leading)
                    }

                    Text("Fixes I'll make (\(fixes.filter { store.state.holds?[String($0.n)] == true }.count) on hold)").font(.serif(22)).padding(.top, 8)
                    ForEach(fixes) { d in
                        Box(title: "\(d.n) · \(d.title)") {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    if !d.recommend.isEmpty { Text(d.recommend).font(.system(size: 13, weight: .semibold)) }
                                    Text(d.detail).font(.system(size: 12)).foregroundStyle(Color.soft).lineLimit(4).fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle(store.state.holds?[String(d.n)] == true ? "Hold" : "OK", isOn: Binding(
                                    get: { store.state.holds?[String(d.n)] != true },
                                    set: { var h = store.state.holds ?? [:]; h[String(d.n)] = $0 ? nil : true; store.state.holds = h; store.save() }))
                                    .toggleStyle(.switch).controlSize(.small).frame(width: 90)
                            }
                        }.frame(maxWidth: 900, alignment: .leading)
                    }
                    Button("Open the full report") { openURL(URL(fileURLWithPath: r.report)) }.buttonStyle(.link).padding(.top, 6)
                }.padding(28).frame(maxWidth: 1500, alignment: .leading)
            } else {
                Text("No review yet. Run build_review.py.").foregroundStyle(Color.soft).padding(28)
            }
        }
        .navigationTitle("Scene review")
        .navigationSubtitle(store.review.map { "\($0.decisions.count) items · \($0.decisions.filter(\.craig).count) for you" } ?? "")
    }
}

// MARK: - Plates

/// The shared backgrounds. Drop a drawing (or the painting) on a plate once: every scene and pose drop on it, in
/// every episode, shows it until that beat has its own picture.
struct PlatesView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @State var ep: Int? = nil        // show only the plates one episode uses
    /// The plates an episode's scenes sit on, in the order they first come up.
    func platesIn(_ n: Int) -> [String] {
        var ids: [String] = []
        for s in (store.storyboards[n] ?? []).sorted(by: { ($0.beats.first ?? 0) < ($1.beats.first ?? 0) }) {
            if let k = s.plateKey, !ids.contains(k) { ids.append(k) }
        }
        return ids
    }
    var body: some View {
        let _ = store.imageVersion
        let shown: [PlateInfo] = ep.map { n in platesIn(n).compactMap { id in store.plates.first { $0.id == id } } } ?? store.plates
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Drop each background here once: the pencil sketch on the left, the painting on the right. Every scene on it, in every episode, shows the painting once it's in, and the sketch until then. A beat's own picture still wins.")
                    .foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 560), spacing: 16)], spacing: 16) {
                    ForEach(shown) { p in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach([("Sketch", "plate:\(p.id)", p.storyboardPrompt, "Copy sketch prompt"),
                                         ("Painting", "plate-paint:\(p.id)", p.paintingPrompt, "Copy painting prompt")], id: \.1) { slot in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Eyebrow(slot.0)
                                            if store.plateShownKey(p.id) == slot.1 { Text("SHOWN IN SCENES").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.gold) }
                                        }
                                        TruckImage(key: slot.1, fallback: nil, label: "the \(slot.0.lowercased())", aspect: 16 / 9)
                                            // with a picture in, a tap opens the plate's scenes; empty, it still picks a file
                                            .simultaneousGesture(TapGesture().onEnded {
                                                if store.hasImage(slot.1) && p.scenes > 0 { nav.path.append(.plate(p.id)) }
                                            })
                                        HStack(spacing: 6) {
                                            if let t = slot.2 { CopyButton(text: t, title: slot.3) }
                                            if store.hasImage(slot.1) { PlateRemoveButton(plate: p, key: slot.1, what: slot.0.lowercased()) }
                                        }
                                        let refs = store.plateAttachments(p)
                                        AttachmentList(groups: [("Attachments", slot.0 == "Sketch" ? refs.sketch : refs.paint)])
                                    }
                                }
                            }
                            HStack(alignment: .firstTextBaseline) {
                                Text(p.id).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.gold)
                                Text(p.name).font(.serif(17))
                            }
                            let eps = (store.season?.eps ?? []).map(\.n).filter { platesIn($0).contains(p.id) }
                            Text(eps.isEmpty ? "No episode yet" : "Episodes " + eps.map(String.init).joined(separator: ", "))
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.soft)
                            .contentShape(Rectangle())
                            .onTapGesture { if p.scenes > 0 { nav.path.append(.plate(p.id)) } }
                            HStack {
                                Text(p.scenes == 0 ? "Not used by any scene yet" : "\(p.scenes) scene\(p.scenes == 1 ? "" : "s") · \(p.beats) beats")
                                    .font(.system(size: 12)).foregroundStyle(Color.soft)
                                Spacer()
                                if p.scenes > 0 {
                                    Button { nav.path.append(.plate(p.id)) } label: { Label("See its scenes", systemImage: "rectangle.stack") }
                                        .buttonStyle(.borderedProminent).tint(.gold).controlSize(.small)
                                }
                            }
                            Text("ART/Locations/\(p.file)").font(.system(size: 11)).foregroundStyle(.tertiary).textSelection(.enabled)
                        }
                        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.line))

                    }
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .navigationTitle("Plates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker("Episode", selection: $ep) {
                    Text("All episodes (\(store.plates.count))").tag(Int?.none)
                    Divider()
                    ForEach((store.season?.eps ?? []).filter { !platesIn($0.n).isEmpty }) { e in
                        Text("\(e.label) · \(e.title) (\(platesIn(e.n).count))").tag(Int?.some(e.n))
                    }
                }.pickerStyle(.menu).fixedSize().help("Show only the plates one episode uses")
            }
        }
        .navigationSubtitle("\(store.plates.filter { store.hasImage("plate-paint:\($0.id)") }.count) of \(store.plates.count) painted · \(store.plates.filter { store.hasImage("plate:\($0.id)") }.count) sketched")
    }
}

struct PlateRemoveButton: View {
    @EnvironmentObject var store: Store
    let plate: PlateInfo
    var key: String
    var what: String
    @State var asking = false
    var body: some View {
        Button(role: .destructive) { asking = true } label: { Label("Remove", systemImage: "trash") }
            .controlSize(.small)
            .confirmationDialog("Remove the \(plate.id) \(what)?", isPresented: $asking, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { store.removeImage(key) }
            } message: { Text("\(plate.beats) beats use this plate. They'll show the other slot's picture, or a placeholder if it's empty.") }
    }
}

/// Every scene on one plate, episode by episode, with each beat shown at its zoom. Click a beat to open it.
struct PlateDetailView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    let plateID: String
    var body: some View {
        let _ = store.imageVersion
        let plate = store.plates.first { $0.id == plateID }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let p = plate { Text(p.name).foregroundStyle(.secondary) }
                ForEach(season.eps) { e in
                    let scenes = (store.storyboards[e.n] ?? []).filter { $0.plateKey == plateID }
                    if !scenes.isEmpty {
                        Text("\(e.label) · \(e.title)").font(.serif(22)).padding(.top, 6)
                        ForEach(scenes) { s in PlateSceneRow(e: e, s: s) }
                    }
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .scrollIndicators(.never)
        .navigationTitle(plateID)
        .navigationSubtitle(plate.map { "\($0.scenes) scenes · \($0.beats) beats" } ?? "")
    }
}

/// One scene on a plate: its beats as small previews at their zoom.
struct PlateSceneRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let s: Storyboard
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(s.id).font(.system(size: 13, weight: .bold)).foregroundStyle(Color.gold)
                Text(s.name).font(.serif(17))
                Pill(text: s.type == "plate" ? "PLATE" : s.isPoseDrop ? "POSE DROP" : "PAINTED SCENE",
                     color: s.type == "plate" ? .plate : s.isPoseDrop ? .built : .gpt)
                if s.type == "scene" {
                    Text("Its own painting replaces the plate once you drop it").font(.system(size: 11)).foregroundStyle(Color.soft)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(s.beats, id: \.self) { n in
                    if let b = e.beats.first(where: { $0.n == n }) { tile(b) }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
    }
    func tile(_ b: Beat) -> some View {
        Button { nav.open(ep: e.n, beat: b.n) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                    .overlay {
                        if let img = store.picture(e, b) { FramedPicture(image: img, frame: store.shownFrame(e, b)) }
                        else { Color(hex: 0x2a2520) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .topLeading) {
                        Text("\(b.n)").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.black.opacity(0.6), in: Capsule()).padding(6)
                    }
                Text(b.text).font(.body(13)).lineLimit(2).foregroundStyle(Color.ink).multilineTextAlignment(.leading)
                if let look = s.zooms?[String(b.n)]?.look {
                    Text(look).font(.system(size: 11)).foregroundStyle(Color.mute).lineLimit(2).multilineTextAlignment(.leading)
                }
            }
        }
        .buttonStyle(.plain)
        .clipped()
        .contentShape(Rectangle())
        .help("Open beat \(b.n) in \(e.label)")
    }
}
