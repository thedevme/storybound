import SwiftUI

// MARK: - The sidebar: every project, then the open project's episodes and library (Storybench direction)

struct BenchSidebar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var trailerModel: TrailerModel
    @State var episodesOpen = true
    @State var allProjects = false
    @State var allEpisodes = false
    @State var moreOpen = false
    @State var newProject = false
    @State var newEpisode = false
    @State var newSeason = false
    @State var renamingSeason: SeasonInfo?
    @State var settingsFor: BenchProject?
    let shownProjects = 4, shownEpisodes = 8

    /// The review questions you haven't answered yet.
    var reviewCount: Int {
        (store.review?.decisions.filter(\.craig) ?? []).filter { (store.state.answers?[String($0.n)] ?? "").isEmpty }.count
    }
    /// The open project always stays on the short list.
    var listedProjects: [BenchProject] {
        if allProjects || store.projects.count <= shownProjects { return store.projects }
        var out = Array(store.projects.prefix(shownProjects))
        if let c = store.currentProject, !out.contains(c) { out[out.count - 1] = c }
        return out
    }

    var body: some View {
        let _ = store.imageVersion
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    heading("Projects")
                    Button { newProject = true } label: {
                        Label("New project", systemImage: "plus").font(.system(size: 13)).frame(maxWidth: .infinity).frame(height: 28)
                            .background(Color.benchRaised, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(.bottom, 6)
                    ForEach(listedProjects) { p in projectRow(p) }
                    if store.projects.count > shownProjects {
                        toggle(allProjects ? "Show less" : "Show more (\(store.projects.count - shownProjects))", open: allProjects) { allProjects.toggle() }
                    }
                    heading(store.projectName).padding(.top, 8)
                    seasonMenu
                    episodes
                    Rectangle().fill(Color.clear).frame(height: 6)
                    row(.cast, "person.2", "Characters")
                    row(.locations, "map", "Locations")
                    if store.currentProject?.hideFood != true { row(.food, "fork.knife", "Food") }
                    if store.currentProject?.hideTruck != true { row(.truck, "box.truck", "Truck") }
                    row(.plates, "photo", "Backgrounds")
                    toggle("More", open: moreOpen) { moreOpen.toggle() }.padding(.top, 4)
                    if moreOpen || [.boards, .review, .make, .listen].contains(nav.tab) {
                        row(.boards, "paintbrush.pointed", "Artwork")
                        row(.review, "checkmark.circle", "Review queue", count: reviewCount)
                        row(.make, "checklist", "Make list")
                        row(.listen, "headphones", "Listen")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            Rectangle().fill(Color.benchLine).frame(height: 1)
            VStack(spacing: 2) {
                BenchSidebarRow(icon: "paintbrush", title: "Kie", on: isOn(.kie)) { nav.go(.kie) }
                BenchSidebarRow(icon: "gearshape", title: "Project settings", on: false) { settingsFor = store.currentProject }
            }.padding(8)
        }
        .background(Color.benchPanel.ignoresSafeArea())
        .foregroundStyle(Color.benchInk)
        .sheet(isPresented: $newProject) {
            NewProjectSheet { open($0) }.environmentObject(store)
        }
        .sheet(isPresented: $newEpisode) {
            NewEpisodeSheet(seasonN: nav.seasonN) { nav.go(.ep, ep: $0) }.environmentObject(store)
        }
        .sheet(isPresented: $newSeason) {
            SeasonNameSheet(renaming: nil) { nav.openSeason($0, store: store) }.environmentObject(store)
        }
        .sheet(item: $renamingSeason) { s in
            SeasonNameSheet(renaming: s) { _ in }.environmentObject(store)
        }
        // an episode opened from anywhere else brings its season with it
        .onChange(of: nav.ep) { _, n in followEpisode(n) }
        .onChange(of: nav.tab) { _, _ in if nav.tab == .ep { followEpisode(nav.ep) } else if nav.tab == .trailer { nav.seasonN = 1 } }
        .onAppear { if nav.tab == .ep { followEpisode(nav.ep) } }
        // a page just turned off in Project settings doesn't stay on screen
        .onChange(of: store.projects) { _, _ in
            let p = store.currentProject
            if (nav.tab == .truck && p?.hideTruck == true) || (nav.tab == .food && p?.hideFood == true) { nav.go(.season) }
        }
        .sheet(item: $settingsFor) { p in
            ProjectSettingsSheet(p: p) { if store.currentProject == nil, let first = store.projects.first { open(first) } }.environmentObject(store)
        }
    }

    func open(_ p: BenchProject) { nav.open(p, store: store, listener: listener, trailer: trailerModel) }
    func followEpisode(_ n: Int) {
        guard nav.tab == .ep, let e = store.season?.eps.first(where: { $0.n == n }), e.seasonN != nav.seasonN else { return }
        nav.seasonN = e.seasonN
    }
    var seasonMenu: some View {
        let list = store.seasons
        let now = list.first { $0.n == nav.seasonN } ?? list.first
        return Menu {
            ForEach(list) { s in
                Button { nav.openSeason(s.n, store: store) } label: {
                    if s.n == nav.seasonN { Label(s.title, systemImage: "checkmark") } else { Text(s.title) }
                }
            }
            Divider()
            Button("New season…") { newSeason = true }
            if let now { Button("Rename \(now.title)…") { renamingSeason = now } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 12)).frame(width: 18)
                Text(now?.title ?? "Season 1").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.benchSoft)
            }
            .padding(.horizontal, 8).frame(height: 30)
            .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).padding(.bottom, 4)
    }
    func isOn(_ t: Tab) -> Bool { nav.tab == t && nav.query.isEmpty }

    @ViewBuilder var episodes: some View {
        let eps = (store.season?.eps ?? []).filter { $0.seasonN == nav.seasonN }
        let trailerHere = store.hasTrailer && nav.seasonN == (store.seasons.first?.n ?? 1)
        HStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { episodesOpen.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(episodesOpen ? 90 : 0)).frame(width: 12)
                    Image(systemName: "rectangle.stack").font(.system(size: 13))
                    Text("Episodes").font(.system(size: 13))
                    Spacer()
                }.padding(.leading, 8).frame(height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { newEpisode = true } label: {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
            }.buttonStyle(.plain).foregroundStyle(Color.benchSoft).help("New episode")
        }
        if episodesOpen {
            if eps.isEmpty { Text("No episodes yet").font(.system(size: 12)).foregroundStyle(Color.benchSoft).padding(.leading, 34).frame(height: 24) }
            // the open episode or the trailer past the short list opens the whole list
            let openAll = allEpisodes || (isOn(.ep) && !eps.prefix(shownEpisodes).contains { $0.n == nav.ep }) || isOn(.trailer)
            ForEach(openAll ? eps : Array(eps.prefix(shownEpisodes))) { e in
                BenchSidebarRow(icon: "play.circle", title: String(format: "%02d  %@", e.number, e.title), indent: 18, on: isOn(.ep) && nav.ep == e.n) { nav.go(.ep, ep: e.n) }
            }
            if openAll && trailerHere {
                BenchSidebarRow(icon: "film", title: Tab.trailer.rawValue, indent: 18, on: isOn(.trailer)) { nav.go(.trailer) }
            }
            if eps.count > shownEpisodes || (trailerHere && !openAll) {
                toggle(allEpisodes ? "Show fewer episodes" : "Show more episodes", open: allEpisodes) { allEpisodes.toggle() }.padding(.leading, 18)
            }
        }
    }

    func projectRow(_ p: BenchProject) -> some View {
        let on = store.currentProject?.id == p.id
        let count = store.projectEpisodes[p.id] ?? 0
        return Button {
            if on { nav.go(.season) } else { open(p) }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Color.black
                    if let u = store.logoFile(p), let logo = store.fileImage(u, maxPixel: 200) { logo.resizable().scaledToFit().padding(2) }
                    else { Text(String(p.name.prefix(1)).uppercased()).font(.bench(18)).foregroundStyle(Color.benchSoft) }
                }.frame(width: 38, height: 38).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("\(seasonLine(p)) · \(count) episode\(count == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(on ? Color.benchInk.opacity(0.8) : Color.benchSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
                if on {
                    Menu {
                        Button("Season overview") { nav.go(.season) }
                        Button("Project settings") { settingsFor = p }
                    } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            }
            .padding(6)
            .background(on ? Color.benchBlue.opacity(0.4) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).help(on ? "Season overview" : "Open \(p.name)")
    }

    func seasonLine(_ p: BenchProject) -> String {
        let t = store.projectSeasons[p.id] ?? [p.season]
        return t.count > 1 ? "\(t.count) seasons" : (t.first ?? p.season)
    }
    func row(_ t: Tab, _ icon: String, _ title: String, count: Int = 0) -> some View {
        BenchSidebarRow(icon: icon, title: title, count: count, on: isOn(t)) { nav.go(t) }
    }
    func toggle(_ title: String, open: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeOut(duration: 0.15)) { act() } }) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).rotationEffect(.degrees(open ? 180 : 0)).frame(width: 18)
                Text(title).font(.system(size: 12))
                Spacer()
            }.padding(.horizontal, 8).frame(height: 24).foregroundStyle(Color.benchSoft).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    func heading(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.6).foregroundStyle(Color.benchSoft).lineLimit(1)
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 6)
    }
}

struct BenchSidebarRow: View {
    let icon: String; let title: String
    var count = 0
    var indent: CGFloat = 0
    let on: Bool
    let action: () -> Void
    @State var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).padding(.horizontal, 7).frame(height: 18)
                        .background(Color.benchRaised, in: Capsule())
                }
            }
            .padding(.leading, 8 + indent).padding(.trailing, 8).frame(height: 26)
            .background(on ? Color.benchBlue : hovering ? Color.benchRaised : .clear, in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(on ? Color.white : Color.benchInk)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
