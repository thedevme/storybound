import SwiftUI
import UniformTypeIdentifiers

// MARK: - Many projects. Each is a folder laid out like Kitchen: <root>/_work/episode-stories/_viewer/season.json and <root>/ART.

struct BenchProject: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String
    var season = "Season 1"
    var folder: String          // Store.folder: the episode-stories folder
    var logo: String? = nil     // a picture you chose; otherwise the first one in ART/Logos
    var hideTruck: Bool? = nil  // Project settings: leave the Truck page out of the sidebar
    var hideFood: Bool? = nil   // and the Food page
    var root: URL { URL(fileURLWithPath: folder).deletingLastPathComponent().deletingLastPathComponent() }
}

extension Season {
    /// The same project, showing one season's episodes.
    func only(_ n: Int) -> Season { var c = self; c.eps = eps.filter { $0.seasonN == n }; return c }
}

extension Store {
    /// The open project's seasons. A file that doesn't list them has one.
    var seasons: [SeasonInfo] { season?.seasons ?? [SeasonInfo(n: 1, title: currentProject?.season ?? "Season 1")] }
    static var defaults = UserDefaults.standard      // the off-screen check swaps this so it never touches your list
    static let projectsKey = "projects"
    /// Kie belongs to the whole app, not a project: one set of pictures and presets, whichever project is open.
    static var kieFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Kitchen/ART/Kie") }
    static var kitchenFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Kitchen/_work/episode-stories") }

    var currentProject: BenchProject? { projects.first { $0.folder == folder.path } }
    var projectName: String { currentProject?.name ?? "Against the Grain" }
    /// The trailer lives in the against-the-grain skill, so only that show has one.
    var hasTrailer: Bool { folder.path == Store.kitchenFolder.path }

    func loadProjects() {
        if let d = Store.defaults.data(forKey: Store.projectsKey), let list = try? JSONDecoder().decode([BenchProject].self, from: d), !list.isEmpty { projects = list }
        // the folder the app already works in is always on the list
        if !projects.contains(where: { $0.folder == folder.path }) {
            let name = folder.path == Store.kitchenFolder.path ? "Against the Grain" : BenchProject(name: "", folder: folder.path).root.lastPathComponent
            projects.insert(BenchProject(name: name, folder: folder.path), at: 0)
        }
        countEpisodes()
    }
    func saveProjects() {
        if let d = try? JSONEncoder().encode(projects) { Store.defaults.set(d, forKey: Store.projectsKey) }
        countEpisodes()
    }
    func countEpisodes() {
        var out: [String: Int] = [:], titles: [String: [String]] = [:]
        for p in projects {
            let u = URL(fileURLWithPath: p.folder).appendingPathComponent("_viewer/season.json")
            if let d = try? Data(contentsOf: u), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let eps = j["eps"] as? [Any] {
                out[p.id] = eps.count
                titles[p.id] = (j["seasons"] as? [[String: Any]])?.compactMap { $0["title"] as? String }
            }
        }
        projectEpisodes = out; projectSeasons = titles
    }
    func logoFile(_ p: BenchProject) -> URL? {
        let fm = FileManager.default
        if let l = p.logo, fm.fileExists(atPath: l) { return URL(fileURLWithPath: l) }
        let dir = p.root.appendingPathComponent("ART/Logos")
        if p.folder == Store.kitchenFolder.path {
            let u = dir.appendingPathComponent("Against the Grain - Season 1 Logo.png")
            if fm.fileExists(atPath: u.path) { return u }
        }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }.sorted { $0.path < $1.path }.first
    }

    /// Makes the folders and an empty season for a new project. Returns why it couldn't, or nil.
    func createProject(name: String, season seasonName: String, parent: URL) -> (BenchProject?, String?) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty else { return (nil, "Give the project a name.") }
        let fm = FileManager.default, root = parent.appendingPathComponent(clean)
        if fm.fileExists(atPath: root.path) { return (nil, "\(root.path) already exists. Pick another name or folder.") }
        let stories = root.appendingPathComponent("_work/episode-stories"), viewer = stories.appendingPathComponent("_viewer")
        do {
            try fm.createDirectory(at: viewer.appendingPathComponent("user"), withIntermediateDirectories: true)
            for d in ["ART/Characters", "ART/Locations", "ART/Logos", "ART/Props", "episodes"] { try fm.createDirectory(at: root.appendingPathComponent(d), withIntermediateDirectories: true) }
            let empty = Season(seasons: [SeasonInfo(n: 1, title: seasonName.isEmpty ? "Season 1" : seasonName)], eps: [], cast: [], food: [], truck: Truck(layout: "", views: []))
            try JSONEncoder().encode(empty).write(to: viewer.appendingPathComponent("season.json"))
        } catch { return (nil, error.localizedDescription) }
        // Truck and Food start off in a new project; Project settings turns them on
        let p = BenchProject(name: clean, season: seasonName, folder: stories.path, hideTruck: true, hideFood: true)
        projects.append(p); saveProjects()
        return (p, nil)
    }
    /// Puts a folder that already holds a project on the list: the project's root or its episode-stories folder.
    func addExistingProject(_ url: URL) -> BenchProject? {
        let fm = FileManager.default
        let candidates = [url, url.appendingPathComponent("_work/episode-stories")]
        guard let stories = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("_viewer/season.json").path) }) else {
            say("No season found in that folder."); return nil
        }
        if let known = projects.first(where: { $0.folder == stories.path }) { return known }
        var p = BenchProject(name: "", folder: stories.path); p.name = p.root.lastPathComponent
        projects.append(p); saveProjects()
        return p
    }
    /// Adds an empty episode to the open project's season.json and loads it. Edits the file as plain JSON, so nothing else in it changes.
    /// The first time, the file is copied to season.json.bak-before-new-episode.
    func createEpisode(title: String, season seasonN: Int = 1) -> (Int?, String?) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return (nil, "Give the episode a title.") }
        let url = dataDir.appendingPathComponent("season.json")
        do {
            let data = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any], var eps = root["eps"] as? [[String: Any]] else { return (nil, "Couldn't read this project's season file.") }
            let n = (eps.compactMap { $0["n"] as? Int }.max() ?? 0) + 1
            eps.append(["n": n, "title": clean, "made": false, "logline": "", "summary": [], "sections": [], "beats": [], "gpt": [], "built": [], "prep": [], "words": 0, "ends": "", "season": seasonN])
            root["eps"] = eps
            let bak = dataDir.appendingPathComponent("season.json.bak-before-new-episode")
            if !FileManager.default.fileExists(atPath: bak.path) { try FileManager.default.copyItem(at: url, to: bak) }
            try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]).write(to: url, options: .atomic)
            load(); countEpisodes()
            return (season?.eps.contains { $0.n == n } == true ? n : nil, season == nil ? loadError : nil)
        } catch { return (nil, error.localizedDescription) }
    }
    /// Edits the season list in season.json, as plain JSON, and reloads. Nothing else in the file changes.
    private func writeSeasons(_ change: (inout [SeasonInfo]) -> Void) -> String? {
        let url = dataDir.appendingPathComponent("season.json")
        do {
            let data = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Couldn't read this project's season file." }
            var list = seasons
            change(&list)
            root["seasons"] = list.map { ["n": $0.n, "title": $0.title] as [String: Any] }
            let bak = dataDir.appendingPathComponent("season.json.bak-before-new-episode")
            if !FileManager.default.fileExists(atPath: bak.path) { try FileManager.default.copyItem(at: url, to: bak) }
            try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]).write(to: url, options: .atomic)
            load(); countEpisodes()
            return nil
        } catch { return error.localizedDescription }
    }
    func createSeason(title: String) -> (Int?, String?) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return (nil, "Give the season a name.") }
        let n = (seasons.map(\.n).max() ?? 0) + 1
        if let why = writeSeasons({ $0.append(SeasonInfo(n: n, title: clean)) }) { return (nil, why) }
        return (n, nil)
    }
    func renameSeason(_ n: Int, title: String) -> String? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Give the season a name." }
        return writeSeasons { list in if let i = list.firstIndex(where: { $0.n == n }) { list[i].title = clean } }
    }
    /// Adds a character or a dish to the project's library in season.json, as plain JSON. Every season shares the library.
    func addLibraryItem(_ key: String, name: String, entry: [String: Any]) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Give it a name." }
        let url = dataDir.appendingPathComponent("season.json")
        do {
            let data = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "Couldn't read this project's season file." }
            var list = root[key] as? [[String: Any]] ?? []
            if list.contains(where: { ($0["name"] as? String)?.caseInsensitiveCompare(clean) == .orderedSame }) { return "\(clean) is already in this project." }
            var item = entry; item["name"] = clean
            list.append(item); root[key] = list
            let bak = dataDir.appendingPathComponent("season.json.bak-before-new-episode")
            if !FileManager.default.fileExists(atPath: bak.path) { try FileManager.default.copyItem(at: url, to: bak) }
            try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]).write(to: url, options: .atomic)
            load()
            return nil
        } catch { return error.localizedDescription }
    }
    func addCharacter(name: String, look: String) -> String? {
        addLibraryItem("cast", name: name, entry: ["eps": "", "status": "Make", "look": look.trimmingCharacters(in: .whitespacesAndNewlines), "heat": [Int]()])
    }
    func addDish(name: String, look: String) -> String? {
        addLibraryItem("food", name: name, entry: ["eps": "", "who": "", "look": look.trimmingCharacters(in: .whitespacesAndNewlines), "heat": [Int]()])
    }
    /// Makes ART/Locations/<next number> <name> and copies the pictures in. The originals stay where they are.
    func addLocation(name: String, pictures: [URL]) -> String? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !clean.isEmpty else { return "Give the location a name." }
        guard !pictures.isEmpty else { return "Add at least one PNG picture." }
        let fm = FileManager.default
        let existing = (try? fm.contentsOfDirectory(atPath: locationsDir.path)) ?? []
        if existing.contains(where: { String($0.drop { $0.isNumber || $0 == " " }).caseInsensitiveCompare(clean) == .orderedSame }) { return "\(clean) is already in this project." }
        let next = (existing.compactMap { Int($0.prefix { $0.isNumber }) }.max() ?? 0) + 1
        let dir = locationsDir.appendingPathComponent("\(next) \(clean)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for p in pictures { try fm.copyItem(at: p, to: dir.appendingPathComponent(p.lastPathComponent)) }
        } catch { return error.localizedDescription }
        imageVersion += 1
        return nil
    }
    /// The folder under ART/Characters holding a character's locked design. Against the Grain's are listed by hand.
    func designFolder(_ name: String) -> String? {
        hasTrailer ? ["Jasmine": "Jasmine", "Andre": "Andre", "Lena": "Lena", "Chef Laurent Voss": "Chef Voss"][name] : name
    }
    /// Adds a beat at the end of an episode in season.json. Only the end: beat numbers key your images, framing and script edits,
    /// so existing beats never renumber. The last section stretches to include it. Same plain JSON edit and backup as a new episode.
    func addBeat(to e: Episode, text: String) -> (Int?, String?) {
        let clean = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !clean.isEmpty else { return (nil, "Type the beat's line.") }
        let url = dataDir.appendingPathComponent("season.json")
        do {
            let data = try Data(contentsOf: url)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any], var eps = root["eps"] as? [[String: Any]],
                  let i = eps.firstIndex(where: { $0["n"] as? Int == e.n }) else { return (nil, "Couldn't read this project's season file.") }
            var beats = eps[i]["beats"] as? [[String: Any]] ?? []
            let n = (beats.compactMap { $0["n"] as? Int }.max() ?? 0) + 1
            beats.append(["n": n, "text": clean, "kind": "gpt", "img": "N\(n)", "what": ""])   // its own picture code, so beats never share a picture by accident
            eps[i]["beats"] = beats
            eps[i]["words"] = (eps[i]["words"] as? Int ?? 0) + clean.split(separator: " ").count
            if var secs = eps[i]["sections"] as? [[String: Any]], let last = secs.indices.last, let span = secs[last]["span"] as? String {
                let start = span.replacingOccurrences(of: "–", with: "-").split(separator: "-").first.map(String.init) ?? "\(n)"
                secs[last]["span"] = "\(start)–\(n)"
                eps[i]["sections"] = secs
            }
            root["eps"] = eps
            let bak = dataDir.appendingPathComponent("season.json.bak-before-new-episode")
            if !FileManager.default.fileExists(atPath: bak.path) { try FileManager.default.copyItem(at: url, to: bak) }
            try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes]).write(to: url, options: .atomic)
            load()
            return (season?.eps.first { $0.n == e.n }?.beats.contains { $0.n == n } == true ? n : nil, season == nil ? loadError : nil)
        } catch { return (nil, error.localizedDescription) }
    }
    /// Takes a project off the list. Its folder and files stay where they are.
    func removeFromList(_ p: BenchProject) {
        projects.removeAll { $0.id == p.id }; saveProjects()
    }
    func updateProject(_ p: BenchProject) {
        if let i = projects.firstIndex(where: { $0.id == p.id }) { projects[i] = p; saveProjects(); imageVersion += 1 }
    }
}

extension Nav {
    /// Opens a project: the store reads its folder, and the page goes to its first episode (or its season page if it has none).
    func open(_ p: BenchProject, store: Store, listener: Listener, trailer: TrailerModel) {
        listener.stop()
        trailer.audio.stop()
        store.folder = URL(fileURLWithPath: p.folder)
        store.load()
        seasonN = store.seasons.first?.n ?? 1
        if store.hasTrailer { MainActor.assumeIsolated { trailer.reload(store) } }   // always called from the interface
        openSeason(seasonN, store: store)
    }
}

extension Nav {
    /// Shows a season: its first episode, or its season page if it has none yet.
    func openSeason(_ n: Int, store: Store) {
        seasonN = n
        if let first = store.season?.eps.first(where: { $0.seasonN == n }) { go(.ep, ep: first.n) } else { go(.season) }
    }
}

// MARK: - New project and Project settings

struct NewProjectSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let created: (BenchProject) -> Void
    @State var name = ""
    @State var season = "Season 1"
    @State var parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Storybench Projects")
    @State var picking = false
    @State var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.bench(24))
            field("Name") { TextField("Project name", text: $name).textFieldStyle(.roundedBorder) }
            field("Season") { TextField("Season 1", text: $season).textFieldStyle(.roundedBorder) }
            field("Folder") {
                HStack {
                    Text(parent.path).font(.system(size: 12)).foregroundStyle(Color.benchSoft).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { picking = true }
                }
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.benchAmber).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                    let (p, why) = store.createProject(name: name, season: season, parent: parent)
                    if let p { dismiss(); created(p) } else { problem = why }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.benchBlue)
            }
        }
        .padding(22).frame(width: 460).background(Color.benchPanel).foregroundStyle(Color.benchInk)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { if case .success(let u) = $0 { parent = u } }
    }
    func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).font(.system(size: 12)).foregroundStyle(Color.benchSoft).frame(width: 60, alignment: .leading); c() }
    }
}

struct NewEpisodeSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let seasonN: Int
    let created: (Int) -> Void
    @State var title = ""
    @State var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New episode").font(.bench(24))
            Text("Episode \((store.season?.eps.filter { $0.seasonN == seasonN }.count ?? 0) + 1) of \(store.seasons.first { $0.n == seasonN }?.title ?? "this season")").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
            TextField("Episode title", text: $title).textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.benchAmber).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let (n, why) = store.createEpisode(title: title, season: seasonN)
                    if let n { dismiss(); created(n) } else { problem = why }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.benchBlue)
            }
        }
        .padding(22).frame(width: 420).background(Color.benchPanel).foregroundStyle(Color.benchInk)
    }
}

/// Names a new season, or renames one.
struct SeasonNameSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let renaming: SeasonInfo?
    let done: (Int) -> Void
    @State var title = ""
    @State var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(renaming == nil ? "New season" : "Rename season").font(.bench(24))
            if renaming == nil { Text("It shares this project's characters, locations and the rest of the library.").font(.system(size: 12)).foregroundStyle(Color.benchSoft) }
            TextField("Season name", text: $title).textFieldStyle(.roundedBorder)
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.benchAmber).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(renaming == nil ? "Create" : "Save") {
                    if let r = renaming {
                        if let why = store.renameSeason(r.n, title: title) { problem = why } else { dismiss(); done(r.n) }
                    } else {
                        let (n, why) = store.createSeason(title: title)
                        if let n { dismiss(); done(n) } else { problem = why }
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.benchBlue)
            }
        }
        .padding(22).frame(width: 420).background(Color.benchPanel).foregroundStyle(Color.benchInk)
        .onAppear {
            title = renaming?.title ?? "Season \((store.seasons.map(\.n).max() ?? 0) + 1)"
        }
    }
}

/// Adds a character or a dish: a name and a description. Pictures go on its card afterward.
struct AddLibrarySheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let dish: Bool
    @State var name = ""
    @State var look = ""
    @State var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(dish ? "Add dish" : "Add character").font(.bench(24))
            TextField(dish ? "Dish name" : "Character name", text: $name).textFieldStyle(.roundedBorder)
            Text(dish ? "What it looks like" : "What they look like").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
            TextEditor(text: $look).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 110)
                .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.benchAmber).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let why = dish ? store.addDish(name: name, look: look) : store.addCharacter(name: name, look: look) { problem = why } else { dismiss() }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.benchBlue)
            }
        }
        .padding(22).frame(width: 460).background(Color.benchPanel).foregroundStyle(Color.benchInk)
    }
}

/// Adds a location: a name and its pictures, one per camera view.
struct AddLocationSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var name = ""
    @State var pictures: [URL] = []
    @State var picking = false
    @State var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add location").font(.bench(24))
            TextField("Location name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Text(pictures.isEmpty ? "No pictures yet" : "\(pictures.count) picture\(pictures.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                Spacer()
                Button("Choose PNGs…") { picking = true }
            }
            if !pictures.isEmpty {
                Text(pictures.map(\.lastPathComponent).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(Color.benchSoft).lineLimit(3).truncationMode(.middle)
            }
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.benchAmber).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    if let why = store.addLocation(name: name, pictures: pictures) { problem = why } else { dismiss() }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.benchBlue)
            }
        }
        .padding(22).frame(width: 460).background(Color.benchPanel).foregroundStyle(Color.benchInk)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.png], allowsMultipleSelection: true) { if case .success(let u) = $0 { pictures = u } }
    }
}

struct NewBeatSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let e: Episode
    let created: (Int) -> Void
    @State var text = ""
    @State var problem: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add beat").font(.bench(24))
            Text("Beat \((e.beats.map(\.n).max() ?? 0) + 1), at the end of \(e.title)").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
            TextEditor(text: $text).font(.system(size: 14)).scrollContentBackground(.hidden).padding(6).frame(height: 110)
                .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Color.benchAmber).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    let (n, why) = store.addBeat(to: e, text: text)
                    if let n { dismiss(); created(n) } else { problem = why }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.benchBlue)
            }
        }
        .padding(22).frame(width: 460).background(Color.benchPanel).foregroundStyle(Color.benchInk)
    }
}

struct ProjectSettingsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var p: BenchProject
    let removed: () -> Void
    @State var picking = false
    @State var asking = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Project settings").font(.bench(24))
            row("Name") { TextField("Name", text: $p.name).textFieldStyle(.roundedBorder) }
            row("Logo") {
                HStack {
                    Text(store.logoFile(p)?.lastPathComponent ?? "None").font(.system(size: 12)).foregroundStyle(Color.benchSoft).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { picking = true }
                }
            }
            row("Pages") {
                HStack(spacing: 16) {
                    Toggle("Truck", isOn: Binding(get: { p.hideTruck != true }, set: { p.hideTruck = !$0 })).toggleStyle(.checkbox)
                    Toggle("Food", isOn: Binding(get: { p.hideFood != true }, set: { p.hideFood = !$0 })).toggleStyle(.checkbox)
                }.font(.system(size: 12))
            }
            row("Folder") { Text(p.root.path).font(.system(size: 12)).foregroundStyle(Color.benchSoft).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            HStack {
                Button("Remove from list…", role: .destructive) { asking = true }.disabled(store.projects.count < 2)
                    .help(store.projects.count < 2 ? "This is your only project" : "Takes it off the list. The folder stays.")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { store.updateProject(p); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(.benchBlue)
                    .disabled(p.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22).frame(width: 460).background(Color.benchPanel).foregroundStyle(Color.benchInk)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { if case .success(let u) = $0 { p.logo = u.path } }
        .confirmationDialog("Remove \(p.name) from the list?", isPresented: $asking, titleVisibility: .visible) {
            Button("Remove from list", role: .destructive) { store.removeFromList(p); dismiss(); removed() }
        } message: { Text("Nothing is deleted. The folder stays at \(p.root.path).") }
    }
    func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack { Text(label).font(.system(size: 12)).foregroundStyle(Color.benchSoft).frame(width: 60, alignment: .leading); c() }
    }
}

/// The credit balance in the top bar; it opens the Kie tab.
struct CreditsButton: View {
    @EnvironmentObject var nav: Nav
    @State var balance: Double?
    var body: some View {
        Button { nav.go(.kie) } label: {
            Label(balance.map { "\(Int($0).formatted()) credits" } ?? "Credits", systemImage: "cylinder.split.1x2").labelStyle(.titleAndIcon)
        }
        .help("Open the Kie tab")
        .task { if let b = try? await Kie.balance() { balance = b } }
        .onChange(of: nav.tab) { old, _ in
            if old == .kie { Task { if let b = try? await Kie.balance() { balance = b } } }   // back from Kie: it may have changed
        }
    }
}
