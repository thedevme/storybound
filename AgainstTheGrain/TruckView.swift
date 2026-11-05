import SwiftUI

/// The truck: the layout text, the floor plan, and the views. Edit turns on text editing and adding views;
/// images can be dropped on the plan or on any view at any time.
struct TruckView: View {
    @EnvironmentObject var store: Store
    let season: Season
    @State var editing = false

    var layout: String { store.state.truckLayout ?? season.truck.layout }
    var views: [[String]] { store.state.truckViews ?? season.truck.views }
    var changed: Bool { store.state.truckLayout != nil || store.state.truckViews != nil }

    var body: some View {
        let _ = store.imageVersion
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if editing {
                    TextEditor(text: Binding(get: { layout }, set: { store.state.truckLayout = $0; store.save() }))
                        .font(.system(size: 15)).scrollContentBackground(.hidden).padding(8).frame(minHeight: 140)
                        .background(Color.panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gold))
                } else {
                    Text(layout).foregroundStyle(Color.soft).font(.system(size: 15)).frame(maxWidth: 900, alignment: .leading)
                }

                TruckImage(key: "truck:plan", fallback: store.plan, label: "the floor plan", aspect: nil)

                Text(views.count == 3 ? "The three views" : "The views").font(.serif(26)).padding(.top, 10)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 16)], spacing: 16) {
                    ForEach(Array(views.enumerated()), id: \.offset) { i, v in viewCard(i, v) }
                }
            }.padding(28).frame(maxWidth: 1500, alignment: .leading)
        }
        .navigationTitle("The truck")
        .navigationSubtitle(store.hasTrailer ? "A 22-foot truck, a crew of four" : store.projectName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if editing {
                    Button { addView() } label: { Label("Add a view", systemImage: "plus") }
                    if changed {
                        Button("Reset Text") {
                            store.state.truckLayout = nil; store.state.truckViews = nil; store.save(); store.say("Truck text reset")
                        }.help("Put the layout and view text back to the original")
                    }
                }
                Button(editing ? "Done" : "Edit") { editing.toggle() }.keyboardShortcut("e", modifiers: .command)
            }
        }
    }

    func cell(_ v: [String], _ i: Int) -> String { i < v.count ? v[i] : "" }

    @ViewBuilder func viewCard(_ i: Int, _ v: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TruckImage(key: "truck:view:\(cell(v, 0))", fallback: nil, label: "a picture of \(cell(v, 0))", aspect: 16 / 9)
            if editing {
                HStack(spacing: 8) {
                    Text(cell(v, 0)).font(.serif(20)).foregroundStyle(Color.gold)
                    TextField("Name", text: Binding(get: { cell(v, 1) }, set: { update(i, 1, $0) }))
                        .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) { removeView(i) } label: { Label("Remove this view", systemImage: "trash").labelStyle(.iconOnly) }
                        .buttonStyle(.borderless).help("Remove this view")
                }
                TextEditor(text: Binding(get: { cell(v, 2) }, set: { update(i, 2, $0) }))
                    .font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(minHeight: 90)
                    .background(Color.panel, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.line))
            } else {
                Text("\(cell(v, 0)) · \(cell(v, 1))").font(.serif(20))
                Text(cell(v, 2)).font(.system(size: 13)).foregroundStyle(Color.soft).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.line))
    }

    func update(_ i: Int, _ j: Int, _ val: String) {
        var vs = views
        while vs[i].count <= j { vs[i].append("") }
        vs[i][j] = val
        store.state.truckViews = vs; store.save()
    }
    func addView() {
        var vs = views
        var n = vs.count + 1
        while vs.contains(where: { cell($0, 0) == "V\(n)" }) { n += 1 }
        vs.append(["V\(n)", "New view", ""])
        store.state.truckViews = vs; store.save()
    }
    func removeView(_ i: Int) {
        var vs = views
        let id = cell(vs[i], 0)
        vs.remove(at: i)
        store.state.truckViews = vs; store.save()
        if store.hasImage("truck:view:\(id)") { store.removeImage("truck:view:\(id)") }
    }
}

/// A truck picture you can replace: drop an image on it or click to choose one.
struct TruckImage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let key: String
    let fallback: Image?
    let label: String
    let aspect: CGFloat?
    @State var target = false
    @State var hover = false

    var body: some View {
        let mine = store.image(key)
        let img = mine ?? fallback
        ZStack {
            if let img {
                img.resizable().scaledToFit()
            } else {
                Color(hex: 0x2a2520)
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 22))
                    Text("Drop \(label) here, or click to choose").font(.system(size: 12))
                }.foregroundStyle(Color.soft)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(img == nil ? (aspect ?? 16 / 9) : nil, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(target ? Color.gold : (img == nil ? Color.line : .clear),
                                                           style: StrokeStyle(lineWidth: target ? 2.5 : 1.5, dash: img == nil ? [5] : [])))
        .overlay(alignment: .topTrailing) {
            if hover || target {
                HStack(spacing: 6) {
                    if let u = store.userFile(key) { RevealButton(url: u, label: "Show in Finder").buttonStyle(.bordered) }
                    Button("Replace…") { pick() }
                    if mine != nil { Button(fallback == nil ? "Remove" : "Use the Original", role: .destructive) { store.removeImage(key) } }
                }.controlSize(.small).padding(10)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if img == nil { pick() } }
        .fileDrop(targeted: $target) { store.setImage(key, from: $0) }
        .help("Drop an image to replace \(label)")
    }
    func pick() { nav.choose([.image]) { store.setImage(key, from: $0) } }
}
