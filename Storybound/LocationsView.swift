import SwiftUI

/// Every place in the season in one page: Meridian's painted rooms (ART/Locations, Ep 1) and the truck and lot plates
/// (Ep 2 to 10), with which scenes use each one. A reference: the pictures themselves live on the Plates page and in ART.
struct LocationsView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season
    @State var showing: URL? = nil
    @State var adding = false

    struct Place: Identifiable { var id: String; var name: String; var views: [URL] }

    /// ART/Locations: one folder per place ("1 Kitchen"), one painting per camera ("CAM-02 Cooking Line.png").
    var meridian: [Place] {
        let root = store.dataDir.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ART/Locations")
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return folders.compactMap { f in
            let dir = root.appendingPathComponent(f)
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".png") && !$0.hasPrefix("_") && !$0.hasPrefix(".") }
                .sorted { a, b in
                    // the cameras first, the design sheet last
                    let da = a.hasPrefix("Design"), db = b.hasPrefix("Design")
                    return da == db ? a.localizedStandardCompare(b) == .orderedAscending : !da
                }
            guard !files.isEmpty else { return nil }
            let name = f.drop { $0.isNumber || $0 == " " }
            return Place(id: f, name: String(name), views: files.map { dir.appendingPathComponent($0) })
        }
    }

    /// The Ep 1 scenes drawn from or edited on this picture.
    func uses(_ url: URL) -> [Storyboard] { (store.storyboards[1] ?? []).filter { $0.ref == url.path } }

    /// The truck and lot plates, grouped by camera: T1 (day, night ...), T2, P1 ...
    var plateGroups: [(String, [PlateInfo])] {
        var order: [String] = [], groups: [String: [PlateInfo]] = [:]
        for p in store.plates {
            let g = String(p.id.split(separator: " ").first ?? Substring(p.id))
            if groups[g] == nil { order.append(g) }
            groups[g, default: []].append(p)
        }
        return order.map { ($0, groups[$0]!) }
    }

    func episodes(_ plate: String) -> [Int] {
        season.eps.map(\.n).filter { n in (store.storyboards[n] ?? []).contains { $0.plateKey == plate } }
    }

    var body: some View {
        let _ = store.imageVersion
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(store.hasTrailer ? "Every place in the season. Meridian's rooms are already painted (ART/Locations) and Episode 1's scenes are drawn from them. The truck and the lot are the plates: drop their sketches and paintings on the Plates page." : "Every place in this project, shared by all its seasons. Each location holds its pictures in ART/Locations.")
                    .foregroundStyle(.secondary).frame(maxWidth: 900, alignment: .leading)

                Text(store.hasTrailer ? "Meridian · Episode 1" : "Locations").font(.serif(24)).padding(.top, 6)
                ForEach(meridian) { place in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(place.name).font(.serif(19))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(place.views, id: \.self) { url in
                                let used = uses(url)
                                VStack(alignment: .leading, spacing: 4) {
                                    LocationThumb(url: url).onTapGesture { showing = url }
                                    Text(url.deletingPathExtension().lastPathComponent).font(.system(size: 12, weight: .semibold))
                                    Text(used.isEmpty ? " " : used.map { "\($0.id) (beats \($0.beats.map(String.init).joined(separator: ", ")))" }.joined(separator: " · "))
                                        .font(.system(size: 11)).foregroundStyle(Color.gold).lineLimit(2)
                                }
                            }
                        }
                    }.padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                }

                if store.hasTrailer || !store.plates.isEmpty {
                Text(store.hasTrailer ? "The truck and the lot · Episodes 2 to 10" : "Backgrounds").font(.serif(24)).padding(.top, 18)
                }
                ForEach(plateGroups, id: \.0) { group, plates in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(group) · \(plates[0].name.components(separatedBy: ",").first ?? plates[0].name)").font(.serif(19))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(plates) { p in
                                let key = store.plateShownKey(p.id)
                                let eps = episodes(p.id)
                                VStack(alignment: .leading, spacing: 4) {
                                    ZStack {
                                        Color(hex: 0x2a2520)
                                        if let k = key, let i = store.cardImage(k) { i.resizable().scaledToFit() }
                                        else { Text("Not drawn yet").font(.system(size: 12)).foregroundStyle(Color.soft) }
                                    }
                                    .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                    .onTapGesture { if p.scenes > 0 { nav.path.append(.plate(p.id)) } }
                                    HStack(spacing: 6) {
                                        Text(p.id).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.gold)
                                        Text(key == nil ? "empty" : key!.hasPrefix("plate-paint") ? "painted" : "sketch")
                                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.soft)
                                    }
                                    Text(p.name).font(.system(size: 11)).lineLimit(2)
                                    Text(eps.isEmpty ? "No episode yet" : (eps.count == 1 ? "Episode " : "Episodes ") + eps.map(String.init).joined(separator: ", ") + " · \(p.beats) beats")
                                        .font(.system(size: 11)).foregroundStyle(Color.soft)
                                }
                            }
                        }
                    }.padding(14).background(Color.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .navigationTitle("Locations")
        .navigationSubtitle(store.hasTrailer ? "\(meridian.count) Meridian places · \(store.plates.count) truck and lot plates" : "\(meridian.count) location\(meridian.count == 1 ? "" : "s")")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: { Label("Add location", systemImage: "plus") }.help("Add a location to this project")
            }
        }
        .sheet(isPresented: $adding) { AddLocationSheet() }
        .sheet(item: Binding(get: { showing.map(IdentifiedURL.init) }, set: { showing = $0?.url })) { item in
            VStack(spacing: 10) {
                HStack {
                    Text(item.url.deletingPathExtension().lastPathComponent).font(.serif(20))
                    Spacer()
                    Button("Close") { showing = nil }.keyboardShortcut(.cancelAction)
                }
                if let i = loadImage(item.url, maxPixel: 2400) { i.resizable().scaledToFit() }
                Text(item.url.path).font(.system(size: 11)).foregroundStyle(.tertiary).textSelection(.enabled)
            }.padding(20).frame(minWidth: 900, minHeight: 600)
        }
    }
}

struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.path } }

/// A small copy of a location painting, loaded once off the main thread so the page scrolls smoothly.
struct LocationThumb: View {
    let url: URL
    @State var image: Image? = nil
    var body: some View {
        ZStack {
            Color(hex: 0x2a2520)
            if let image { image.resizable().scaledToFit() }
        }
        .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .task(id: url) { image = await Task.detached { loadImage(url, maxPixel: 900) }.value }
    }
}
