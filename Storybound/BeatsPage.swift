import SwiftUI
import AppKit
import AVFoundation

// MARK: - The new episode workspace: the Beats stage (Storybench direction). Script is in ScriptPage.swift, Edit in EditPage.swift; Artwork isn't built yet.

extension Color {
    static let benchBG = Color(hex: 0x151c2b), benchPanel = Color(hex: 0x1a2232), benchCard = Color(hex: 0x1f2839), benchRaised = Color(hex: 0x28324a)
    static let benchLine = Color(hex: 0x3a465e), benchInk = Color(hex: 0xe9edf5), benchSoft = Color(hex: 0xa3aec2), benchMute = Color(hex: 0x6f7b92)
    static let benchBlue = Color(hex: 0x6288e6), benchGreen = Color(hex: 0x4cc07f), benchAmber = Color(hex: 0xe6b63f)
}
extension Font { static func bench(_ s: CGFloat) -> Font { .system(size: s, design: .serif) } }
extension Notification.Name { static let beatsSeek = Notification.Name("beatsSeek") }

enum BeatsFilter: String, CaseIterable { case all = "All beats", artwork = "Needs artwork", recording = "Needs recording" }

/// Where a beat's picture stands. "Approved" is the beat's Done tick.
enum ArtStatus {
    case approved, review, needsPainting, needsArtwork
    var label: String {
        switch self { case .approved: return "Approved"; case .review: return "Needs review"; case .needsPainting: return "Needs painting"; case .needsArtwork: return "Needs artwork" }
    }
    var color: Color {
        switch self { case .approved: return .benchGreen; case .review, .needsPainting: return .benchAmber; case .needsArtwork: return .benchMute }
    }
    var needsWork: Bool { self == .needsPainting || self == .needsArtwork }
}
/// Where a beat's voiceover stands.
enum AudioStatus {
    case synced, unsynced, needsRecording, none
    var label: String {
        switch self { case .synced: return "Audio synced"; case .unsynced: return "Not synced"; case .needsRecording: return "Needs recording"; case .none: return "No audio" }
    }
    var color: Color {
        switch self { case .synced: return .benchSoft; case .unsynced, .needsRecording: return .benchAmber; case .none: return .benchMute }
    }
}

extension Store {
    func artStatus(_ e: Episode, _ b: Beat) -> ArtStatus {
        if isLocationOnly(e, b) { return .needsPainting }
        if cardPicture(e, b) == nil { return .needsArtwork }
        return isDone(keyBeat(e, b)) ? .approved : .review
    }
    func audioStatus(_ e: Episode, _ b: Beat, changed: Set<Int>) -> AudioStatus {
        if changed.contains(b.n) { return .needsRecording }
        if audioURL(e) != nil, !hasRecordedTime(e, b) { return .needsRecording }   // added after the recording was made
        return episodeAudioStatus(e)
    }
    /// The other beats showing this beat's picture. A beat with its own picture shares it with nobody, and beats with their own pictures don't count.
    func sharedBeats(_ e: Episode, _ b: Beat) -> [Int] {
        if hasImage(keyBeat(e, b)) { return [] }
        let others: [Int]
        if let s = storyboard(e, b) { others = s.beats.filter { $0 != b.n } }
        else { others = e.beats.filter { $0.n != b.n && !Set(Store.ids($0.img)).isDisjoint(with: Store.ids(b.img)) }.map(\.n) }
        return others.filter { n in e.beats.first { $0.n == n }.map { !hasImage(keyBeat(e, $0)) } ?? false }
    }
    /// The recording's timings know this beat.
    func hasRecordedTime(_ e: Episode, _ b: Beat) -> Bool {
        if let s = state.syncTimes?["e\(e.n)"] { return s.contains { $0.first == Double(b.n) } }
        if let t = e.timing, !isOwnAudio(e) { return t.contains { $0.first == Double(b.n) } }
        return true    // timed by word count: every beat is covered
    }
    func episodeAudioStatus(_ e: Episode) -> AudioStatus {
        if audioURL(e) == nil { return .none }
        return state.syncTimes?["e\(e.n)"] != nil || (e.timing != nil && !isOwnAudio(e)) ? .synced : .unsynced
    }
    /// The episode's running time without asking the player: measured when we have it, else by word count.
    func estimatedLength(_ e: Episode) -> Double {
        if !isOwnAudio(e), let last = e.timing?.last, last.count >= 3 { return last[2] + 1 }
        if let last = state.syncTimes?["e\(e.n)"]?.last, last.count >= 3 { return last[2] + 1 }
        return Double(e.words) / 150 * 60
    }
}

func benchClock(_ t: Double) -> String { let s = Int(max(0, t).rounded()); return String(format: "%02d:%02d", s / 60, s % 60) }

// MARK: - Which page an episode shows

/// The new Beats page, with a switch back to the old episode page while the other stages aren't built.
struct EpisodeStage: View {
    @EnvironmentObject var nav: Nav
    let season: Season; let n: Int; let isRoot: Bool
    var body: some View {
        Group {
            if nav.oldEpisodePage && season.eps.first(where: { $0.n == n })?.beats.isEmpty == false { EpisodeView(season: season, n: n, isRoot: isRoot) }
            else if nav.stage == .script { ScriptPage(season: season, n: n, isRoot: isRoot).id(n) }
            else if nav.stage == .edit { EditPage(season: season, n: n, isRoot: isRoot).id(n) }
            else { BeatsPage(season: season, n: n, isRoot: isRoot) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(nav.oldEpisodePage ? "New page" : "Old page") { nav.oldEpisodePage.toggle() }
                    .help("Switch between the new Beats page and the old episode page")
            }
        }
    }
}

enum Stage: String, CaseIterable {
    case beats = "Beats", script = "Script", artwork = "Artwork", edit = "Edit"
    var built: Bool { self != .artwork }
}

struct StageTabs: View {
    @EnvironmentObject var nav: Nav
    var body: some View {
        HStack(spacing: 2) {
            ForEach(Stage.allCases, id: \.self) { s in
                Button { nav.stage = s } label: {
                    Text(s.rawValue).font(.system(size: 13, weight: .medium)).frame(width: 74, height: 24)
                        .background(nav.stage == s ? Color.benchBlue : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(nav.stage == s ? Color.white : s.built ? Color.benchInk : Color.benchMute)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(!s.built)
                .help(s.built ? "" : "\(s.rawValue) isn't built yet")
            }
        }.padding(2)
    }
}

/// The title and toolbar every stage of an episode shares.
struct StageChrome: ViewModifier {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    let season: Season; let e: Episode; let isRoot: Bool
    func body(content: Content) -> some View {
        content
            .navigationTitle("\(e.title)")
            .navigationSubtitle("\(store.seasons.first { $0.n == e.seasonN }?.title ?? "Season 1") · Episode \(String(format: "%02d", e.number)) · \(e.beats.count) beats")
            .toolbar {
                if isRoot {
                    ToolbarItem(placement: .navigation) {
                        Picker("Episode", selection: Binding(get: { nav.ep }, set: { $0 == 0 ? nav.go(.trailer) : nav.go(.ep, ep: $0) })) {
                            ForEach(season.eps.filter { $0.seasonN == e.seasonN }) { x in Text("\(x.label) · \(x.title)").tag(x.n) }
                            if store.hasTrailer && e.seasonN == 1 { Text(Tab.trailer.rawValue).tag(0) }
                        }.pickerStyle(.menu).help("Choose an episode")
                    }
                }
                ToolbarItem(placement: .principal) { StageTabs() }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { nav.inspector = false; player.open(e, store: store, at: nav.selected); nav.path.append(.readThrough(e.n)) } label: {
                        Label("Preview", systemImage: "play.fill")
                    }.help("Open the full-screen read-through").disabled(e.beats.isEmpty)
                    ExportVideoMenu(e: e).disabled(e.beats.isEmpty)
                    Button { nav.inspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
                        .help("Show or hide the beat panel")
                }
            }
    }
}

/// The "Is this right?" and prompt sheets the Generate buttons open.
struct BeatGenerateSheets: ViewModifier {
    @EnvironmentObject var tm: TrailerModel
    @EnvironmentObject var store: Store
    let e: Episode
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { tm.confirming != nil }, set: { if !$0 { tm.confirming = nil } })) {
                if let jobs = tm.confirming { GenConfirmSheet(jobs: jobs).environmentObject(store).environmentObject(tm) }
            }
            .sheet(isPresented: Binding(get: { tm.beatPrompt != nil }, set: { if !$0 { tm.beatPrompt = nil } })) {
                if let n = tm.beatPrompt, let b = e.beats.first(where: { $0.n == n }) { BeatPromptSheet(e: e, b: b).environmentObject(store).environmentObject(tm) }
            }
    }
}

// MARK: - The page

struct BeatsPage: View {
    @EnvironmentObject var tm: TrailerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    let season: Season; let n: Int; let isRoot: Bool
    var e: Episode { season.eps.first { $0.n == n } ?? season.eps[0] }
    @State var filter = BeatsFilter.all
    @State var asList = false
    @AppStorage("beatsCardSize") var cardSize = 340.0
    @State var showNewBeat = false

    var body: some View {
        let _ = store.imageVersion
        let e = self.e
        let changed = Set(store.changedSinceRecording(e))
        let times = store.beatTimes(e, duration: store.estimatedLength(e))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                page(e, changed: changed, times: times).frame(minWidth: 0, maxWidth: .infinity)
                if nav.inspector, let b = e.beats.first(where: { $0.n == nav.selected }) {
                    Rectangle().fill(Color.benchLine).frame(width: 1)
                    BeatPanel(e: e, b: b, span: span(e, b, times), changed: changed).id(b.n).frame(width: 360)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            Rectangle().fill(Color.benchLine).frame(height: 1)
            BeatsPlayer(e: e, times: times)
        }
        .background(Color.benchBG)
        .foregroundStyle(Color.benchInk)
        .sheet(isPresented: $showNewBeat) {
            NewBeatSheet(e: e) { n in filter = .all; nav.selected = n; nav.scrollTo = n; nav.inspector = true }
        }
        .modifier(StageChrome(season: season, e: e, isRoot: isRoot))
        .onAppear(perform: selectFirst)
        .onChange(of: n) { _, _ in selectFirst() }
        .onChange(of: nav.selected) { _, v in if v == nil { selectFirst() } }
    }

    func selectFirst() {
        if nav.selected == nil { nav.selected = e.beats.first?.n }
        nav.inspector = true; nav.drawer = .beat
    }
    func span(_ e: Episode, _ b: Beat, _ times: [(Double, Double)]) -> (Double, Double) {
        guard let i = e.beats.firstIndex(where: { $0.n == b.n }), times.indices.contains(i) else { return (0, 0) }
        return times[i]
    }
    func keeps(_ e: Episode, _ b: Beat, _ changed: Set<Int>) -> Bool {
        switch filter {
        case .all: return true
        case .artwork: return store.artStatus(e, b).needsWork
        case .recording: let a = store.audioStatus(e, b, changed: changed); return a == .needsRecording || a == .none
        }
    }

    @ViewBuilder func page(_ e: Episode, changed: Set<Int>, times: [(Double, Double)]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !changed.isEmpty { banner(changed) }
                    controls
                    let secs = Listener.sections(e)
                    ForEach(Array(secs.enumerated()), id: \.offset) { _, s in
                        let beats = e.beats.filter { s.range.contains($0.n) && keeps(e, $0, changed) }
                        if !beats.isEmpty {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(s.title).font(.bench(26))
                                Text("Beats \(String(format: "%02d", s.range.lowerBound))–\(String(format: "%02d", s.range.upperBound))").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                            }.padding(.top, 8)
                            if asList {
                                LazyVStack(spacing: 8) {
                                    ForEach(beats) { b in BeatRow(e: e, b: b, span: span(e, b, times), changed: changed).id(b.n) }
                                }
                            } else {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                                    ForEach(beats) { b in BenchBeatCard(e: e, b: b, span: span(e, b, times), changed: changed).id(b.n) }
                                }
                            }
                        }
                    }
                    if !e.beats.contains(where: { keeps(e, $0, changed) }) {
                        Text(e.beats.isEmpty ? "No beats yet." : "No beats here.").foregroundStyle(Color.benchSoft).padding(.top, 20)
                    }
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .safeAreaInset(edge: .bottom, spacing: 0) { VStack(spacing: 0) { ExportStatusBar(); if !tm.beatPicks.isEmpty { BeatGenerateBar(e: e) } } }
            .onChange(of: e.n) { _, _ in tm.beatPicks = [] }
            .modifier(BeatGenerateSheets(e: e))
            .onChange(of: nav.scrollTo) { _, v in if let v { withAnimation { proxy.scrollTo(v, anchor: .center) }; nav.scrollTo = nil } }
            .onAppear { if let v = nav.scrollTo { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(v, anchor: .center); nav.scrollTo = nil } } }
        }
    }

    func banner(_ changed: Set<Int>) -> some View {
        let count = changed.count
        return HStack(spacing: 10) {
            Image(systemName: "info.circle").foregroundStyle(Color.benchBlue)
            Text("\(count) line\(count == 1 ? "" : "s") need\(count == 1 ? "s" : "") recording").font(.system(size: 13, weight: .medium))
            Spacer()
            Button { nav.selected = changed.min(); nav.scrollTo = nav.selected; nav.stage = .script } label: { Label("Review", systemImage: "arrow.right").labelStyle(TrailingIcon()) }
                .buttonStyle(.plain).foregroundStyle(Color.benchBlue)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.benchLine))
    }

    var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(BeatsFilter.allCases, id: \.self) { f in
                    Button { filter = f } label: {
                        Text(f.rawValue).font(.system(size: 12, weight: .medium)).padding(.horizontal, 14).frame(height: 26)
                            .background(filter == f ? Color.benchRaised : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(filter == f ? Color.benchInk : Color.benchSoft)
                }
            }.padding(2).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
            Button { showNewBeat = true } label: {
                Label("Add beat", systemImage: "plus").font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                    .background(Color.benchBlue, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Add a beat at the end of this episode")
            Spacer()
            HStack(spacing: 2) {
                viewButton("square.grid.2x2.fill", on: !asList, tip: "Cards") { asList = false }
                viewButton("list.bullet", on: asList, tip: "List") { asList = true }
            }.padding(2).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
            if !asList {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle").font(.system(size: 10))
                    Slider(value: $cardSize, in: 240...560).frame(width: 90).controlSize(.mini).tint(.benchBlue)
                    Image(systemName: "rectangle").font(.system(size: 15))
                }.foregroundStyle(Color.benchSoft).help("Card size")
            }
        }
    }
    func viewButton(_ icon: String, on: Bool, tip: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 12)).frame(width: 30, height: 26)
                .background(on ? Color.benchRaised : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(on ? Color.benchInk : Color.benchSoft).help(tip)
    }
}

struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View { HStack(spacing: 6) { configuration.title; configuration.icon }.font(.system(size: 13, weight: .medium)) }
}

// MARK: - Cards and rows

struct ArtChip: View {
    let status: ArtStatus
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status == .approved ? "checkmark.circle.fill" : status == .needsArtwork ? "circle" : "circle.fill")
                .font(.system(size: status == .approved || status == .needsArtwork ? 12 : 8)).foregroundStyle(status.color)
            Text(status.label).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.benchInk)
        }
        .padding(.horizontal, 9).frame(height: 22)
        .background(Color.benchRaised, in: Capsule()).overlay(Capsule().stroke(Color.benchLine))
    }
}
struct AudioChip: View {
    let status: AudioStatus
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform").font(.system(size: 11))
            Text(status.label).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }.foregroundStyle(status.color)
    }
}
/// A ring on the beat the recording is on. Its own view, so only the ring redraws as the audio plays.
struct BenchNowRing: View {
    @EnvironmentObject var listener: Listener
    let e: Episode; let n: Int; var corner: CGFloat = 10
    var body: some View {
        if listener.playing && listener.nowBeat(e) == n {
            RoundedRectangle(cornerRadius: corner).stroke(Color.benchGreen, lineWidth: 2).allowsHitTesting(false)
        }
    }
}

struct BeatPicture: View {
    @EnvironmentObject var store: Store
    let e: Episode; let b: Beat
    var body: some View {
        Color.clear.aspectRatio(16 / 9, contentMode: .fit).overlay {
            if let img = store.cardPicture(e, b) { FramedPicture(image: img, frame: store.shownFrame(e, b)) }
            else { ZStack { Color.benchRaised; Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(Color.benchMute) } }
        }.clipped()
    }
}

struct BeatMenu: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    let e: Episode; let b: Beat
    var body: some View {
        let done = store.isDone(store.keyBeat(e, b))
        Menu {
            Button("Play from this beat") { NotificationCenter.default.post(name: .beatsSeek, object: BeatsSeek(beat: b.n, start: true)) }
            Button(done ? "Remove approval" : "Approve") { store.setDone(store.keyBeat(e, b), !done) }
            if store.picture(e, b) != nil {
                Button("View full image") { nav.selected = b.n; withAnimation(.easeOut(duration: 0.2)) { nav.viewing = true } }
            }
        } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Color.benchSoft)
    }
}

struct BenchBeatCard: View {
    @EnvironmentObject var tm: TrailerModel
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat; let span: (Double, Double); let changed: Set<Int>
    @State var target = false
    var body: some View {
        let sel = nav.selected == b.n
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                BeatPickBox(e: e, b: b)
                Text("BEAT \(String(format: "%02d", b.n))").font(.system(size: 11, weight: .semibold)).tracking(0.8)
                Spacer()
                Text(benchClock(span.1 - span.0)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.benchSoft)
                BeatMenu(e: e, b: b)
            }.padding(.horizontal, 4)
            BeatPicture(e: e, b: b).clipShape(RoundedRectangle(cornerRadius: 5)).revealOnHover(store.pictureURL(e, b))
                .overlay(alignment: .bottomLeading) { SceneRunBadge(kie: tm.kie, id: store.genID(e, b)).padding(6) }
            Text(b.text).font(.bench(14)).lineSpacing(2).lineLimit(2, reservesSpace: true).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .topLeading).padding(.horizontal, 4)
            Rectangle().fill(Color.benchLine.opacity(0.6)).frame(height: 1)
            HStack(spacing: 10) {
                ArtChip(status: store.artStatus(e, b))
                Rectangle().fill(Color.benchLine).frame(width: 1, height: 14)
                AudioChip(status: store.audioStatus(e, b, changed: changed))
                Spacer(minLength: 0)
            }
            BeatCardGenerate(e: e, b: b).frame(minHeight: 22)
        }
        .padding(10)
        .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(sel || target ? Color.benchBlue : Color.benchLine, lineWidth: sel || target ? 2 : 1))
        .overlay(BenchNowRing(e: e, n: b.n))
        .contentShape(Rectangle())
        .onTapGesture { nav.selected = b.n; nav.drawer = .beat; nav.inspector = true }
        .fileDrop(targeted: $target) { store.setImage(store.sceneKey(e, b) ?? store.keyImg(e, store.primaryId(e, b)), from: $0) }
        .help("Drop an image here")
    }
}

struct BeatRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat; let span: (Double, Double); let changed: Set<Int>
    var body: some View {
        let sel = nav.selected == b.n
        HStack(spacing: 14) {
            BeatPickBox(e: e, b: b).frame(width: 16)
            Text(String(format: "%02d", b.n)).font(.bench(20)).frame(width: 34)
            Text(benchClock(span.0)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.benchSoft)
            Text(b.text).font(.bench(14)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            BeatPicture(e: e, b: b).frame(width: 110).clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 6) {
                ArtChip(status: store.artStatus(e, b))
                AudioChip(status: store.audioStatus(e, b, changed: changed))
            }.frame(width: 130, alignment: .leading)
            BeatCardGenerate(e: e, b: b).frame(width: 210, alignment: .leading)
            BeatMenu(e: e, b: b)
        }
        .padding(10)
        .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(sel ? Color.benchBlue : Color.benchLine, lineWidth: sel ? 2 : 1))
        .overlay(BenchNowRing(e: e, n: b.n))
        .contentShape(Rectangle())
        .onTapGesture { nav.selected = b.n; nav.drawer = .beat; nav.inspector = true }
    }
}

// MARK: - The beat panel: Shot, Artwork, Audio

struct BeatPanel: View {
    enum Page: String, CaseIterable { case shot = "Shot", artwork = "Artwork", audio = "Audio" }
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat; let span: (Double, Double); let changed: Set<Int>
    @State var page = Page.shot
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Beat \(String(format: "%02d", b.n))").font(.bench(22))
                    Spacer()
                    BeatMenu(e: e, b: b)
                }
                HStack(spacing: 2) {
                    ForEach(Page.allCases, id: \.self) { p in
                        Button { page = p } label: {
                            Text(p.rawValue).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 26)
                                .background(page == p ? Color.benchBlue : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(page == p ? Color.white : Color.benchSoft)
                    }
                }.padding(2).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
                switch page {
                case .shot: ShotPage(e: e, b: b, span: span)
                case .artwork: ArtworkPage(e: e, b: b)
                case .audio: AudioPage(e: e, b: b, span: span, changed: changed)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(Color.benchPanel)
    }
}

struct PanelRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.benchSoft).frame(width: 100, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ShotPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    @EnvironmentObject var listener: Listener
    let e: Episode; let b: Beat; let span: (Double, Double)
    var beforeTimeChange: (() -> Void)? = nil
    @State var draft = ""
    @FocusState var typing: Bool
    @State var durationDraft = ""
    @FocusState var typingDuration: Bool

    /// The cast named in what this beat shows.
    var people: [Person] {
        let what = (store.storyboard(e, b)?.zooms?[String(b.n)]?.look ?? "") + " " + b.what
        return (store.season?.cast ?? []).filter { p in
            guard let last = p.name.split(separator: " ").last else { return false }   // "Chef Laurent Voss" is matched on Voss
            return what.contains(String(last))
        }
    }
    var location: (name: String, plate: String?)? {
        guard let s = store.storyboard(e, b) else { return nil }
        if let k = s.plateKey { return (store.plates.first { $0.id == k }?.name ?? k, k) }
        if let r = s.ref { return (URL(fileURLWithPath: r).deletingPathExtension().lastPathComponent, nil) }
        return nil
    }
    var shared: [Int] { store.sharedBeats(e, b) }

    var body: some View {
        let s = store.suggestedMotions(e)[b.n], c = store.chosenMotion(e, b)
        let f = store.shownFrame(e, b)
        VStack(alignment: .leading, spacing: 12) {
            if let img = store.picture(e, b) { FrameEditor(e: e, b: b, image: img) }
            else { BeatPicture(e: e, b: b).clipShape(RoundedRectangle(cornerRadius: 6)) }

            Text("Script").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
            TextEditor(text: $draft).font(.system(size: 13)).scrollContentBackground(.hidden).focused($typing)
                .padding(6).frame(height: 76)
                .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(typing ? Color.benchBlue : Color.benchLine))
            if draft != b.text && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack {
                    Button("Save line") { _ = store.saveScript(e, "[\(b.n)] \(draft)"); typing = false }.buttonStyle(.borderedProminent).tint(.benchBlue).controlSize(.small)
                    Button("Cancel") { draft = b.text; typing = false }.controlSize(.small)
                }
            }

            PanelRow(label: "Framing") {
                Text(f.map { $0.scale > 1.01 ? String(format: "Zoom %.1f×", $0.scale) : "Whole picture" } ?? "Whole picture").font(.system(size: 12))
            }
            PanelRow(label: "Camera move") {
                Picker("", selection: Binding(get: { c?.move }, set: { store.setMotion(e, b, move: .some($0)) })) {
                    Text("Auto · \(s?.move?.label ?? "")").tag(Move?.none)
                    Divider()
                    ForEach(Move.allCases, id: \.self) { Text($0.label).tag(Move?.some($0)) }
                }.labelsHidden()
            }
            if let img = store.picture(e, b) { framingEnds(img, frame: f) }
            PanelRow(label: "Transition") {
                Picker("", selection: Binding(get: { c?.transition }, set: { store.setMotion(e, b, transition: .some($0)) })) {
                    Text("Auto · \(s?.transition?.label ?? "")").tag(Transition?.none)
                    Divider()
                    ForEach(Transition.allCases, id: \.self) { Text($0.label).tag(Transition?.some($0)) }
                }.labelsHidden()
            }
            PanelRow(label: "Duration") {
                if store.canMoveCuts(e) {
                    HStack(spacing: 6) {
                        TextField("", text: $durationDraft).textFieldStyle(.roundedBorder).font(.system(size: 12).monospacedDigit())
                            .multilineTextAlignment(.trailing).frame(width: 58).focused($typingDuration)
                            .onSubmit { commitDuration() }
                        Text("s").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                        Stepper("", onIncrement: { setDuration(span.1 - span.0 + 0.1) }, onDecrement: { setDuration(span.1 - span.0 - 0.1) }).labelsHidden()
                    }
                    .help("How long this picture stays up. The next picture comes in that much earlier or later.")
                } else {
                    Text(String(format: "%.1f s", span.1 - span.0)).font(.system(size: 12).monospacedDigit())
                }
            }

            Button { nav.inspector = false; player.open(e, store: store, at: b.n); nav.path.append(.readThrough(e.n)) } label: {
                Label("Preview shot", systemImage: "play.fill").frame(maxWidth: .infinity)
            }.controlSize(.large)

            if !people.isEmpty || location != nil {
                Rectangle().fill(Color.benchLine).frame(height: 1)
                Text("Reference").font(.system(size: 13, weight: .semibold))
                ForEach(people) { p in
                    referenceRow(p.name, "Character", image: store.cardImage("cast:\(p.name)") ?? castArt(p)) { nav.go(.cast) }
                }
                if let l = location {
                    referenceRow(l.name, "Location", image: l.plate.flatMap { store.plateShownKey($0) }.flatMap { store.cardImage($0) }) {
                        if let k = l.plate { nav.path.append(.plate(k)) } else { nav.go(.locations) }
                    }
                }
            }
            if !shared.isEmpty {
                Text("Used in \(shared.count + 1) beats").font(.system(size: 12, weight: .medium)).foregroundStyle(Color.benchBlue)
                FlowRow(items: shared) { n in
                    Button(String(format: "%02d", n)) { nav.selected = n; nav.scrollTo = n }.controlSize(.small)
                }
            }
        }
        .onAppear { draft = b.text; durationDraft = durationText }
        .onChange(of: b.text) { _, t in draft = t }
        .onChange(of: typing) { _, t in nav.typing = t }
        .onChange(of: span.1 - span.0) { _, _ in if !typingDuration { durationDraft = durationText } }
        .onChange(of: typingDuration) { _, t in nav.typing = t; if !t { commitDuration() } }
        .onDisappear { nav.typing = false }
    }

    var durationText: String { String(format: "%.1f", span.1 - span.0) }
    func commitDuration() {
        if let d = Double(durationDraft.replacingOccurrences(of: "s", with: "").trimmingCharacters(in: .whitespaces)), durationText != durationDraft { setDuration(d) }
        else { durationDraft = durationText }
    }
    /// This beat runs for `d` seconds: its end moves, and the next beat comes in there. It can't run past the next beat's end or the recording's.
    func setDuration(_ d: Double) {
        let times = store.beatTimes(e, duration: store.estimatedLength(e))
        guard let i = e.beats.firstIndex(where: { $0.n == b.n }), times.indices.contains(i) else { return }
        let latest = i + 1 < times.count ? times[i + 1].1 - 0.1 : max(store.estimatedLength(e), times[i].1)
        let end = min(latest, max(times[i].0 + 0.1, times[i].0 + d))
        guard abs(end - times[i].1) >= 0.01 else { durationDraft = durationText; return }
        beforeTimeChange?()
        store.setBeatTime(e, b.n, end: end)
        listener.refreshTimes(e)
        durationDraft = String(format: "%.1f", end - times[i].0)
    }

    /// Where the camera move starts and ends on this picture. The end is the framing set above.
    func framingEnds(_ img: Image, frame f: BeatFrame?) -> some View {
        let i = e.beats.firstIndex { $0.n == b.n } ?? 0
        let before = i > 0 ? store.shownFrame(e, e.beats[i - 1]) : nil
        let ends = MovingPicture(image: img, frame: f ?? BeatFrame(), from: before, move: store.motion(e, b).move, p: 0).ends
        func thumb(_ label: String, _ frame: BeatFrame) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                FramedPicture(image: img, frame: frame).aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.benchLine))
            }
        }
        return HStack(alignment: .bottom, spacing: 8) {
            thumb("Start framing", ends.0)
            Image(systemName: "chevron.right.2").font(.system(size: 11)).foregroundStyle(Color.benchSoft).padding(.bottom, 24)
            thumb("End framing", ends.1)
        }
    }

    func castArt(_ p: Person) -> Image? {
        store.designFolder(p.name).flatMap { store.characterArt($0) }
    }
    func referenceRow(_ title: String, _ kind: String, image: Image?, _ open: @escaping () -> Void) -> some View {
        Button(action: open) {
            HStack(spacing: 10) {
                ZStack {
                    Color.benchRaised
                    if let image { image.resizable().scaledToFill() } else { Image(systemName: kind == "Character" ? "person" : "map").foregroundStyle(Color.benchMute) }
                }.frame(width: 52, height: 36).clipShape(RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(kind).font(.system(size: 11)).foregroundStyle(Color.benchSoft)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Color.benchSoft)
            }
            .padding(8).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// The picture's slots, prompts and options: what the old panel had under the picture.
struct ArtworkPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat
    var body: some View {
        let board = store.storyboard(e, b), pid = store.primaryId(e, b)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ArtChip(status: store.artStatus(e, b))
                Spacer()
                DoneToggle(key: store.keyBeat(e, b))
            }
            BeatGenerateButtons(e: e, b: b)
            if store.picture(e, b) != nil {
                HStack(spacing: 8) {
                    Button { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = true } } label: {
                        Label("View full image", systemImage: "arrow.up.left.and.arrow.down.right")
                    }.controlSize(.small)
                    RemoveImageButton(e: e, b: b)
                }
            }
            HStack(spacing: 8) {
                if let sb = board { DropZone(title: "Every beat in scene \(sb.id)", key: store.sceneKey(e, sb)) }
                else { DropZone(title: "Every beat using \(pid)", key: store.keyImg(e, pid)) }
                DropZone(title: "This beat only", key: store.keyBeat(e, b))
            }
            if let s = board {
                if let img = store.picture(e, b), s.beats.count > 1 || s.zooms?[String(b.n)]?.frame != nil { ZoomMap(e: e, s: s, current: b.n, image: img) }
                StoryboardBox(s: s, beat: b.n, e: e)
            } else {
                Box(title: "What you see") {
                    Text(b.what).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(Store.ids(b.img), id: \.self) { id in
                if let s = store.stillFor(e, id: id) {
                    Box(title: "Still \(s.id) · \(s.name)", titleColor: .benchBlue) {
                        ForEach(0..<s.choices.count, id: \.self) { i in OptionRow(e: e, s: s, i: i) }
                    }
                }
            }
        }
    }
}

struct AudioPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat; let span: (Double, Double); let changed: Set<Int>
    @State var showScript = false
    var body: some View {
        let status = store.audioStatus(e, b, changed: changed)
        let has = store.audioURL(e) != nil, own = store.isOwnAudio(e)
        VStack(alignment: .leading, spacing: 12) {
            AudioChip(status: status)
            if changed.contains(b.n), store.recordedLine(e, b.n) == b.text {
                Text("The script line hasn't changed, but the words heard in the recording don't match it.").font(.system(size: 12)).foregroundStyle(Color.benchSoft).fixedSize(horizontal: false, vertical: true)
                lineBox(b.text)
            } else if changed.contains(b.n), let rec = store.recordedLine(e, b.n) {
                Text("Recorded line").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                lineBox(rec)
                Text("Current script").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                lineBox(b.text)
            }
            PanelRow(label: "Recording") { Text(has ? (own ? "Your recording" : "Original voiceover") : "None yet").font(.system(size: 12)) }
            PanelRow(label: "Start time") { Text(benchClock(span.0)).font(.system(size: 12).monospacedDigit()) }
            PanelRow(label: "End time") { Text(benchClock(span.1)).font(.system(size: 12).monospacedDigit()) }
            if let note = store.syncing[e.n] ?? store.state.syncNotes?["e\(e.n)"] {
                Text(note).font(.system(size: 11)).foregroundStyle(Color.benchSoft).fixedSize(horizontal: false, vertical: true)
            }
            PlayBeatButton(e: e, b: b).tint(.benchBlue)
            if has {
                Button { Task { await store.syncBeats(e) } } label: { Label("Sync beats", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity) }
                    .disabled(store.syncing[e.n] != nil)
                    .help("Listen to the recording on this Mac and line every beat up with where its words are said.")
            }
            Button { nav.choose([.audio]) { store.setAudio(e, from: $0) } } label: {
                Label(has ? "Replace recording…" : "Choose MP3…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity)
            }
            Button { showScript = true } label: { Label("Edit script…", systemImage: "pencil").frame(maxWidth: .infinity) }
            if own {
                Button(role: .destructive) { store.removeAudio(e) } label: { Label("Remove my recording", systemImage: "trash").frame(maxWidth: .infinity) }
            }
        }
        .controlSize(.regular)
        .sheet(isPresented: $showScript) { ScriptSheet(e: e) }
    }
    func lineBox(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
    }
}

// MARK: - The bottom player: transport, waveform, volume, filmstrip

struct BeatsSeek { let beat: Int; let start: Bool }

struct BeatsPlayer: View {
    let e: Episode; let times: [(Double, Double)]
    var body: some View {
        VStack(spacing: 8) {
            BeatsTransport(e: e, times: times)
            BeatsFilmstrip(e: e)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.benchPanel)
    }
}

/// Its own view, so only this row redraws as the audio plays.
struct BeatsTransport: View {
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let times: [(Double, Double)]
    @State var peaks: [Float] = []
    var here: Bool { listener.ep == e.n }
    var body: some View {
        let len = max(listener.length(e), 0.1)
        let i = e.beats.firstIndex { $0.n == nav.selected } ?? 0
        let t = here ? listener.time : (times.indices.contains(i) ? times[i].0 : 0)
        let status = store.episodeAudioStatus(e)
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                step("backward.end.fill", "Previous beat", -1)
                Button { listener.toggle(e, from: nav.selected) } label: {
                    Image(systemName: here && listener.playing ? "pause.fill" : "play.fill").font(.system(size: 14))
                        .frame(width: 36, height: 36).background(Color.benchBlue, in: Circle()).foregroundStyle(.white).contentShape(Circle())
                }.buttonStyle(.plain).help("Play or pause (Space)")
                step("forward.end.fill", "Next beat", 1)
            }
            Text("\(benchClock(t)) / \(benchClock(len))").font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.benchInk).fixedSize()
            BeatsWaveform(peaks: peaks, progress: t / len) { f in
                if here { listener.seek(f * len) } else { listener.play(e, at: f * len) }
            }
            .frame(height: 34)
            Rectangle().fill(Color.benchLine).frame(width: 1, height: 24)
            HStack(spacing: 6) {
                Image(systemName: status == .synced ? "checkmark.circle.fill" : "circle.fill").font(.system(size: status == .synced ? 13 : 8))
                    .foregroundStyle(status == .synced ? Color.benchGreen : status.color)
                Text(status == .synced ? "Voiceover synced" : status == .unsynced ? "Voiceover not synced" : "No voiceover").font(.system(size: 11))
            }.fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Color.benchSoft)
                Slider(value: Binding(get: { Double(listener.volume) }, set: { listener.volume = Float($0) }), in: 0...1).frame(width: 80).controlSize(.mini).tint(.benchBlue)
            }
        }
        .task(id: store.audioURL(e)) {
            peaks = []
            if let u = store.audioURL(e) { peaks = await Waveforms.peaks(u) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .beatsSeek)) { note in
            guard let s = note.object as? BeatsSeek else { return }
            if s.start { listener.play(e, beat: s.beat) } else if here { seek(to: s.beat) }
        }
    }
    func seek(to n: Int) {
        if let j = e.beats.firstIndex(where: { $0.n == n }) { let bt = listener.beatTimes(e); if bt.indices.contains(j) { listener.seek(bt[j].0) } }
    }
    func step(_ icon: String, _ tip: String, _ d: Int) -> some View {
        Button {
            guard !e.beats.isEmpty else { return }
            let i = e.beats.firstIndex { $0.n == nav.selected } ?? 0
            let j = min(e.beats.count - 1, max(0, i + d)), n = e.beats[j].n
            nav.selected = n; nav.scrollTo = n
            if here { seek(to: n) }
        } label: { Image(systemName: icon).font(.system(size: 13)).frame(width: 24, height: 24).contentShape(Rectangle()) }
        .buttonStyle(.plain).foregroundStyle(Color.benchInk).help(tip)
    }
}

struct BeatsWaveform: View {
    let peaks: [Float]; let progress: Double
    let seek: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            Canvas { c, size in
                let bars = max(1, Int(size.width / 3))
                let source = peaks.isEmpty ? [Float](repeating: 0.04, count: bars) : peaks
                let mid = size.height / 2
                for i in 0..<bars {
                    let v = CGFloat(source[min(source.count - 1, i * source.count / bars)])
                    let h = max(2, v * size.height), x = CGFloat(i) * 3
                    let played = Double(i) / Double(bars) <= progress
                    c.fill(Path(CGRect(x: x, y: mid - h / 2, width: 2, height: h)), with: .color(played ? .benchBlue : .benchMute))
                }
                let px = CGFloat(min(1, max(0, progress))) * size.width
                c.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.benchInk))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in seek(min(1, max(0, v.location.x / max(1, g.size.width)))) })
        }
    }
}

/// Peaks of a recording, read once on this Mac and kept for the session.
enum Waveforms {
    @MainActor static var cache: [String: [Float]] = [:]
    @MainActor static func peaks(_ url: URL, count: Int = 1200) async -> [Float] {
        let key = "\(url.path)#\(count)"
        if let c = cache[key] { return c }
        let out = await Task.detached(priority: .utility) { () -> [Float] in (try? await read(url, count: count)) ?? [] }.value
        if !out.isEmpty { cache[key] = out }
        return out
    }
    nonisolated static func read(_ url: URL, count: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let seconds = try await asset.load(.duration).seconds
        let rate = 8000.0
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate])
        reader.add(output)
        guard reader.startReading() else { return [] }
        let window = max(1, Int(seconds * rate) / count)
        var bars: [Float] = [], peak: Int16 = 0, n = 0
        bars.reserveCapacity(count + 1)
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0; var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr, let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { s in
                for i in 0..<(length / 2) {
                    let v = s[i] == Int16.min ? Int16.max : abs(s[i])
                    if v > peak { peak = v }
                    n += 1
                    if n >= window { bars.append(Float(peak)); peak = 0; n = 0 }
                }
            }
        }
        guard let top = bars.max(), top > 0 else { return [] }
        return bars.map { $0 / top }
    }
}

struct BeatsFilmstrip: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 4) {
                    ForEach(e.beats) { b in
                        let sel = nav.selected == b.n
                        BeatPicture(e: e, b: b).frame(height: 52).clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(sel ? Color.benchBlue : .clear, lineWidth: 2))
                            .overlay(BenchNowRing(e: e, n: b.n, corner: 4))
                            .contentShape(Rectangle())
                            .onTapGesture {
                                nav.selected = b.n; nav.scrollTo = b.n; nav.drawer = .beat; nav.inspector = true
                                NotificationCenter.default.post(name: .beatsSeek, object: BeatsSeek(beat: b.n, start: false))
                            }
                            .help("Beat \(b.n)")
                            .id(b.n)
                    }
                }.padding(2)
            }
            .frame(height: 56)
            .scrollIndicators(.never)
            .onChange(of: nav.selected) { _, v in if let v { withAnimation { proxy.scrollTo(v, anchor: .center) } } }
        }
    }
}

// MARK: - Off-screen check

/// `-beats-test <folder>`: draws the Beats page into a window that is never shown, saves pictures and quits.
enum BeatsTest {
    @MainActor static func run(_ dir: URL) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Store.listensForWords = false
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // a throwaway settings suite: this check never touches your project list or open folder
        let suite = "beats-test-suite"; UserDefaults().removePersistentDomain(forName: suite)
        Store.defaults = UserDefaults(suiteName: suite) ?? .standard
        let store = Store(), nav = Nav(), hover = Hover(), exporter = VideoExporter(), player = Player(), listener = Listener(), tm = TrailerModel()
        listener.store = store
        guard let season = store.season else { try? "no season".write(to: dir.appendingPathComponent("error.txt"), atomically: true, encoding: .utf8); exit(3) }
        nav.tab = .ep; nav.ep = 1; nav.selected = 5; nav.inspector = true
        let page = NavigationStack { BeatsPage(season: season, n: 1, isRoot: true) }
            .environmentObject(store).environmentObject(nav).environmentObject(hover).environmentObject(exporter)
            .environmentObject(player).environmentObject(listener).environmentObject(tm).preferredColorScheme(.dark)
        let host = NSHostingView(rootView: page)
        host.frame = NSRect(x: 0, y: 0, width: 1300, height: 860)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func save(_ name: String) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        }
        var lines0: [String] = []
        spin(4); save("beats-ep1.png")
        nav.selected = 2; spin(2); save("beats-ep1-beat2.png")
        let ep = season.eps[0], beat = ep.beats[54], none = Set(store.changedSinceRecording(ep))
        func extra<V: View>(_ v: V, _ name: String, _ w: CGFloat, _ h: CGFloat, wait: Double = 2) {
            let h2 = NSHostingView(rootView: v.environmentObject(store).environmentObject(nav).environmentObject(hover).environmentObject(exporter)
                .environmentObject(player).environmentObject(listener).environmentObject(tm).foregroundStyle(Color.benchInk).preferredColorScheme(.dark))
            h2.frame = NSRect(x: 0, y: 0, width: w, height: h)
            let wn = NSWindow(contentRect: h2.frame, styleMask: [.borderless], backing: .buffered, defer: false); wn.contentView = h2
            spin(wait); h2.layoutSubtreeIfNeeded()
            if let rep = h2.bitmapImageRepForCachingDisplay(in: h2.bounds) { h2.cacheDisplay(in: h2.bounds, to: rep); try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name)) }
        }
        if let k = ProcessInfo.processInfo.arguments.firstIndex(of: "-tall-test") {
            let src = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[k + 1]); var finished = false
            Task { await exporter.makeTall(from: src); finished = true }
            let t0 = Date(); while !finished && Date().timeIntervalSince(t0) < 120 { spin(0.5) }
            try? "finished \(finished), status \(exporter.status), output \(exporter.output?.path ?? "none"), progress \(exporter.progress)".write(to: dir.appendingPathComponent("tall.txt"), atomically: true, encoding: .utf8)
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("-episode-compare") {
            // works out what picking these beats would send, and shows it. Nothing runs.
            let e1p = season.eps[0], few = e1p.beats.filter { [1, 2, 9].contains($0.n) }
            let got = store.pickedJobs(e1p, few)
            try? "picked \(few.map(\.n)): pictures \(got.pictures), bw \(got.bw.map(\.shot)), color \(got.color.map(\.shot)), kie running \(tm.kie.running.count)".write(to: dir.appendingPathComponent("picks.txt"), atomically: true, encoding: .utf8)
            tm.beatPicks = Set(few.map(\.n)); nav.selected = 1
            extra(NavigationStack { BeatsPage(season: season, n: 1, isRoot: true) }, "picks-e1.png", 1300, 860, wait: 4)
            tm.beatPicks = []
            for n in [1, 2] {
                nav.ep = n; nav.selected = 5
                extra(NavigationStack { BeatsPage(season: season, n: n, isRoot: true) }, "cmp-beats-e\(n).png", 1300, 860, wait: 4)
                extra(NavigationStack { ScriptPage(season: season, n: n, isRoot: true) }, "cmp-script-e\(n).png", 1300, 860, wait: 3)
                extra(NavigationStack { EditPage(season: season, n: n, isRoot: true) }, "cmp-edit-e\(n).png", 1300, 860, wait: 5)
            }
            exit(0)
        }
        if ProcessInfo.processInfo.arguments.contains("-season-concepts") {
            nav.tab = .season
            extra(SeasonConceptPage(season: season, variant: 1), "season-A-filmstrips.png", 1440, 1240, wait: 6)
            extra(SeasonConceptPage(season: season, variant: 2), "season-B-beat-map.png", 1440, 1240, wait: 6)
            extra(SeasonConceptPage(season: season, variant: 3), "season-C-rings.png", 1440, 1240, wait: 6)
            extra(SeasonConceptPage(season: season, variant: 4), "season-D-timeline.png", 1440, 1240, wait: 6)
            extra(SeasonConceptPage(season: season, variant: 5), "season-E-scenes.png", 1440, 2300, wait: 8)
            extra(SeasonConceptPage(season: season, variant: 6), "season-F-posters.png", 1440, 1300, wait: 6)
            exit(0)
        }
        extra(BeatPanel(e: ep, b: beat, span: (0, 4), changed: none, page: .artwork), "panel-artwork.png", 360, 860)
        extra(BeatPanel(e: ep, b: beat, span: (0, 4), changed: none, page: .audio), "panel-audio.png", 360, 860)
        extra(NavigationStack { BeatsPage(season: season, n: 1, isRoot: true, asList: true) }, "beats-list.png", 1300, 860)
        // generate from beats: the jobs only. Nothing is ever started here.
        if let ep2 = season.eps.first(where: { $0.n == 2 }) {
            var c: [String: Int] = [:]
            for b in ep2.beats { c[store.sceneArt(ep2, b) != nil ? "generate" : (store.noGenerateReason(ep2, b) ?? "?").prefix(20).description, default: 0] += 1 }
            lines0.append("ep2 beats: \(c)")
            var seen = Set<String>()
            for a in ep2.beats.compactMap({ store.sceneArt(ep2, $0) }) where seen.insert(a.id).inserted {
                let j = store.bwJob(a), k = store.colorJob(a)
                lines0.append("job \(a.id) beats \(a.beats.count) plate \(a.scenes ?? 0): bw \(j.res) \(j.credits)cr refs \(j.refs.map(\.name)) -> \(j.out.lastPathComponent); color \(k.map { "\($0.res) \($0.credits)cr master \($0.prompt == Store.colorMaster) refs \($0.refs.map(\.name))" } ?? "needs sketch")")
            }
            if let b = ep2.beats.first(where: { store.sceneArt(ep2, $0) != nil }), let pose = ep2.beats.first(where: { store.storyboard(ep2, $0)?.isPoseDrop == true }) {
                nav.selected = b.n
                extra(BeatPanel(e: ep2, b: b, span: (0, 4), changed: none, page: .artwork), "panel-generate.png", 360, 860)
                extra(BeatPanel(e: ep2, b: pose, span: (0, 4), changed: none, page: .artwork), "panel-pose.png", 360, 860)
                tm.beatPicks = Set(ep2.beats.filter { store.sceneArt(ep2, $0) != nil }.prefix(3).map(\.n) + [pose.n])
                extra(NavigationStack { BeatsPage(season: season, n: 2, isRoot: true) }, "beats-picked.png", 1300, 860)
                extra(BeatGenerateBar(e: ep2), "bar.png", 900, 60)
                tm.beatPicks = []
                extra(NavigationStack { BeatsPage(season: season, n: 2, isRoot: true, cardSize: 240) }, "beats-small-cards.png", 1300, 860)
                extra(NavigationStack { BeatsPage(season: season, n: 2, isRoot: true, asList: true) }, "beats-list-ep2.png", 1300, 860)
                extra(NavigationStack { BeatsPage(season: season, n: 1, isRoot: true) }, "beats-ep1.png", 1300, 860)
                let e1 = season.eps[0], b4 = e1.beats[3], b3 = e1.beats[2]
                extra(BeatPromptSheet(e: e1, b: b3), "prompt-sheet-b3.png", 760, 680)
                extra(BeatPanel(e: e1, b: b4, span: (0, 4), changed: none, page: .artwork), "panel-ep1.png", 360, 860)
                let j4 = store.ownBWJob(e1, b4, prompt: store.ownPrompt(e1, b4), refs: store.ownRefs(e1, b3))
                lines0.append("own: ep1 buttons \(e1.beats.count), scene \(e1.beats.filter { store.sceneArt(e1, $0) != nil }.count); b3 refs \(store.ownRefs(e1, b3).map(\.name)); job \(j4.id) \(j4.res) \(j4.credits)cr \(j4.out.lastPathComponent) slot \(j4.stateKey ?? "?") starts \(j4.prompt.prefix(60)) ends \(j4.prompt.suffix(90)); color \(store.ownColorJob(e1, b4) == nil ? "needs sketch" : "ready")")
                let art = store.sceneArt(ep2, b)!
                extra(GenConfirmSheet(jobs: [store.bwJob(art)]), "confirm-sheet.png", 760, 640)
                tm.beatPicks = []
            }
        }
        nav.selected = 5; spin(0.5)
        nav.tab = .ep; nav.ep = 1
        extra(NavigationStack { ScriptPage(season: season, n: 1, isRoot: true) }, "script-ep1.png", 1300, 860)
        nav.selected = 55
        extra(NavigationStack { ScriptPage(season: season, n: 1, isRoot: true) }, "script-b55.png", 1300, 860)
        extra(NavigationStack { ScriptPage(season: season, n: 1, isRoot: true, find: "Voss") }, "script-find.png", 1300, 860)
        extra(NavigationStack { ScriptPage(season: season, n: 1, isRoot: true, panel: .picture) }, "script-picture.png", 1300, 860)
        extra(NavigationStack { ScriptPage(season: season, n: 1, isRoot: true, collapsed: [0]) }, "script-collapsed.png", 1300, 860)
        lines0.append("script: words \(season.eps[0].beats.map(\.wordCount).reduce(0, +)), stored \(season.eps[0].words), b55 recorded same \(store.recordedLine(season.eps[0], 55) == season.eps[0].beats.first { $0.n == 55 }?.text), heard \(store.heardLine(season.eps[0], 55) ?? "none")")
        nav.selected = 5; spin(0.3)
        extra(NavigationStack { EditPage(season: season, n: 1, isRoot: true) }, "edit-ep1.png", 1300, 860, wait: 8)
        if ProcessInfo.processInfo.arguments.contains("-edit-only") {
            var r1 = KieRun(title: "GPT · 4K · 16:9", status: "Kie is making it"); r1.step = 2; r1.started = Date().addingTimeInterval(-74)
            var r2 = KieRun(title: "Nano Banana · 1K · 16:9", status: "Uploading image 1 of 2"); r2.started = Date().addingTimeInterval(-5)
            var r3 = KieRun(title: "GPT · 1K · 16:9", status: "Kie is making it"); r3.step = 2; r3.percent = 40; r3.started = Date().addingTimeInterval(-30)
            KieStudio.shared.runs = [r1, r2, r3]
            extra(KieTab(), "kie-progress.png", 1180, 860)
            KieStudio.shared.runs = []
            if let f = KieStudio.shared.results.first.flatMap({ KieStudio.shared.url($0) }) { KieStudio.shared.refs = [f] }
            extra(KieRefPicker(studio: KieStudio.shared), "kie-ref-picker.png", 440, 480)
            extra(KieTab(), "kie-refs.png", 1180, 860)
            KieStudio.shared.shown = KieStudio.shared.shownResults.dropFirst(2).first
            extra(KieTab(gallery: true), "kie-gallery-arrows.png", 1180, 860, wait: 4)
            KieStudio.shared.refs = []
            extra(NavigationStack { EditPage(season: season, n: 1, isRoot: true, pictureHeight: 124) }, "edit-large.png", 1300, 860, wait: 6)
            extra(NavigationStack { EditPage(season: season, n: 1, isRoot: true, pictureHeight: 330) }, "edit-tall.png", 1300, 860, wait: 6)
            extra(NavigationStack { EditPage(season: season, n: 1, isRoot: true, pictureHeight: 330) }, "edit-tall-small-window.png", 1000, 620, wait: 6)
            exit(0)
        }
        nav.selected = 55
        extra(NavigationStack { EditPage(season: season, n: 1, isRoot: true, pps: 140) }, "edit-zoomed.png", 1300, 860, wait: 8)
        extra(NavigationStack { EditPage(season: season, n: 1, isRoot: true, pps: 30, inspectorPage: .audio) }, "edit-out.png", 1300, 860, wait: 8)
        if let ep2 = season.eps.first(where: { $0.n == 2 }) { extra(NavigationStack { EditPage(season: season, n: 2, isRoot: true) }, "edit-ep2.png", 1300, 860) }
        nav.selected = 5; spin(0.3)
        extra(EditPanel(e: season.eps[0], b: season.eps[0].beats[4], span: (24.9, 29.0), changed: [], page: .shot), "panel-shot-tall.png", 340, 1250)
        extra(BenchSidebar(), "sidebar.png", 250, 860)
        KieStudio.shared.prompt = "A test prompt. Nothing is sent."
        extra(KieTab(), "kie.png", 1180, 860)
        extra(KieTab(gallery: true), "kie-gallery.png", 1180, 860)
        KieStudio.shared.prompt = ""; 
        // a new project in the test folder, opened, then back to the real one
        let kitchen = store.currentProject!
        let (made, why) = store.createProject(name: "Test Show", season: "Season 1", parent: dir)
        lines0.append("created: \(made?.name ?? why ?? "?") eps \(made.map { store.projectEpisodes[$0.id] ?? -1 } ?? -1)")
        if let made {
            nav.open(made, store: store, listener: listener, trailer: tm); spin(1)
            lines0.append("opened: season \(store.season != nil), eps \(store.season?.eps.count ?? -1), images \(store.state.images.count), tab \(nav.tab.rawValue), hasTrailer \(store.hasTrailer), kitchen \(store.kitchen.lastPathComponent)")
            extra(BenchSidebar(), "sidebar-newproject.png", 250, 860)
            lines0.append("add: char \(store.addCharacter(name: "Test Hero", look: "Tall, with a red coat.") ?? "ok"), again \(store.addCharacter(name: "test hero", look: "") ?? "ok"), dish \(store.addDish(name: "Test Soup", look: "A bowl of soup.") ?? "ok"), cast \(store.season?.cast.count ?? -1), food \(store.season?.food.count ?? -1)")
            let logo = Store.kitchenFolder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("ART/Logos/Against the Grain - Season 1 Logo.png")
            lines0.append("add location: \(store.addLocation(name: "Test Room", pictures: [logo]) ?? "ok"), empty name \(store.addLocation(name: " ", pictures: [logo]) ?? "ok")")
            extra(KieTab(), "kie-from-other-project.png", 1180, 860)
            lines0.append("kie in other project: \(KieStudio.shared.folder?.path ?? "none"), pictures \(KieStudio.shared.results.count)")
            extra(NavigationStack { CastView(season: store.season!) }, "cast-new.png", 1100, 760)
            extra(NavigationStack { FoodView(season: store.season!) }, "food-new.png", 1100, 620)
            extra(NavigationStack { LocationsView(season: store.season!) }, "locations-new.png", 1100, 620)
            var shown = made; shown.hideFood = false; store.updateProject(shown); spin(0.2)
            lines0.append("food on: \(store.currentProject?.hideFood.map(String.init) ?? "nil"), truck hidden \(store.currentProject?.hideTruck.map(String.init) ?? "nil")")
            extra(NavigationStack { SeasonView(season: store.season!) }, "season-empty.png", 900, 500)
            let (epN, epWhy) = store.createEpisode(title: "The First One")
            lines0.append("new episode: \(epN.map(String.init) ?? epWhy ?? "?") count \(store.projectEpisodes[made.id] ?? -1)")
            if let epN {
                nav.go(.ep, ep: epN); spin(0.5)
                extra(NavigationStack { EpisodeStage(season: store.season!, n: epN, isRoot: true) }, "episode-empty.png", 1100, 700)
                extra(NavigationStack { SeasonView(season: store.season!) }, "season-one.png", 900, 500)
                extra(BenchSidebar(), "sidebar-newepisode.png", 250, 860)
                let empty = store.season!.eps.first { $0.n == epN }!
                let (b1, why1) = store.addBeat(to: empty, text: "The first line of the show.")
                let (b2, _) = store.addBeat(to: store.season!.eps.first { $0.n == epN }!, text: "The second line,\nwith a line break.")
                let shown = store.season!.eps.first { $0.n == epN }!
                lines0.append("beats added: \(b1.map(String.init) ?? why1 ?? "?"), \(b2.map(String.init) ?? "?"); words \(shown.words); text2 \(shown.beats.last?.text ?? "")")
                nav.selected = b1
                extra(NavigationStack { EpisodeStage(season: store.season!, n: epN, isRoot: true) }, "episode-beats.png", 1300, 860)
            }
            // the same on a copy of the real season file, so the real one can be compared afterward
            let (copy, _) = store.createProject(name: "Copy Show", season: "Season 1", parent: dir)
            if let copy {
                let real = Store.kitchenFolder.appendingPathComponent("_viewer/season.json"), to = URL(fileURLWithPath: copy.folder).appendingPathComponent("_viewer/season.json")
                try? FileManager.default.removeItem(at: to); try? FileManager.default.copyItem(at: real, to: to)
                nav.open(copy, store: store, listener: listener, trailer: tm); spin(0.5)
                // a finished picture going in its slot, on the copy: the old one is kept
                let fakeOld = store.userDir.appendingPathComponent("old-pic.png"), fakeNew = store.userDir.appendingPathComponent("scene_e2_TEST-kie.png")
                try? Data([1]).write(to: fakeOld); try? Data([2]).write(to: fakeNew)
                store.state.images["scene:e2:TEST"] = "old-pic.png"
                store.adoptGenerated("scene:e2:TEST", fakeNew)
                lines0.append("adopt: slot \(store.state.images["scene:e2:TEST"] ?? "?"), old kept \(FileManager.default.fileExists(atPath: store.userDir.appendingPathComponent("_previous/old-pic.png").path))")
                store.state.images["scene:e2:TEST"] = nil; store.save()
                // script edits, on the copy
                let c1 = store.season!.eps[0], c5 = c1.beats[4]
                let saved = store.saveLine(c1, 5, " I look at him.\n\"Heard, Chef.\" [3] "), same = store.saveLine(store.season!.eps[0], 5, store.season!.eps[0].beats[4].text), blank = store.saveLine(store.season!.eps[0], 5, "  ")
                let c1b = store.season!.eps[0]
                lines0.append("saveLine: \(saved) same \(same) blank \(blank), text \(c1b.beats[4].text), was \(c5.text), beat 3 untouched \(c1b.beats[2].text == c1.beats[2].text), flagged \(store.changedSinceRecording(c1b).contains(5))")
                let pv = store.previewScript(c1b, "[1] New first line.\n\n[2] \(c1b.beats[1].text)\n\n[999] Nope.")
                lines0.append("import preview: changed \(pv.changed), unknown \(pv.unknown), found \(pv.found); line 1 unsaved \(store.season!.eps[0].beats[0].text == c1b.beats[0].text); none \(store.previewScript(c1b, "plain words").found)")
                store.state.syncTimes = ["e1": c1b.beats.map { [Double($0.n), Double($0.n), Double($0.n) + 1] }]
                store.setBeatTime(c1b, 5, start: 4.7); store.setBeatTime(c1b, 5, end: 6.5); store.setBeatTime(c1b, 5, end: 99)
                let tt = store.state.syncTimes!["e1"]!
                lines0.append("alignment: b4 \(tt[3]), b5 \(tt[4]), b6 \(tt[5]), others same \(tt[9] == [10, 10, 11])")
                store.state.syncTimes = nil
                // a cut moved back into the line before: nothing new gets flagged, and the words stay where they are
                let realE1 = store.season!.eps[0]
                let heardCopy = (try? JSONDecoder().decode(UserState.self, from: Data(contentsOf: Store.kitchenFolder.appendingPathComponent("_viewer/user/state.json"))))
                store.state.heard = heardCopy?.heard; store.state.syncTimes = heardCopy?.syncTimes; store.state.alignedTimes = nil; store.state.lines = heardCopy?.lines; store.applyLineEdits()
                let e1c = store.season!.eps[0]; _ = realE1
                let flagsBefore = store.changedSinceRecording(e1c)
                let twStart = Date(); let tw = store.wordsInRecording(e1c); lines0.append("word line-up took \(String(format: "%.2f", Date().timeIntervalSince(twStart))) s")
                let b3 = store.beatTimes(e1c, duration: 500)[2]
                let midB3 = tw.filter { $0.t > b3.0 + 1 && $0.t < b3.1 }.first
                let wasSync = store.state.syncTimes?["e1"]
                if let midB3 { store.setBeatTime(e1c, 4, start: midB3.t - 0.15) }
                let afterT = store.beatTimes(e1c, duration: 500)
                lines0.append("cut move: word \(midB3?.text ?? "?") at \(midB3?.t ?? -1); b3 now \(afterT[2]) b4 now \(afterT[3]); flags \(flagsBefore) -> \(store.changedSinceRecording(e1c)); kept \(store.state.alignedTimes?["e1"] != nil)")
                store.restoreBeatTimes(e1c, wasSync)
                lines0.append("undo ok \(store.state.syncTimes?["e1"] == wasSync); words \(tw.count), in script \(tw.filter(\.inScript).count); sample \(tw.prefix(14).map(\.text).joined(separator: " ")); around 55 \(tw.filter { $0.t > 361 && $0.t < 366 }.map(\.text).joined(separator: " "))")
                store.state.syncTimes = nil; store.state.alignedTimes = nil; store.state.heard = nil; store.state.lines = nil; store.applyLineEdits()
                // re-timing Episode 1 on the copy, with the same recording and lines the real one uses. The real one isn't touched.
                if let realName = heardCopy?.audio["audio:e1"] {
                    store.state.lines = heardCopy?.lines; store.applyLineEdits()
                    let e1r = store.season!.eps[0], t0 = Date()
                    let name1 = "audio-e1-test.mp3"; try? FileManager.default.copyItem(at: Store.kitchenFolder.appendingPathComponent("_viewer/user").appendingPathComponent(realName), to: store.userDir.appendingPathComponent(name1))
                    store.state.audio["audio:e1"] = name1
                    var resynced = false
                    Task { await store.syncBeats(e1r); resynced = true }
                    while !resynced && Date().timeIntervalSince(t0) < 200 { spin(1) }
                    lines0.append("resync e1: \(Int(Date().timeIntervalSince(t0))) s, flags \(store.changedSinceRecording(store.season!.eps[0])), note \(store.state.syncNotes?["e1"] ?? "none"), method \(store.state.wordMethod?["e1"] ?? -1)")
                    if let d = try? JSONEncoder().encode(["sync": store.state.syncTimes?["e1"] ?? []]) { try? d.write(to: dir.appendingPathComponent("e1-sync.json")) }
                    if let d = try? JSONEncoder().encode(store.state.heard?["e1"] ?? []) { try? d.write(to: dir.appendingPathComponent("e1-heard.json")) }
                    store.removeAudio(store.season!.eps[0]); store.state.lines = nil; store.applyLineEdits()
                }
                // word times, on the copy: really listens to Episode 2's recording. No cut may move.
                let c2 = store.season!.eps[1], rel = c2.audio ?? ""
                let toMP3 = store.folder.appendingPathComponent(rel)
                try? FileManager.default.createDirectory(at: toMP3.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: Store.kitchenFolder.appendingPathComponent(rel), to: toMP3)
                store.state.syncTimes = heardCopy?.syncTimes
                let b3e2 = store.beatTimes(c2, duration: 500)[2]
                store.setBeatTime(c2, 4, start: b3e2.0 + 0.5)
                let cutsBefore = store.state.syncTimes?["e2"]
                let listenStart = Date(); var listened = false
                Task { await store.getWords(c2); listened = true }
                while !listened && Date().timeIntervalSince(listenStart) < 800 { spin(1) }
                let hc = store.state.heard?["e2"]?.count ?? -1
                lines0.append("getWords: done \(listened) in \(Int(Date().timeIntervalSince(listenStart))) s, heard \(hc), cuts unchanged \(store.state.syncTimes?["e2"] == cutsBefore), aligned \(store.state.alignedTimes?["e2"]?.count ?? -1), flags \(store.changedSinceRecording(c2)), syncing cleared \(store.syncing[2] == nil)")
                lines0.append("first words: \((store.state.heard?["e2"] ?? []).prefix(12).map { "\($0.w)@\($0.t)" }.joined(separator: " ")); method \(store.state.wordMethod?["e2"] ?? -1)")
                let cacheFile = store.wordCacheFile(c2); try? FileManager.default.removeItem(at: cacheFile)
                let sc = c2.beats.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }, hd = (store.state.heard?["e2"] ?? []).map { (w: $0.w, t: $0.t) }
                let t1 = Date(); let w1 = savedTimedWords(file: cacheFile, script: sc, heard: hd); let d1 = Date().timeIntervalSince(t1)
                let t2 = Date(); let w2 = savedTimedWords(file: cacheFile, script: sc, heard: hd); let d2 = Date().timeIntervalSince(t2)
                let w3 = savedTimedWords(file: cacheFile, script: sc + ["changed"], heard: hd)
                lines0.append(String(format: "cache: first %.2f s, second %.3f s, same \(w1.map(\.id) == w2.map(\.id)), count \(w1.count), script change redoes \(w3.count > 0)", d1, d2))
                let durBefore = store.beatTimes(c2, duration: 500)
                store.setBeatTime(c2, 10, end: durBefore[9].0 + 2.5)
                let durAfter = store.beatTimes(c2, duration: 500)
                lines0.append("duration: b10 \(durBefore[9]) -> \(durAfter[9]); b11 \(durBefore[10]) -> \(durAfter[10]); b12 same \(durBefore[11] == durAfter[11]); flags \(store.changedSinceRecording(c2))")
                try? FileManager.default.removeItem(at: toMP3); try? FileManager.default.removeItem(at: cacheFile)
                store.state.syncTimes = nil; store.state.alignedTimes = nil; store.state.heard = nil
                lines0.append("diff: \(store.addedWords(old: "Heard, Chef.", new: "I look at him. \"Heard, Chef.\""))")
                let (n2, why2) = store.createEpisode(title: "Eleven")
                let ep1 = store.season!.eps[0]
                let before = store.beatTimes(ep1, duration: store.estimatedLength(ep1)).map { "\($0)" }
                let synced = ep1.beats.map { [Double($0.n), Double($0.n), Double($0.n) + 1] }
                let (b71, _) = store.addBeat(to: ep1, text: "Added to a copy of the real episode.")
                let after1 = store.season!.eps[0]
                let after = store.beatTimes(after1, duration: store.estimatedLength(after1)).map { "\($0)" }
                store.state.syncTimes = ["e1": synced]
                let syncedTimes = store.beatTimes(after1, duration: 500)
                lines0.append("copy beat: \(b71 ?? -1), last section \(after1.sections.last?.span ?? "?"), visible \(after1.sections.last?.range.contains(b71 ?? -1) ?? false), timings kept \(Array(after.prefix(before.count)) == before), synced kept \(syncedTimes[69] == (70, 71)), new beat at \(syncedTimes[70]), status \(store.audioStatus(after1, after1.beats[70], changed: []).label)")
                store.state.syncTimes = nil
                let castBefore = store.season?.cast.count ?? -1, firstBefore = store.season?.eps[0].label ?? ""
                let (s2, sWhy) = store.createSeason(title: "Season 2")
                let (s2e, s2Why) = store.createEpisode(title: "New Start", season: s2 ?? 2)
                let added = store.season?.eps.first { $0.n == s2e }
                lines0.append("season: \(s2.map(String.init) ?? sWhy ?? "?"), ep id \(s2e.map(String.init) ?? s2Why ?? "?"), label \(added?.label ?? "?"), number \(added?.number ?? -1), titles \(store.seasons.map(\.title)), s1 eps \(store.season?.only(1).eps.count ?? -1), s2 eps \(store.season?.only(2).eps.count ?? -1), cast \(castBefore)->\(store.season?.cast.count ?? -1), first \(firstBefore)->\(store.season?.eps[0].label ?? "")")
                nav.tab = .ep; nav.seasonN = 2; nav.ep = s2e ?? 1; spin(0.3)
                extra(BenchSidebar(), "sidebar-season2.png", 250, 860)
                _ = store.renameSeason(2, title: "The Second Year")
                lines0.append("renamed: \(store.seasons.map(\.title))")
                lines0.append("copy: new ep \(n2.map(String.init) ?? why2 ?? "?"), total \(store.season?.eps.count ?? -1), decoded \(store.season != nil)")
            }
            nav.open(kitchen, store: store, listener: listener, trailer: tm); spin(1)
            lines0.append("back: eps \(store.season?.eps.count ?? -1), images \(store.state.images.count), hasTrailer \(store.hasTrailer), tab \(nav.tab.rawValue) ep \(nav.ep)")
        }
        var lines = ["beats: \(season.eps[0].beats.count)", "changed: \(store.changedSinceRecording(season.eps[0]))", "audio: \(store.audioURL(season.eps[0])?.lastPathComponent ?? "none")"]
        var counts: [String: Int] = [:]
        for b in season.eps[0].beats { counts[store.artStatus(season.eps[0], b).label, default: 0] += 1 }
        lines.append("art: \(counts)")
        try? (lines + lines0).joined(separator: "\n").write(to: dir.appendingPathComponent("facts.txt"), atomically: true, encoding: .utf8)
        exit(0)
    }
}
