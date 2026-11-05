import SwiftUI
import UniformTypeIdentifiers

// MARK: - Look

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255) }
    static let bg = Color(hex: 0x141210), panel = Color(hex: 0x1d1a17), card = Color(hex: 0x24201c), line = Color(hex: 0x3a332c)
    static let ink = Color(hex: 0xefe6d3), soft = Color(hex: 0xa89c8a), mute = Color(hex: 0x6f6556), gold = Color(hex: 0xd4a84b), red2 = Color(hex: 0xd9534f)
    static let gpt = Color(hex: 0xe07a2e), built = Color(hex: 0x4f8fd0), done = Color(hex: 0x5aa36a), plate = Color(hex: 0x8b8b8b), reuse = Color(hex: 0xa77ccf)
    static let dark = Color(hex: 0x1a1714)
    static func kind(_ k: String) -> Color {
        switch k { case "gpt": return .gpt; case "built": return .built; case "done": return .done; case "plate": return .plate; case "reuse": return .reuse; default: return .mute }
    }
}
extension Font {
    static func serif(_ s: CGFloat) -> Font { .custom("Didot", size: s) }
    static func body(_ s: CGFloat) -> Font { .custom("Baskerville", size: s) }
}
struct Eyebrow: View {
    let text: String
    var color: Color = .gold
    init(_ t: String, color: Color = .gold) { text = t; self.color = color }
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(2.2).foregroundStyle(color) }
}
struct Pill: View {
    let text: String; let color: Color; var dark = false
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 2)
            .background(color, in: Capsule()).foregroundStyle(dark ? Color.dark : .white)
    }
}
struct Stat: View {
    let value: String; let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.serif(30)).foregroundStyle(Color.ink)
            Text(label.uppercased()).font(.system(size: 10)).tracking(1.4).foregroundStyle(Color.mute)
        }.fixedSize()
    }
}
struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            ForEach(["gpt", "built", "done", "plate", "reuse"], id: \.self) { k in
                HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(Color.kind(k)).frame(width: 10, height: 10); Text(Kind.label(k)) }
            }
        }.font(.system(size: 12)).foregroundStyle(Color.soft)
    }
}
struct Box<C: View>: View {
    var title: String? = nil; var titleColor: Color = .gold; var border: Color = .line
    @ViewBuilder var content: C
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) { content }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        } label: {
            if let title { Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(titleColor) }
        }
    }
}

// MARK: - Navigation state

enum Tab: String, CaseIterable { case season = "Season", ep = "Episodes", cast = "Characters", food = "Food", truck = "The truck", make = "Make list", listen = "Listen", boards = "Storyboards", plates = "Plates", locations = "Locations", review = "Scene review", trailer = "Season 1 Trailer", kie = "Kie"
    var icon: String {
        switch self {
        case .season: return "square.grid.2x2"
        case .ep: return "film.stack"
        case .cast: return "person.2"
        case .food: return "fork.knife"
        case .truck: return "box.truck"
        case .make: return "checklist"
        case .listen: return "headphones"
        case .boards: return "pencil.and.scribble"
        case .review: return "checklist.checked"
        case .plates: return "photo.on.rectangle.angled"
        case .locations: return "map"
        case .trailer: return "film"
        case .kie: return "paintbrush"
        }
    }
}

/// Screens pushed onto a tab's NavigationStack.
enum Route: Hashable { case episode(Int), readThrough(Int), plate(String) }

/// Which picture the pointer is over, for the gold outline on every beat that shares it. Kept out of Nav so a
/// hover redraws only the outlines, not the whole page (that made scrolling jittery).
final class Hover: ObservableObject { @Published var img: String? = nil }

final class Nav: ObservableObject {
    @Published var tab: Tab = .season
    @Published var sidebarRequest: NavigationSplitViewVisibility? = nil   // a page asking to show or hide the sidebar
    @Published var path: [Route] = []
    @Published var ep = 1
    @Published var seasonN = 1                     // the season the sidebar and season page are showing
    @Published var selected: Int? = nil
    @Published var inspector = false
    @Published var drawer: Drawer = .beat
    @Published var query = ""
    @Published var chooser: String? = nil          // still id for the chooser sheet
    @Published var scrollTo: Int? = nil
    @Published var viewing = false                 // the selected beat's picture, filling the window
    @Published var importing = false               // a file or folder picker is open
    @Published var stage = Stage.beats             // which stage of the episode: Beats, Script ...
    @Published var oldEpisodePage = false          // the old episode page instead of the new Beats page
    @Published var typing = false                  // typing in a text box on the Beats page: single-key shortcuts stay off
    var importTypes: [UTType] = [.item]
    var importInSheet = false                      // the still chooser sheet hosts its own picker
    var importDone: ((URL) -> Void)?
    /// Opens SwiftUI's file picker for these types and hands back what was picked.
    func choose(_ types: [UTType], _ done: @escaping (URL) -> Void) {
        importTypes = types; importDone = done; importInSheet = chooser != nil; importing = true
    }
    enum Drawer: Equatable { case beat, options(Int), plan }
    func go(_ t: Tab, ep e: Int? = nil, beat: Int? = nil) {
        tab = t; path = []; if let e { ep = e }; selected = beat; scrollTo = beat; inspector = beat != nil; drawer = .beat; query = ""
    }
    /// Pushes an episode onto the current tab, optionally at a beat.
    func open(ep e: Int, beat: Int? = nil) {
        ep = e; selected = beat; scrollTo = beat; inspector = beat != nil; drawer = .beat
        path.append(.episode(e))
    }
    /// The episode on screen, if one is.
    /// The trailer page is showing (its shot panel uses the window's side column).
    var showsTrailer: Bool { tab == .trailer && path.isEmpty && query.isEmpty }
    /// The new Beats page is on screen; it keeps its own panel and player.
    var showsBeatsPage: Bool {
        guard !oldEpisodePage else { return false }
        switch path.last {
        case .episode?: return true
        case .readThrough?, .plate?: return false
        case nil: return tab == .ep && query.isEmpty
        }
    }
    var shownEpisode: Int? {
        switch path.last {
        case .episode(let n)?, .readThrough(let n)?: return n
        case .plate?: return nil
        case nil: return tab == .ep && query.isEmpty ? ep : nil
        }
    }
}

// MARK: - App

@main
struct StoryViewerApp: App {
    @StateObject var store = Store()
    @StateObject var nav = Nav()
    @StateObject var hover = Hover()
    @StateObject var exporter = VideoExporter()
    @StateObject var player = Player()
    @StateObject var listener = Listener()
    @StateObject var trailer = TrailerModel()
    init() { Verify.runIfAsked() }
    var body: some Scene {
        WindowGroup("Storybound") {
            ContentView().environmentObject(store).environmentObject(nav).environmentObject(hover).environmentObject(exporter).environmentObject(player).environmentObject(listener)
                .environmentObject(trailer)
                .onAppear { listener.store = store }
                .frame(minWidth: 1180, minHeight: 760).preferredColorScheme(.dark)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project Folder…") { nav.choose([.folder]) { if let p = store.addExistingProject($0) { nav.open(p, store: store, listener: listener, trailer: trailer) } } }.keyboardShortcut("o")
                Button("Reload Season") { store.load() }.keyboardShortcut("r")
                Divider()
                ShowInFinderButton(url: store.userDir)
                Button("Back Up My Images…") { nav.choose([.folder]) { store.backup(to: $0) } }
                Button("Restore From Backup…") { nav.choose([.folder]) { store.restore(from: $0) } }
            }
            SidebarCommands()
            CommandMenu("Go") {
                Button("Season") { nav.go(.season) }.keyboardShortcut("1")
                Button("Episodes") { nav.go(.ep) }.keyboardShortcut("2")
                Button("Characters") { nav.go(.cast) }.keyboardShortcut("3")
                Button("Food") { nav.go(.food) }.keyboardShortcut("4")
                Button("The Truck") { nav.go(.truck) }.keyboardShortcut("5")
                Button("Make List") { nav.go(.make) }.keyboardShortcut("6")
                Button("Listen") { nav.go(.listen) }.keyboardShortcut("7")
            }
        }
    }
}

/// Opens a folder in Finder through SwiftUI's openURL.
struct ShowInFinderButton: View {
    @Environment(\.openURL) var openURL
    let url: URL
    var body: some View { Button("Show My Images in Finder") { openURL(url) } }
}

/// SwiftUI's file picker, driven by nav.choose(_:_:).
struct ImportHost: ViewModifier {
    @ObservedObject var nav: Nav
    let inSheet: Bool
    func body(content: Content) -> some View {
        content.fileImporter(isPresented: Binding(get: { nav.importing && nav.importInSheet == inSheet }, set: { if !$0 { nav.importing = false } }),
                             allowedContentTypes: nav.importTypes) { result in
            if case .success(let url) = result { nav.importDone?(url) }
            nav.importing = false
        }
    }
}

/// Accepts a file dropped from Finder and hands its URL over.
struct FileDrop: ViewModifier {
    let onURL: (URL) -> Void
    @Binding var targeted: Bool
    func body(content: Content) -> some View {
        content.dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onURL(url); return true
        } isTargeted: { targeted = $0 }
    }
}
extension View {
    func fileDrop(targeted: Binding<Bool>, _ onURL: @escaping (URL) -> Void) -> some View { modifier(FileDrop(onURL: onURL, targeted: targeted)) }
}

// MARK: - Window

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    @EnvironmentObject var trailerModel: TrailerModel
    @FocusState var searchFocus: Bool

    var body: some View {
        ZStack {
            Color.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                // native sidebar: title-bar toggle, View › Hide Sidebar (⌃⌘S), drag to resize
                NavigationSplitView(columnVisibility: $columns) {
                    BenchSidebar()
                    .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 420)   // drag the divider to resize; pages shrink to fit beside it
                } detail: {
                    DetailColumn()
                }
                .frame(minHeight: 0, maxHeight: .infinity)      // never taller than the window
                .toolbar { ToolbarItem(placement: .primaryAction) { CreditsButton() } }
                .searchable(text: $nav.query, placement: .sidebar, prompt: "Search lines or scenes  ( / )")
                .searchFocused($searchFocus)
                // the beat panel: a full-height column on the right of the split view
                .inspector(isPresented: Binding(get: { nav.inspector && (nav.shownEpisode != nil || nav.showsTrailer) && !player.isOpen && !nav.showsBeatsPage },
                                                set: { nav.inspector = $0 })) {
                    if let n = nav.shownEpisode, let e = store.season?.eps.first(where: { $0.n == n }) {
                        InspectorView(e: e).inspectorColumnWidth(min: 280, ideal: 400, max: 600).scrollIndicators(.never)
                    } else if nav.showsTrailer {
                        // a trailer shot's panel: the same column as a beat's
                        TrailerInspector().inspectorColumnWidth(min: 300, ideal: 440, max: 640).scrollIndicators(.never)
                    }
                }
                // the season player, on every tab (like the Music app); hidden during a read-through
                if let season = store.season, !player.isOpen, !nav.showsBeatsPage {
                    Rectangle().fill(Color.line).frame(height: 1)
                    NowPlaying(season: season).frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            if nav.viewing, let n = nav.shownEpisode, let e = store.season?.eps.first(where: { $0.n == n }),
               let b = e.beats.first(where: { $0.n == nav.selected }) {
                BeatViewer(e: e, b: b).zIndex(8).transition(.opacity)
            }
            if trailerModel.watching && nav.showsTrailer {
                TrailerWatch(audio: trailerModel.audio, close: { withAnimation(.easeOut(duration: 0.2)) { trailerModel.watching = false } })
                    .zIndex(11).transition(.opacity)
            }
            if nav.viewing, nav.showsTrailer, let tile = trailerModel.tile(trailerModel.selected) {
                TileViewer(tile: tile, url: trailerModel.files[tile.id]?.shown, close: { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = false } })
                    .zIndex(8).transition(.opacity)
            } else if nav.viewing, nav.showsTrailer, let t = trailerModel.trailer, let s = trailerModel.shot {
                TrailerViewer(shot: s, trailer: t, files: trailerModel.files, close: { withAnimation(.easeOut(duration: 0.2)) { nav.viewing = false } })
                    .zIndex(8).transition(.opacity)
            }
            // Watch: the read-through's picture alone, filling the window (and the screen, with ⌃⌘F)
            if player.isOpen && player.watching, let e = player.episode {
                WatchView(e: e).zIndex(10).transition(.opacity)
            }
            if let t = store.toast {
                VStack { Spacer(); Text(t).font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(Color.gold, in: Capsule()).foregroundStyle(Color.dark).padding(.bottom, 140) }
                    .allowsHitTesting(false).zIndex(9)
            }
        }
        .foregroundStyle(Color.ink)
        .onChange(of: nav.sidebarRequest) { _, v in if let v { columns = v; nav.sidebarRequest = nil } }
        .toolbar(player.isOpen && player.watching ? .hidden : .automatic, for: .windowToolbar)
        .animation(.easeInOut(duration: 0.25), value: player.watching)
        .sheet(item: Binding(get: { nav.chooser.map { ChooserID(id: $0) } }, set: { nav.chooser = $0?.id })) { c in
            if let e = store.season?.eps.first(where: { $0.n == nav.ep }), let s = e.built.first(where: { $0.id == c.id }) {
                StillChooser(episode: e, still: s).environmentObject(store).environmentObject(nav).scrollIndicators(.never)
                    .modifier(ImportHost(nav: nav, inSheet: true))
            }
        }
        .background(KeyCommands(searchFocus: $searchFocus))
        .onAppear { Snapshot.runIfAsked(nav: nav, store: store, trailer: trailerModel) }
        .modifier(ImportHost(nav: nav, inSheet: false))
        .onChange(of: player.isOpen) { _, open in
            // back on the episode page, at the beat the read-through stopped on
            guard !open, let e = player.episode, e.beats.indices.contains(player.index) else { return }
            let n = e.beats[player.index].n
            nav.selected = n
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { nav.scrollTo = n }
        }
    }

    @State var columns = NavigationSplitViewVisibility.all
}

/// The detail column: the tab's NavigationStack and the beat inspector. Its own view, so
/// SwiftUI re-checks the inspector whenever the navigation state changes (the split view
/// doesn't re-run its detail builder on its own).
struct DetailColumn: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var trailerModel: TrailerModel
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player

    var body: some View {
        NavigationStack(path: $nav.path) {
            detail.navigationDestination(for: Route.self) { route in
                // pushed pages take whatever width is left, like the root page, so the inspector always fits
                destination(route).frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
            }
        }
        .scrollIndicators(.never)          // no scroll bars on any page, list or table
        .background(Color.bg)
    }

    @ViewBuilder var detail: some View {
        if let season = store.season {
            Group {
                if !nav.query.trimmingCharacters(in: .whitespaces).isEmpty { SearchView(season: season) }
                else {
                    switch nav.tab {
                    case .season: SeasonView(season: season.only(nav.seasonN))
                    case .ep: EpisodeStage(season: season, n: nav.ep, isRoot: true)
                    case .cast: CastView(season: season)
                    case .food: FoodView(season: season)
                    case .truck: TruckView(season: season)
                    case .make: MakeView(season: season)
                    case .listen: ListenView(season: season)
                    case .boards: StoryboardsView(season: season)
                    case .review: ReviewView()
                    case .plates: PlatesView()
                    case .locations: LocationsView(season: season)
                    case .trailer: TrailerView(audio: trailerModel.audio)
                    case .kie: KieTab()
                    }
                }
            }.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            VStack(spacing: 14) {
                Text("No season data found").font(.serif(30))
                Text(store.loadError ?? "").foregroundStyle(Color.soft).multilineTextAlignment(.center)
                Button("Open Project Folder…") {
                    nav.choose([.folder]) { store.folder = $0; store.load(); store.loadProjects() }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder func destination(_ route: Route) -> some View {
        if let season = store.season {
            switch route {
            case .episode(let n): EpisodeStage(season: season, n: n, isRoot: false)
            case .readThrough(let n):
                if let e = season.eps.first(where: { $0.n == n }) { PlayerView(episode: e) }
            case .plate(let id): PlateDetailView(season: season, plateID: id)
            }
        }
    }
}

/// Keyboard shortcuts as hidden buttons. Its own view, so the audio player's
/// frequent updates redraw these buttons only, not the whole window.
struct KeyCommands: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var trailerModel: TrailerModel
    var searchFocus: FocusState<Bool>.Binding

    var body: some View {
        ZStack {
            Button("") { searchFocus.wrappedValue = true }.keyboardShortcut("/", modifiers: [])
            Button("") {
                if player.watching { player.watching = false }
                else if trailerModel.watching { trailerModel.watching = false }
                else if nav.viewing && ZoomState.shared.zoomed { ZoomState.shared.reset() }   // zoomed in: back to the whole picture first
                else if nav.viewing { nav.viewing = false }
                else if nav.inspector { nav.inspector = false }
                else if !nav.path.isEmpty { nav.path.removeLast() }
                else if !nav.query.isEmpty { nav.query = ""; searchFocus.wrappedValue = false }
            }.keyboardShortcut(.escape, modifiers: [])
            Button("") { arrow(1) }.keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { arrow(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            Button("") {
                if player.isOpen { player.toggle() }
                else if nav.showsTrailer { trailerModel.audio.toggle() }
                else if nav.tab == .listen && nav.query.isEmpty { listener.toggle() }
                else if let n = nav.shownEpisode, let e = store.season?.eps.first(where: { $0.n == n }) { listener.toggle(e, from: nav.selected) }
            }.keyboardShortcut(.space, modifiers: [])
            Button("") { if player.isOpen { player.sidebar.toggle() } }.keyboardShortcut("b", modifiers: [])
            Button("") { if player.isOpen { player.watching.toggle() } }.keyboardShortcut("f", modifiers: [])
        }.opacity(0).frame(width: 0, height: 0).disabled(searchFocus.wrappedValue || nav.tab == .kie || nav.typing)   // the Kie tab is for typing: space, / and letters stay in the prompt
    }
    func arrow(_ d: Int) {
        if player.isOpen { player.step(d); return }
        if nav.tab == .trailer && nav.query.isEmpty { NotificationCenter.default.post(name: .trailerStep, object: d); return }
        if nav.tab == .listen { d > 0 ? listener.nextSection() : listener.prevSection(); return }
        guard let n = nav.shownEpisode, let e = store.season?.eps.first(where: { $0.n == n }) else { return }
        guard !e.beats.isEmpty else { return }
        let i = e.beats.firstIndex { $0.n == nav.selected } ?? -1
        let j = min(e.beats.count - 1, max(0, i + d))
        nav.selected = e.beats[j].n; nav.scrollTo = e.beats[j].n; nav.drawer = .beat; nav.inspector = true
    }
}
struct ChooserID: Identifiable { let id: String }
