import SwiftUI
import UniformTypeIdentifiers

// MARK: - Season

struct SeasonView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Every episode, every beat. Click an episode to open it. Each tick on a strip is one beat, colored by where its picture comes from. Click a tick to jump straight to that beat.")
                    .foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                let words = season.eps.reduce(0) { $0 + $1.words }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading, spacing: 14) {
                    Stat(value: "\(season.eps.count)", label: "episodes")
                    Stat(value: "\(season.eps.reduce(0) { $0 + $1.beats.count })", label: "beats")
                    Stat(value: words.formatted(), label: "words")
                    Stat(value: "\(words / 150)", label: "minutes of voice")
                    Stat(value: "\(season.eps.filter { !$0.made }.reduce(0) { $0 + $1.gptCount })", label: store.hasTrailer ? "images to make (Ep 2 to 10)" : "images to make")
                    Stat(value: "\(season.cast.filter { $0.status == "Make" }.count)", label: "characters to design")
                    Stat(value: "\(store.state.images.count)", label: "images you've added")
                }
                Legend()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 420), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(season.eps) { e in EpisodeCard(e: e) }
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .navigationTitle(store.seasons.first { $0.n == nav.seasonN }?.title ?? "Season 1")
        .navigationSubtitle(store.hasTrailer ? "From the walkout to a card face down on the counter" : store.projectName)
    }
}

struct EpisodeCard: View {
    @EnvironmentObject var nav: Nav
    let e: Episode
    @State var hover = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow("\(e.label)")
            // fixed lines (space kept when shorter) so every episode card is the same height
            Text(e.title).font(.serif(24)).lineLimit(1)
            Text(e.logline).font(.system(size: 13)).foregroundStyle(Color.soft).lineLimit(4, reservesSpace: true)
            Text(e.ends).font(.body(13).italic()).foregroundStyle(Color.gold).lineLimit(2, reservesSpace: true).padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.gold).frame(width: 2) }
            GeometryReader { g in
                HStack(spacing: 1) {
                    ForEach(e.beats) { b in
                        Rectangle().fill(Color.kind(b.kind).opacity(0.9))
                            .frame(width: max(1, (g.size.width - CGFloat(e.beats.count)) / CGFloat(e.beats.count)))
                            .help("\(b.n). \(b.text)")
                            .onTapGesture { nav.open(ep: e.n, beat: b.n) }
                    }
                }
            }.frame(height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 12) {
                Text("\(e.beats.count) beats"); Text("\(e.words) words"); Text("\(e.minutes) min")
                if e.made { Text("● made").foregroundStyle(Color.done) }
            }.font(.system(size: 11)).foregroundStyle(Color.mute)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) { Text("\(e.n)").font(.serif(56)).foregroundStyle(Color.line).padding(.trailing, 16).padding(.top, 2) }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(hover ? Color.gold : Color.line))
        .offset(y: hover ? -2 : 0).animation(.easeOut(duration: 0.15), value: hover)
        .onHover { hover = $0 }
        .contentShape(Rectangle()).onTapGesture { nav.open(ep: e.n) }
    }
}

// MARK: - Episode

struct EpisodeView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    let season: Season
    let n: Int
    let isRoot: Bool                     // the Episodes tab's own page, with the episode picker
    var e: Episode { season.eps.first { $0.n == n } ?? season.eps[0] }
    @State var show = Show.all
    @State var doneFilter = DoneFilter.all
    enum Show: String, CaseIterable {
        case all = "All beats", scenes = "Scenes", painted = "Painted", stills = "Stills", done = "Done", plate = "Plate", reuse = "Reuse", locationOnly = "Location only (needs painting)"
        var kind: String? { [.painted: "gpt", .done: "done", .plate: "plate", .reuse: "reuse"][self] }
    }

    /// Stills are the built screens (blue STILL cards); scenes are every painted picture.
    /// Painted, Done, Plate and Reuse match the beat's colour in the legend.
    func shows(_ b: Beat, _ f: Show? = nil) -> Bool {
        let still = b.kind == "built" || store.stillOf(e, b) != nil
        switch f ?? show {
        case .all: return true
        case .scenes: return !still
        case .stills: return still
        case .locationOnly: return store.isLocationOnly(e, b)
        default: return !still && b.kind == (f ?? show).kind
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(e.logline).foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 10) {
                        Stat(value: "\(e.beats.count)", label: "beats"); Stat(value: "\(e.words)", label: "words"); Stat(value: e.minutes, label: "minutes")
                        Stat(value: "\(e.gptCount)", label: "ChatGPT images"); Stat(value: "\(e.built.count)", label: "built stills")
                    }
                    recording
                    if store.storyboards[e.n] != nil { EpisodePictures(e: e) }
                    if !e.summary.isEmpty {
                        Box(title: "The story in one page") {
                            ForEach(Array(e.summary.enumerated()), id: \.offset) { _, s in
                                (Text(s.first ?? "").bold().foregroundColor(.ink) + Text(" " + (s.count > 1 ? s[1] : "")).foregroundColor(.soft)).font(.system(size: 13))
                                    .frame(maxWidth: 900, alignment: .leading)
                            }
                        }
                    }
                    Legend()
                    Box(title: "How to read this page") {
                        Text("Orange cards are painted scenes (ChatGPT). Blue cards marked STILL are single objects I build, not scenes: Choose still picks version A, B or C. The gold outline when you hover a card marks every other beat that uses the same picture. Drag an image from Finder onto a card to use it; on a still, drop the finished still, or open Choose still to drop a mockup for each option. ← → move · Space reads through · / searches.")
                            .font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                    }
                    let secs = e.sections.isEmpty ? [Section(span: "1-\(e.beats.count)", title: "", opts: [])] : e.sections
                    ForEach(Array(secs.enumerated()), id: \.offset) { si, s in
                      let beats = e.beats.filter { s.range.contains($0.n) && shows($0) && doneFilter.keeps(store.isDone(store.keyBeat(e, $0))) }
                      if !beats.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(s.title).font(.serif(20))
                            Text("Beats \(s.span)").font(.system(size: 12)).foregroundStyle(.tertiary)
                            Spacer()
                            if !s.opts.isEmpty && store.storyboards[e.n] == nil {
                                Button("3 ways to paint it") { nav.drawer = .options(si); nav.inspector = true }.buttonStyle(.link)
                            }
                        }.padding(.top, 18)
                        Divider()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            // the section's chapter title card leads its row, like any other slide
                            if show == .all && !e.sections.isEmpty { TitleCardTile(e: e, i: si, s: s) }
                            ForEach(beats) { b in BeatCard(e: e, b: b).id(b.n) }
                        }
                      }
                    }
                }
                .padding(28).frame(maxWidth: 1500, alignment: .leading)
            }
            .scrollIndicators(.never)
            .safeAreaInset(edge: .bottom, spacing: 0) { ExportStatusBar() }
            .onChange(of: nav.scrollTo) { _, v in if let v { withAnimation { proxy.scrollTo(v, anchor: .center) }; nav.scrollTo = nil } }
            .onAppear { if let v = nav.scrollTo { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(v, anchor: .center); nav.scrollTo = nil } } }
        }
        .navigationTitle("\(e.label) · \(e.title)")
        .navigationSubtitle("\(e.beats.count) beats · \(e.beats.filter { store.isDone(store.keyBeat(e, $0)) }.count) done · \(e.minutes) min\(e.made ? " · made" : "")")
        .toolbar {
            if isRoot {
                ToolbarItem(placement: .navigation) {
                    Picker("Episode", selection: Binding(get: { nav.ep }, set: { $0 == 0 ? nav.go(.trailer) : nav.go(.ep, ep: $0) })) {
                        ForEach(season.eps.filter { $0.seasonN == e.seasonN }) { x in Text("\(x.label) · \(x.title)").tag(x.n) }
                        if store.hasTrailer && e.seasonN == 1 { Text(Tab.trailer.rawValue).tag(0) }
                    }.pickerStyle(.menu).help("Choose an episode")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Done", selection: $doneFilter) {
                    ForEach(DoneFilter.allCases) { f in Text("\(f.rawValue) (\(e.beats.filter { f.keeps(store.isDone(store.keyBeat(e, $0))) }.count))").tag(f) }
                }.pickerStyle(.segmented).fixedSize().help("Show every beat, only the ones left, or only the done ones")
            }
            ToolbarItem(placement: .primaryAction) {
                Picker("Show", selection: $show) {
                    ForEach([Show.all, .scenes, .stills], id: \.self) { f in Text("\(f.rawValue) (\(e.beats.filter { shows($0, f) }.count))").tag(f) }
                    Divider()
                    ForEach([Show.painted, .done, .plate, .reuse], id: \.self) { f in Text("\(f.rawValue) (\(e.beats.filter { shows($0, f) }.count))").tag(f) }
                    Divider()
                    Text("\(Show.locationOnly.rawValue) (\(e.beats.filter { shows($0, .locationOnly) }.count))").tag(Show.locationOnly)
                }.pickerStyle(.menu).fixedSize().help("Show all beats, or only one kind: painted, still, done, plate or reuse")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                PlayEpisodeButton(e: e)
                Button { nav.inspector = false; player.open(e, store: store, at: nav.selected); nav.path.append(.readThrough(e.n)) } label: {
                    Label("Full-screen read-through", systemImage: "play.rectangle")
                }.help("Open the full-screen read-through")
                ExportVideoMenu(e: e)
                Button { nav.drawer = .plan; nav.inspector = true } label: { Label("Image plan", systemImage: "photo.on.rectangle.angled") }
                    .help("Image plan")
                Button { nav.inspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                    .help("Show or hide the details panel")
            }
        }
    }

    @State var audioTarget = false
    @State var showScript = false
    /// Three boxes side by side (stacked when the window is narrow): the voiceover, the script and the pictures.
    /// Each says where it stands in a line you can read at a glance, with its own buttons underneath.
    var recording: some View {
        let has = store.audioURL(e) != nil, own = store.isOwnAudio(e)
        let changed = store.changedSinceRecording(e)
        let syncNote = store.syncing[e.n] ?? store.state.syncNotes?["e\(e.n)"]
        let hasPictures = store.storyboards[e.n] != nil
        let sketchLeft = hasPictures ? store.remainingPrompts([e], .sketch).count : 0
        let paintLeft = hasPictures ? store.remainingPrompts([e], .painting).count : 0
        let boxes = Group {
            ProductionBox(title: "Voiceover", icon: "waveform", headline: has ? (own ? "Your recording" : "Original voiceover") : "No recording yet",
                          detail: has ? (syncNote ?? "Beats follow the voiceover's timing.") : "Drop the episode MP3 on this box.",
                          busy: store.syncing[e.n] != nil, highlight: audioTarget) {
                HStack(spacing: 8) {
                    if has {
                        Button { Task { await store.syncBeats(e) } } label: { Label("Sync beats", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderedProminent).tint(.gold).disabled(store.syncing[e.n] != nil)
                            .help("Listen to the recording on this Mac and line every beat up with where its words are said. Runs by itself when you drop in a new MP3.")
                    }
                    Button { nav.choose([.audio]) { store.setAudio(e, from: $0) } } label: { Label(has ? "Replace…" : "Choose MP3…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered)
                    if own {
                        Button(role: .destructive) { store.removeAudio(e) } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered).help("Remove your recording and go back to the original voiceover")
                    }
                }
            }
            .fileDrop(targeted: $audioTarget) { store.setAudio(e, from: $0) }
            ProductionBox(title: "Script", icon: "text.quote",
                          headline: changed.isEmpty ? "Matches the recording" : "Re-record \(changed.count) line\(changed.count == 1 ? "" : "s")",
                          detail: changed.isEmpty ? "Edit any line; the ones you change are listed here to record again."
                                                  : "Changed since the recording: beat \(changed.map(String.init).joined(separator: ", ")).",
                          alert: !changed.isEmpty) {
                Button { showScript = true } label: { Label("Edit script…", systemImage: "pencil") }
                    .buttonStyle(.borderedProminent).tint(.gold)
            }
            if hasPictures {
                ProductionBox(title: "Prompts to make", icon: "photo.on.rectangle.angled",
                              headline: sketchLeft + paintLeft == 0 ? "Every picture is in" : "\(sketchLeft + paintLeft) to make",
                              detail: "Copies the ones still missing, ready for Claude and the image API.") {
                    VStack(alignment: .leading, spacing: 8) {
                        PromptCopyRow(eps: [e], kind: .sketch, label: "Sketches", count: sketchLeft)
                        PromptCopyRow(eps: [e], kind: .painting, label: "Paintings", count: paintLeft)
                    }
                }
            }
        }
        // side by side, always: voiceover, script, prompts
        return HStack(alignment: .top, spacing: 12) { boxes }.fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showScript) { ScriptSheet(e: e) }
        .frame(maxWidth: 1100)
    }
}

// MARK: - Beat card

/// One box on the episode page: a small title, a headline that says where it stands, a line of detail, then its buttons.
struct ProductionBox<Content: View>: View {
    let title: String; let icon: String; let headline: String; let detail: String
    var busy = false, alert = false, highlight = false
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                Text(title.uppercased()).font(.system(size: 11, weight: .bold)).tracking(1.2)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
            }.foregroundStyle(Color.gold)
            Text(headline).font(.serif(22)).foregroundStyle(alert ? Color.gold : Color.ink).lineLimit(2)
            Text(detail).font(.system(size: 12)).foregroundStyle(Color.soft).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            content().controlSize(.regular)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(highlight ? Color.gold : Color.line, lineWidth: highlight ? 2 : 1))
    }
}

struct BeatCard: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var hover: Hover
    let e: Episode
    let b: Beat
    @State var target = false
    var still: Still? { store.stillOf(e, b) }
    /// What the gold hover outline groups by: the scene in the new plan, or the old image code (Ep 1).
    var group: String { store.storyboard(e, b).map { "scene:" + $0.id } ?? b.img }
    var body: some View {
        let _ = store.imageVersion
        let sel = nav.selected == b.n
        VStack(alignment: .leading, spacing: 0) {
            // the thumbnails are 16:9 (720 × 405): show the whole frame, no top/bottom crop
            Color.clear.aspectRatio(16 / 9, contentMode: .fit).overlay(picture).clipped()
                .revealOnHover(store.pictureURL(e, b))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Text("\(b.n)").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(.black.opacity(0.6), in: Capsule())
                        DoneToggle(key: store.keyBeat(e, b), compact: true)
                    }.padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    if let s = store.storyboard(e, b) {
                        Pill(text: s.id + (s.plateKey.map { " · \($0)" } ?? ""), color: s.type == "plate" ? .plate : s.isPoseDrop ? .built : .gpt).padding(8)
                    } else { Pill(text: b.img, color: .kind(b.kind)).padding(8) }
                }
                .overlay(alignment: .bottomLeading) {
                    if still != nil { Pill(text: "STILL", color: .built).padding(8) }
                    else if store.isLocationOnly(e, b) { Pill(text: "LOCATION ONLY · needs painting", color: .gpt, dark: true).padding(8) }
                }
                .overlay(alignment: .bottomTrailing) { if store.isYours(e, b) { Pill(text: "yours", color: .gold, dark: true).padding(8) } }
            Rectangle().fill(Color.kind(b.kind)).frame(height: 4)
            // every card is the same height: the first three lines (space kept when shorter), then one footer row.
            // The full line is in the side panel when the beat is clicked.
            Text(b.text).font(.body(14)).lineLimit(3, reservesSpace: true).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Group {
                if let s = still { StillStrip(e: e, b: b, s: s) }
                else {
                    let what = store.storyboard(e, b)?.zooms?[String(b.n)]?.look ?? b.what
                    Text(what).font(.system(size: 11)).foregroundStyle(Color.mute).lineLimit(2).help(what)
                }
            }
            .frame(height: 30, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(target || sel ? Color.gold : Color.line, lineWidth: sel || target ? 2.5 : 1))
        .overlay(TwinOutline(group: group, img: b.img))
        .overlay(NowPlayingOutline(e: e, n: b.n))
        .scaleEffect(target ? 1.02 : 1)
        .contentShape(Rectangle())
        .onTapGesture { nav.selected = b.n; nav.drawer = .beat; nav.inspector = true }
        .onHover { inside in
            if inside { if hover.img != group { hover.img = group } } else if hover.img == group { hover.img = nil }
        }
        .fileDrop(targeted: $target) { store.setImage(store.sceneKey(e, b) ?? store.keyImg(e, store.primaryId(e, b)), from: $0) }
        .help("Drop an image here")
    }

    @ViewBuilder var picture: some View {
        if let s = still, store.picked(e, s), store.userImage(e, b) == nil, !store.hasImage(store.optKey(e, s.id, store.chosen(e, s))),
           store.chosen(e, s) != 0 || store.builtStill(e, b) == nil {
            let c = store.chosen(e, s)
            ZStack(alignment: .topLeading) {
                Color(hex: 0x1d2733)
                HStack(alignment: .top, spacing: 6) {
                    Text(["A", "B", "C"][min(c, 2)]).font(.system(size: 12, weight: .bold)).frame(width: 24, height: 24).background(Color.built, in: Circle()).foregroundStyle(.white)
                    Text(s.choices[min(c, s.choices.count - 1)]).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color(hex: 0xcfe0f2)).lineLimit(4)
                }.padding(.top, 34).padding(.horizontal, 12)
            }
        } else if let img = store.cardPicture(e, b) {
            FramedPicture(image: img, frame: store.shownFrame(e, b))
        } else {
            ZStack { Color(hex: 0x2a2520); Text(Store.ids(b.img).first ?? "").font(.serif(28)).foregroundStyle(Color(hex: 0x5a5046)) }
        }
    }
}

/// A still's controls in one row: its id, the A/B/C options (mockups if dropped), and Choose or Edit.
struct StillStrip: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat; let s: Still
    var body: some View {
        let c = store.chosen(e, s), picked = store.picked(e, s)
        HStack(spacing: 6) {
            Text("Still \(s.id)").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.built).lineLimit(1)
            ForEach(0..<s.choices.count, id: \.self) { i in
                ZStack {
                    if let im = store.image(store.optKey(e, s.id, i)) { im.resizable().scaledToFill() }
                    else { Text(["A", "B", "C"][min(i, 2)]).font(.system(size: 9, weight: .bold)) }
                }
                .frame(width: 20, height: 20).background(Color(hex: 0x1a222c)).clipShape(Circle())
                .overlay(Circle().stroke(i == c && picked ? Color.built : Color(hex: 0x3a4f66), lineWidth: i == c && picked ? 2 : 1))
                .foregroundStyle(Color(hex: 0xcfe0f2))
            }
            if store.hasImage(store.keyImg(e, s.id)) { Pill(text: "final", color: .built) }
            Spacer(minLength: 4)
            if picked {
                Button("Edit") { nav.selected = b.n; nav.drawer = .beat; nav.inspector = true }.controlSize(.small)
            } else {
                Button("Choose still") { nav.chooser = s.id }.buttonStyle(.borderedProminent).tint(.built).controlSize(.small)
            }
        }
        .help(picked ? "Still \(s.id): \(["A", "B", "C"][min(c, 2)]) chosen. \(s.choices[min(c, s.choices.count - 1)])"
                     : "Still \(s.id): not chosen yet (A is my pick). \(s.choices[0])")
    }
}

// MARK: - Inspector (the side panel)

struct InspectorView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch nav.drawer {
                case .beat: if let n = nav.selected, let b = e.beats.first(where: { $0.n == n }) { BeatDetail(e: e, b: b) } else { Text("Click a beat").foregroundStyle(Color.soft) }
                case .options(let i): if e.sections.indices.contains(i) { SectionOptions(s: e.sections[i]) }
                case .plan: ImagePlan(e: e)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(Color.panel).foregroundStyle(Color.ink)
    }
}

struct DropZone: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let title: String; let key: String
    var height: CGFloat = 70
    @State var target = false
    var body: some View {
        let has = store.hasImage(key)
        VStack(spacing: 4) {
            Text(title).bold().foregroundStyle(Color.ink).font(.system(size: 13))
            Text("drop an image, or click to choose").font(.system(size: 12)).foregroundStyle(Color.soft)
            if has { Button("Remove", role: .destructive) { store.removeImage(key) }.buttonStyle(.borderless).controlSize(.small) }
        }
        .frame(maxWidth: .infinity, minHeight: height).padding(8)
        .background(target ? Color(hex: 0x2a2520) : .clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(target ? Color.gold : Color.line, style: StrokeStyle(lineWidth: 1.5, dash: [5])))
        .contentShape(Rectangle())
        .onTapGesture { nav.choose([.image]) { store.setImage(key, from: $0) } }
        .fileDrop(targeted: $target) { store.setImage(key, from: $0) }
    }
}

struct BeatDetail: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat
    var body: some View {
        let _ = store.imageVersion
        let pid = store.primaryId(e, b)
        let same = e.beats.filter { $0.n != b.n && !Set(Store.ids($0.img)).isDisjoint(with: Store.ids(b.img)) }
        let secIndex = e.sections.firstIndex { $0.range.contains(b.n) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) { Eyebrow("\(e.label) · beat \(b.n) · "); Eyebrow(Kind.label(b.kind), color: .kind(b.kind)); Spacer(); DoneToggle(key: store.keyBeat(e, b)) }
            Text(b.text).font(.body(20)).fixedSize(horizontal: false, vertical: true)
            PlayBeatButton(e: e, b: b)
            if let img = store.picture(e, b) {
                FrameEditor(e: e, b: b, image: img)
                HStack(spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = true } } label: {
                        Label("View full image", systemImage: "arrow.up.left.and.arrow.down.right")
                    }.controlSize(.small).help("Show the whole picture in the window (Esc closes, ← → change beat)")
                    RemoveImageButton(e: e, b: b)
                }
            }
            MotionBox(e: e, b: b)
            let board = store.storyboard(e, b)
            HStack(spacing: 8) {
                if let sb = board { DropZone(title: "Every beat in scene \(sb.id)", key: store.sceneKey(e, sb)) }
                else { DropZone(title: "Every beat using \(pid)", key: store.keyImg(e, pid)) }
                DropZone(title: "This beat only", key: store.keyBeat(e, b))
            }
            if let s = store.storyboard(e, b) {
                if let img = store.picture(e, b), s.beats.count > 1 || s.zooms?[String(b.n)]?.frame != nil { ZoomMap(e: e, s: s, current: b.n, image: img) }
                StoryboardBox(s: s, beat: b.n, e: e)
            }
            if board == nil {
                Box(title: "What you see") {
                    Text(b.what).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Text("Image: ").foregroundColor(.soft) + Text(b.img).bold()
                }
            }
            ForEach(Store.ids(b.img), id: \.self) { id in
                if board == nil, let g = e.gpt.first(where: { $0.id == id }) {
                    Box(title: "\(g.id) · \(g.name) · \(g.kind)") {
                        Text(g.shows).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        list("Zooms", g.zooms); list("Attach", g.attach); list("Check", g.watch)
                        Text(g.why).italic().foregroundStyle(Color.soft).font(.system(size: 13))
                    }
                } else if let s = store.stillFor(e, id: id) {
                    Box(title: "Still \(s.id) · \(s.name)", titleColor: .built, border: Color(hex: 0x2f4a66)) {
                        Text("This beat is a still: one object I build in code, not a painted scene. Tap the version you want.").font(.system(size: 13))
                        ForEach(0..<s.choices.count, id: \.self) { i in OptionRow(e: e, s: s, i: i) }
                        Text(s.why).italic().foregroundStyle(Color.soft).font(.system(size: 13))
                    }
                }
            }
            let shared = board.map { sb in sb.beats.filter { $0 != b.n } } ?? same.map { $0.n }
            if !shared.isEmpty {
                Box(title: board == nil ? "The same picture is used in" : "The same scene: one picture, a zoom each") {
                    FlowRow(items: shared) { n in
                        Button("\(n)") { nav.selected = n; nav.scrollTo = n }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if board == nil, let si = secIndex, !e.sections[si].opts.isEmpty {
                Button("See the 3 ways to paint “\(e.sections[si].title)” →") { nav.drawer = .options(si) }.buttonStyle(.bordered)
            }
        }
    }
    @ViewBuilder func list(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            Text(title).bold().font(.system(size: 12)).foregroundStyle(Color.soft).padding(.top, 2)
            ForEach(items, id: \.self) { Text("• " + $0).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct FlowRow<Content: View>: View {
    let items: [Int]
    @ViewBuilder let content: (Int) -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 6)], alignment: .leading, spacing: 6) { ForEach(items, id: \.self) { content($0) } }
    }
}

/// One of a still's options: tap to choose it, drop a mockup on its little box.
struct OptionRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let s: Still; let i: Int
    @State var target = false
    var body: some View {
        let on = i == store.chosen(e, s), key = store.optKey(e, s.id, i)
        HStack(spacing: 12) {
            Text(["A", "B", "C"][min(i, 2)]).font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
                .background(on ? Color.built : Color(hex: 0x2a2520), in: Circle()).foregroundStyle(on ? .white : Color.ink)
            (Text(s.choices[i]) + Text(i == 0 ? "  MY PICK" : "").font(.system(size: 10)).foregroundColor(.gold)).font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            ZStack {
                if let im = store.image(key) { im.resizable().scaledToFill() }
                else { Text("drop\nmockup").font(.system(size: 10)).multilineTextAlignment(.center).foregroundStyle(Color(hex: 0x7d9bb8)) }
            }
            .frame(width: 84, height: 48).background(Color(hex: 0x1a222c)).clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(target ? Color.gold : (store.hasImage(key) ? Color.built : Color(hex: 0x3a4f66)), style: StrokeStyle(lineWidth: 1.5, dash: store.hasImage(key) ? [] : [4])))
            .contentShape(Rectangle())
            .onTapGesture { nav.choose([.image]) { store.setImage(key, from: $0) } }
            .fileDrop(targeted: $target) { store.setImage(key, from: $0) }
            .contextMenu { if store.hasImage(key) { Button("Remove mockup") { store.removeImage(key) } } }
        }
        .padding(12).background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.built : Color.line, lineWidth: on ? 2 : 1))
        .contentShape(Rectangle()).onTapGesture { store.choose(e, s, i) }
    }
}

struct StillChooser: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let episode: Episode; let still: Still
    @State var target = false
    var body: some View {
        let _ = store.imageVersion
        let fk = store.keyImg(episode, still.id)
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("\(episode.label) · still \(still.id) · beats \(still.beats)")
            Text(still.name).font(.serif(26))
            Text("A still is one object I build in code, not a painted scene. Tap the version you want. Drop a mockup onto any option's box, or drop the finished still at the top. Change it any time.")
                .font(.system(size: 13)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
            ZStack {
                if let im = store.image(fk) { im.resizable().scaledToFit() }
                else { VStack(spacing: 2) { Text("The finished still").bold(); Text("drop it here, or click to choose").font(.system(size: 12)) }.foregroundStyle(Color(hex: 0xcfe0f2)) }
            }
            .frame(maxWidth: .infinity, minHeight: store.hasImage(fk) ? 180 : 70, maxHeight: 260)
            .background(Color(hex: 0x1a222c), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(target ? Color.gold : Color.built, style: StrokeStyle(lineWidth: 1.5, dash: store.hasImage(fk) ? [] : [5])))
            .contentShape(Rectangle())
            .onTapGesture { nav.choose([.image]) { store.setImage(fk, from: $0) } }
            .fileDrop(targeted: $target) { store.setImage(fk, from: $0) }
            if store.hasImage(fk) { Button("Remove the finished still", role: .destructive) { store.removeImage(fk) }.buttonStyle(.borderless) }
            ForEach(0..<still.choices.count, id: \.self) { i in
                OptionRow(e: episode, s: still, i: i).simultaneousGesture(TapGesture().onEnded { nav.chooser = nil })
            }
            Text(still.why).font(.system(size: 12)).foregroundStyle(Color.mute)
            HStack { Spacer(); Button("Close") { nav.chooser = nil }.keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 720).background(Color.panel).foregroundStyle(Color.ink).preferredColorScheme(.dark)
    }
}

struct SectionOptions: View {
    let s: Section
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("Beats \(s.span)")
            Text(s.title).font(.serif(26))
            ForEach(Array(s.opts.enumerated()), id: \.offset) { i, o in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(["A", "B", "C"][min(i, 2)])\(o.rec ? " · my pick" : "") · \(o.new)".uppercased()).font(.system(size: 10)).tracking(1.4).foregroundStyle(Color.gold)
                    Text(o.t).font(.serif(16))
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
                        ForEach(Array(o.beats.enumerated()), id: \.offset) { _, r in
                            GridRow { Text(r.first ?? "").foregroundStyle(Color.mute).frame(width: 46, alignment: .leading); Text(r.count > 1 ? r[1] : "") }.font(.system(size: 12))
                        }
                    }
                    (Text("Upside ").foregroundColor(.done) + Text(o.up)).font(.system(size: 12))
                    (Text("Catch ").foregroundColor(.red2) + Text(o.catch)).font(.system(size: 12))
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(o.rec ? Color.gold : Color.line))
            }
        }
    }
}

struct ImagePlan: View {
    let e: Episode
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("\(e.label)")
            Text("Image plan").font(.serif(26))
            if !e.prep.isEmpty {
                Box(title: "Make these first") {
                    ForEach(e.prep) { p in (Text("\(p.id) · \(p.name)\n").bold() + Text(p.looks).foregroundColor(.soft)).font(.system(size: 13)) }
                }
            }
            ForEach(e.gpt) { g in Box(title: "\(g.id) · ChatGPT · beats \(g.beats)", titleColor: .gpt) { Text(g.name).bold(); Text(g.shows).font(.system(size: 13)).foregroundStyle(Color.soft) } }
            ForEach(e.built) { s in Box(title: "\(s.id) · I build · beats \(s.beats)", titleColor: .built) { Text(s.name).bold(); Text(s.looks).font(.system(size: 13)).foregroundStyle(Color.soft) } }
        }
    }
}

// MARK: - Playing an episode in the bottom player

/// Toolbar play/pause for the episode on screen; starts at the selected beat.
struct PlayEpisodeButton: View {
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var nav: Nav
    let e: Episode
    var body: some View {
        let on = listener.ep == e.n && listener.playing
        Button { listener.toggle(e, from: nav.selected) } label: {
            Label(on ? "Pause" : "Play", systemImage: on ? "pause.fill" : "play.fill")
        }.help(on ? "Pause (Space)" : "Play this episode in the player (Space)")
    }
}

/// In the beat panel: start the recording at this beat.
struct PlayBeatButton: View {
    @EnvironmentObject var listener: Listener
    let e: Episode; let b: Beat
    var body: some View {
        let here = listener.nowBeat(e) == b.n && listener.playing
        Button { here ? listener.pause() : listener.play(e, beat: b.n) } label: {
            Label(here ? "Pause" : "Play from this beat", systemImage: here ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent).tint(.gold).controlSize(.large)
    }
}

/// A gold ring on the card of the beat the recording is on. Its own view, so only
/// the ring redraws as the audio plays, not the whole page.
struct NowPlayingOutline: View {
    @EnvironmentObject var listener: Listener
    let e: Episode; let n: Int
    var body: some View {
        if listener.nowBeat(e) == n {
            RoundedRectangle(cornerRadius: 12).stroke(Color.gold, lineWidth: 3)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: listener.playing ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 11, weight: .bold)).padding(6)
                        .background(Color.gold, in: Circle()).foregroundStyle(Color.dark).padding(8)
                }
                .allowsHitTesting(false)
        }
    }
}


/// A section's chapter title card, sized like a beat card so the row stays even.
struct TitleCardTile: View {
    @EnvironmentObject var store: Store
    let e: Episode; let i: Int; let s: Section
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(16 / 9, contentMode: .fit)
                .overlay { if let im = store.titleCard(e, i) { im.resizable().scaledToFill() } else { Color(hex: 0x423E37) } }
                .clipped()
                .overlay(alignment: .topLeading) { Pill(text: "TITLE", color: .gold, dark: true).padding(8) }
            Rectangle().fill(Color.gold).frame(height: 4)
            Text(s.title).font(.body(14)).lineLimit(3, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            Text("Title card · part \(i + 1) of \(e.sections.count) · beats \(s.span)").font(.system(size: 11)).foregroundStyle(Color.mute).lineLimit(1)
                .frame(height: 30, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 10)
        }
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.gold.opacity(0.5), lineWidth: 1))
        .help("Chapter title card: \(s.title)")
    }
}

// MARK: - Framing a beat's picture

/// A picture filling its box, zoomed and moved by the beat's framing.
/// The gold outline on a card whose picture the pointer is over somewhere else. Its own view, so a hover
/// redraws only these outlines.
struct TwinOutline: View {
    @EnvironmentObject var hover: Hover
    let group: String; let img: String
    var body: some View {
        let on: Bool = {
            guard let h = hover.img else { return false }
            if h.hasPrefix("scene:") || group.hasPrefix("scene:") { return h == group }
            return !Set(Store.ids(h)).isDisjoint(with: Store.ids(img))
        }()
        RoundedRectangle(cornerRadius: 12).stroke(on ? Color.gold : .clear, lineWidth: 1).allowsHitTesting(false)
    }
}

struct FramedPicture: View {
    let image: Image
    let frame: BeatFrame?
    var body: some View {
        GeometryReader { g in
            let f = frame ?? BeatFrame()
            image.resizable().scaledToFill()
                .frame(width: g.size.width, height: g.size.height)
                .scaleEffect(f.scale)
                .offset(x: (0.5 - f.x) * g.size.width * f.scale, y: (0.5 - f.y) * g.size.height * f.scale)
        }
        .clipped()
    }
}

/// Drag to move, pinch or slide to zoom: a live preview in the picture, saved when you let go. Beats and trailer shots
/// both use this one control. `locked` shows the framing without letting it change.
struct FrameControl: View {
    let image: Image
    let saved: BeatFrame
    let canReset: Bool
    let caption: String
    var locked = false
    var overPicture: AnyView? = nil          // drawn over the picture (a Kie run's status)
    let commit: (BeatFrame) -> Void
    let reset: () -> Void
    @State var live: BeatFrame? = nil        // while dragging, pinching or sliding
    @State var start: BeatFrame? = nil
    @State var sliding = false               // only a hand on the slider changes the zoom

    var body: some View {
        let f = live ?? saved
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { g in
                FramedPicture(image: image, frame: f)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            let s0 = start ?? saved; if start == nil { start = saved }
                            var n = s0
                            n.x = s0.x - v.translation.width / (g.size.width * s0.scale)
                            n.y = s0.y - v.translation.height / (g.size.height * s0.scale)
                            live = n.clamped()
                        }
                        .onEnded { _ in finish() })
                    .simultaneousGesture(MagnifyGesture()
                        .onChanged { v in
                            let s0 = start ?? saved; if start == nil { start = saved }
                            var n = s0; n.scale = s0.scale * v.magnification
                            live = n.clamped()
                        }
                        .onEnded { _ in finish() })
                    .allowsHitTesting(!locked)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(f.isFull ? Color.line : Color.gold, lineWidth: f.isFull ? 1 : 2))
            .overlay(alignment: .topLeading) {
                if !f.isFull { Pill(text: String(format: "%.1f×", f.scale), color: .gold, dark: true).padding(8) }
            }
            .overlay { overPicture }
            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                // the slider previews while you drag it and saves when you let go; when it glides back after
                // Reset it changes nothing
                Slider(value: Binding(get: { f.scale },
                                      set: { v in if sliding { var n = live ?? saved; n.scale = v; live = n.clamped() } }),
                       in: 1...4, onEditingChanged: { editing in sliding = editing; if !editing { finish() } })
                    .disabled(locked)
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
                Button("Reset") { live = nil; start = nil; reset() }.disabled(!canReset)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    func finish() {
        if let l = live { commit(l) }
        live = nil; start = nil
    }
}

/// In the beat panel. The framing is this beat's alone.
struct FrameEditor: View {
    @EnvironmentObject var store: Store
    let e: Episode; let b: Beat; let image: Image
    var body: some View {
        FrameControl(image: image, saved: store.shownFrame(e, b) ?? BeatFrame(), canReset: store.frame(e, b) != nil,
                     caption: "Drag to move, pinch or slide to zoom. This framing is for beat \(b.n) only; it shows on its card and in the read-through.",
                     commit: { store.setFrame(e, b, $0) }, reset: { store.setFrame(e, b, nil) })
    }
}

/// The selected beat's whole picture, filling the window. ← → move between beats, Esc or a click closes it.
struct BeatViewer: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat
    var body: some View {
        let _ = store.imageVersion
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
                .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = false } }
            VStack(spacing: 16) {
                if let url = store.fullPictureURL(e, b) {
                    // the whole file at full resolution: pinch or the mouse wheel zooms, drag pans, double-click, Fit
                    ZoomableImage(url: url, version: store.imageVersion).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let img = store.fullPicture(e, b) {
                    FramedPicture(image: img, frame: store.shownFrame(e, b)).aspectRatio(16 / 9, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(Store.ids(b.img).first ?? "No picture yet").font(.serif(40)).foregroundStyle(Color.soft)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Eyebrow("\(e.label) · beat \(b.n) · \(b.img)")
                    Text(b.text).font(.body(18)).lineLimit(2)
                }.frame(maxWidth: 1100)
            }.padding(.horizontal, 40).padding(.top, 54).padding(.bottom, 24)
        }
        .overlay(alignment: .topTrailing) {
            ViewerControls(url: store.fullPictureURL(e, b), close: { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = false } })
        }
    }
}

/// A scene's storyboard prompt (the style lock first, then the scene), with a Copy button.
struct StoryboardBox: View {
    @EnvironmentObject var store: Store
    let s: Storyboard
    var beat: Int? = nil
    var e: Episode? = nil
    @State var open = false
    var body: some View {
        Box(title: "Storyboard · \(s.id) · \(s.name)") {
            HStack(spacing: 8) {
                Pill(text: s.type == "plate" ? "PLATE" : s.isPoseDrop ? "POSE DROP" : "PAINTED SCENE", color: s.type == "plate" ? .plate : s.isPoseDrop ? .built : .gpt)
                Text("Beats \(s.beats.map(String.init).joined(separator: ", "))").font(.system(size: 11)).foregroundStyle(Color.soft)
                Spacer()
                CopyButton(text: s.prompt)
            }
            if let n = beat, let z = s.zooms?[String(n)] {
                if let look = z.look { (Text("Zoom on: ").bold().foregroundColor(.gold) + Text(look)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
                if let why = z.why { (Text("Why: ").bold().foregroundColor(.soft) + Text(why).foregroundColor(.soft)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true) }
                if let p = z.pose, !p.isEmpty, p != "None" { (Text("Pose: ").foregroundColor(.soft) + Text(p)).font(.system(size: 12)) }
            }
            Text(s.wide).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            if !s.plate.isEmpty { (Text("Plate: ").foregroundColor(.soft) + Text(s.plate)).font(.system(size: 12)).textSelection(.enabled) }
            if let e {
                let refs = store.sceneAttachments(e, s)
                AttachmentList(groups: [("Sketch attachments", s.isEdit ? [] : refs.sketch), ("Painting attachments", refs.paint)])
            }
            DisclosureGroup("Full prompt", isExpanded: $open) {
                Text(s.prompt).font(.system(size: 12)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }.font(.system(size: 12))
        }
    }
}

/// Puts text on the clipboard. The one AppKit call in the app: SwiftUI has no clipboard write on the Mac.
struct CopyButton: View {
    @EnvironmentObject var store: Store
    let text: String
    var title = "Copy prompt"
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            store.say("Prompt copied")
        } label: { Label(title, systemImage: "doc.on.doc") }
        .controlSize(.small).help("Copy the storyboard style and this scene's prompt")
    }
}

/// Every scene's storyboard prompt, Episodes 2 to 10, in story order.
struct StoryboardsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    @State var showPoses = true
    var body: some View {
        let eps = season.eps.filter { store.storyboards[$0.n] != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("One storyboard per scene. Every prompt starts with the storyboard style, then the scene. Painted scenes are new paintings; pose drops are a plate with a pose placed on it.")
                    .foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)
                if eps.isEmpty { Text("No storyboards yet. Run build_storyboards.py.").foregroundStyle(Color.soft) }
                ForEach(eps) { e in
                    let all = store.storyboards[e.n] ?? []
                    let boards = all.filter { showPoses || !$0.isPoseDrop }.sorted { ($0.beats.first ?? 0) < ($1.beats.first ?? 0) }
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(e.label) · \(e.title)").font(.serif(22))
                        Text("\(all.filter { $0.type == "scene" }.count) painted · \(all.filter(\.isPoseDrop).count) pose drops · \(all.filter { $0.type == "plate" }.count) plates").font(.system(size: 12)).foregroundStyle(.tertiary)
                        Spacer()
                        Button("Open episode") { nav.open(ep: e.n) }.buttonStyle(.link)
                    }.padding(.top, 12)
                    ForEach(boards) { s in StoryboardBox(s: s).frame(maxWidth: 1000, alignment: .leading) }
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .navigationTitle("Storyboards")
        .navigationSubtitle("\(store.storyboards.values.reduce(0) { $0 + $1.count }) scenes")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { PromptBatchMenu(eps: season.eps.filter { store.storyboards[$0.n] != nil }) }
            ToolbarItem(placement: .primaryAction) {
                Toggle("Show pose drops", isOn: $showPoses).toggleStyle(.switch).controlSize(.small)
            }
        }
    }
}

/// The scene's whole picture with a numbered box for every beat in it: where each beat zooms.
/// A solid box is the framing you saved; a dashed one is the plan's suggestion. Click a box to go to that beat.
struct ZoomMap: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let s: Storyboard; let current: Int; let image: Image
    @State var working = false
    var body: some View {
        let _ = store.imageVersion
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Eyebrow("Where each beat zooms")
                Spacer()
                Button {
                    working = true
                    Task { await store.autoZoom(e, s); working = false }
                } label: { Label(working ? "Looking…" : "Auto-zoom", systemImage: "wand.and.stars") }
                .controlSize(.small).disabled(working)
                .help("Find each beat's zoom in this picture on this Mac, and flag anything missing. Fills beats you haven't framed.")
                let missing = s.beats.filter { n in e.beats.first { $0.n == n }.map { store.frame(e, $0) == nil } ?? false && s.zooms?[String(n)]?.frame != nil }
                if !missing.isEmpty {
                    Button("Use the plan for \(missing.count == 1 ? "1 beat" : "\(missing.count) beats")") {
                        for n in missing { if let b = e.beats.first(where: { $0.n == n }) { store.setFrame(e, b, s.zooms?[String(n)]?.frame) } }
                        store.imageVersion += 1; store.say("Planned zooms applied")
                    }.controlSize(.small).help("Give every beat in this scene without a framing its planned zoom")
                }
            }
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    FramedPicture(image: image, frame: nil)
                    ForEach(s.beats, id: \.self) { n in
                        let b = e.beats.first { $0.n == n }
                        let saved = b.flatMap { store.frame(e, $0) }
                        let f = saved ?? s.zooms?[String(n)]?.frame ?? BeatFrame()
                        let w = g.size.width / f.scale, h = g.size.height / f.scale
                        let on = n == current
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(on ? Color.gold : Color.white.opacity(0.85),
                                    style: StrokeStyle(lineWidth: on ? 3 : 1.5, dash: saved == nil ? [6, 4] : []))
                            .background(on ? Color.gold.opacity(0.08) : .clear)
                            .frame(width: w, height: h)
                            .overlay(alignment: .topLeading) {
                                Text("\(n)").font(.system(size: 11, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(on ? Color.gold : Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(on ? Color.dark : .white).padding(3)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { nav.selected = n; nav.scrollTo = n }
                            .offset(x: f.x * g.size.width - w / 2, y: f.y * g.size.height - h / 2)
                            .help("Beat \(n)\(saved == nil ? ": planned zoom (not set yet)" : ": your framing")")
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.line))
            if let b = e.beats.first(where: { $0.n == current }), let note = store.autoNote(e, b) {
                Label(note.found ? note.note : "Missing: \(note.note)", systemImage: note.found ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(note.found ? Color.done : Color.gpt).fixedSize(horizontal: false, vertical: true)
            }
            let flagged = s.beats.filter { n in e.beats.first { $0.n == n }.flatMap { store.autoNote(e, $0) }.map { !$0.found } ?? false }
            if !flagged.isEmpty {
                Text("Not found in this picture: beat\(flagged.count == 1 ? "" : "s") \(flagged.map(String.init).joined(separator: ", "))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gpt)
            }
            HStack(spacing: 14) {
                Label("Your framing", systemImage: "square").font(.system(size: 11)).foregroundStyle(Color.soft)
                Label("Planned, not set yet", systemImage: "square.dashed").font(.system(size: 11)).foregroundStyle(Color.soft)
                if let plan = s.zooms?[String(current)]?.frame, let b = e.beats.first(where: { $0.n == current }), store.frame(e, b) == nil {
                    Spacer()
                    Button("Use the plan for beat \(current)") { store.setFrame(e, b, plan); store.imageVersion += 1 }.controlSize(.small)
                }
            }
        }
    }
}

/// Removes the image you added that this beat shows, after saying how many beats share it.
struct RemoveImageButton: View {
    @EnvironmentObject var store: Store
    let e: Episode; let b: Beat
    @State var asking = false
    var body: some View {
        if let src = store.shownImageSource(e, b) {
            Button(role: .destructive) { asking = true } label: { Label("Remove image", systemImage: "trash") }
                .controlSize(.small)
                .help("Remove the image on \(src.label)")
                .confirmationDialog("Remove the image on \(src.label)?", isPresented: $asking, titleVisibility: .visible) {
                    Button("Remove", role: .destructive) { store.removeImage(src.key) }
                } message: {
                    Text(src.beats > 1 ? "It shows on \(src.beats) beats. They'll go back to their plate or placeholder." : "This beat goes back to its plate or placeholder.")
                }
        }
    }
}
