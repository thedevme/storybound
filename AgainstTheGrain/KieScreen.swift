import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - The Kie screen: the form on the left, your pictures on the right. Exactly the prompt box's text is sent.

extension Color {
    static let kieBG = Color(hex: 0x121418), kiePanel = Color(hex: 0x181a1f), kieCard = Color(hex: 0x202227), kieRaised = Color(hex: 0x2a2c32)
    static let kieLine = Color(hex: 0x34373e), kieInk = Color(hex: 0xeceef2), kieSoft = Color(hex: 0xa4a8b2), kieMute = Color(hex: 0x6c707a)
}

struct KieTab: View {
    @EnvironmentObject var store: Store
    @ObservedObject var studio = KieStudio.shared
    @State var confirming = false
    @State var gallery = false
    @State var removing: KieResult? = nil
    @State var choosingRefs = false
    @State var keyMonitor: Any? = nil
    @State var removeFailed: String? = nil
    @State var viewingRef: URL? = nil   // a reference or edit picture shown large
    @State var presetPage = 0        // Presets, My Presets, Favorites
    @State var naming = false
    @State var presetName = ""
    @State var bottomPage = 0        // Generations, Reference Images
    @State var refTarget = false

    var body: some View {
        HStack(spacing: 0) {
            form.frame(width: 340).background(Color.kiePanel)
            Rectangle().fill(Color.kieLine).frame(width: 1)
            VStack(spacing: 0) {
                header
                Group { if let viewingRef { refViewer(viewingRef) } else if gallery { galleryView } else { grid } }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Color.kieLine).frame(height: 1)
                bottom
            }.background(Color.kieBG)
        }
        .foregroundStyle(Color.kieInk)
        .onChange(of: studio.shown) { _, _ in viewingRef = nil }
        .onAppear {
            // left and right move through Gallery, unless you're typing in the prompt or search box
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard gallery, viewingRef == nil, !removingOpen, event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function]).isEmpty,
                      !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
                switch event.keyCode {
                case 123: stepGallery(-1); return nil
                case 124: stepGallery(1); return nil
                default: return event
                }
            }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
        .confirmationDialog("Move this picture to the Trash?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { r in
            Button("Move to Trash", role: .destructive) { removeFailed = studio.remove(r); removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { r in Text("\(r.file) and its saved prompt go to the Trash. You can put them back from there.") }
        .alert("Couldn't move it to the Trash", isPresented: Binding(get: { removeFailed != nil }, set: { if !$0 { removeFailed = nil } })) { Button("OK") {} } message: { Text(removeFailed ?? "") }
        .navigationTitle("Kie")
        .onAppear {
            studio.folder = Store.kieFolder
            studio.load(); studio.refreshBalance()
        }
        .alert("Is this right?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Submit") { studio.submit() }
        } message: {
            Text("\(studio.mode.rawValue) · \(studio.choice.rawValue) · \(studio.res) · \(studio.aspect)\n\(studio.count) job\(studio.count == 1 ? "" : "s") · \(studio.sentRefs.count) image\(studio.sentRefs.count == 1 ? "" : "s") attached\n\(costLine)")
        }
        .alert("Save as preset", isPresented: $naming) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let n = presetName.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { return }
                studio.myPresets.removeAll { $0.name == n }
                studio.myPresets.append(KiePreset(name: n, note: "Your preset", text: studio.prompt))
                presetPage = 1
            }
        }
    }

    var costLine: String {
        if let c = studio.estimate {
            let total = c * max(1, studio.count)
            return "About \(total) credits · $\(String(format: "%.2f", Double(total) * creditDollars))"
        }
        return "No price seen yet for this setting. The real cost saves after it runs."
    }

    // MARK: the form

    var form: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    modeTabs
                    if studio.mode == .animate {
                        Text("Animate isn't connected yet.").font(.system(size: 13)).foregroundStyle(Color.kieSoft).padding(.vertical, 20)
                    } else {
                        modelCard
                        if studio.mode == .edit { editSlot }
                        promptBox
                        presets
                        references
                    }
                }.padding(14)
            }.scrollIndicators(.never)
            if studio.mode != .animate { generateBar }
        }
    }

    var modeTabs: some View {
        HStack(spacing: 2) {
            ForEach(KieMode.allCases, id: \.self) { m in
                Button { studio.mode = m } label: {
                    Text(m.rawValue).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 30)
                        .background(studio.mode == m ? Color.gold.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                }.buttonStyle(.plain).foregroundStyle(studio.mode == m ? Color.gold : Color.kieSoft)
            }
        }
    }

    func label(_ t: String) -> some View { Text(t).font(.system(size: 13, weight: .semibold)) }

    var modelCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Model & Tool")
            Menu {
                ForEach(KieChoice.allCases) { c in Button(c.rawValue) { studio.choice = c } }
            } label: {
                HStack {
                    Text(studio.choice.rawValue).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("Image").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 8).frame(height: 18).background(Color.built, in: Capsule()).foregroundStyle(.white)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.kieSoft)
                }
                .padding(.horizontal, 10).frame(height: 38)
                .background(Color.kieCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kieLine)).contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            HStack(spacing: 6) {
                setting(studio.res, ["1K", "2K", "4K"]) { studio.res = $0 }
                setting(studio.aspect, KieStudio.ratios) { studio.aspect = $0 }
                setting("\(studio.count) image\(studio.count == 1 ? "" : "s")", (1...6).map { "\($0) image\($0 == 1 ? "" : "s")" }) { studio.count = Int($0.prefix(1)) ?? 1 }
            }
        }
    }
    func setting(_ now: String, _ all: [String], _ pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(all, id: \.self) { a in Button(a) { pick(a) } }
        } label: {
            HStack(spacing: 4) { Text(now).font(.system(size: 12)); Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Color.kieSoft) }
                .frame(maxWidth: .infinity).frame(height: 28)
                .background(Color.kieCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kieLine)).contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }

    var editSlot: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Picture to edit")
            if let u = studio.editSource {
                ZStack(alignment: .topTrailing) {
                    PanelImage(url: u, maxPixel: 500, fit: true).frame(maxWidth: .infinity).frame(height: 130).background(Color.kieCard).clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle()).onTapGesture { viewingRef = u }.help("Click to view larger")
                    removeButton { studio.editSource = nil }.padding(5)
                }
            } else {
                dropBox("Click Edit on any picture", "or drop one here", height: 80) { urls in studio.editSource = urls.first } browse: { pick(multiple: false) { studio.editSource = $0.first } }
            }
        }
    }

    var promptBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            label("Prompt")
            ZStack(alignment: .bottomTrailing) {
                TextEditor(text: $studio.prompt).font(.system(size: 13)).scrollContentBackground(.hidden).padding(6).frame(height: 110)
                    .background(Color.kieCard, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kieLine))
                Text("\(studio.prompt.count)").font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.kieMute).padding(8).allowsHitTesting(false)
            }
            HStack(spacing: 6) {
                chip("Enhance", "sparkles").disabled(true).help("Enhance isn't connected yet")
                chip("Surprise me", "dice").disabled(true).help("Surprise me isn't connected yet")
                Button { presetName = ""; naming = true } label: { chipLabel("Save preset", "bookmark") }.buttonStyle(.plain)
                    .disabled(studio.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    func chip(_ t: String, _ icon: String) -> some View { chipLabel(t, icon).opacity(0.45) }
    func chipLabel(_ t: String, _ icon: String) -> some View {
        HStack(spacing: 4) { Image(systemName: icon).font(.system(size: 10)); Text(t).font(.system(size: 11)).lineLimit(1) }
            .padding(.horizontal, 8).frame(height: 26).frame(maxWidth: .infinity)
            .background(Color.kieCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kieLine)).contentShape(Rectangle())
    }

    var listedPresets: [KiePreset] {
        switch presetPage {
        case 1: return studio.myPresets
        case 2: return (KiePreset.builtIn + studio.myPresets).filter { studio.favorites.contains($0.name) }
        default: return KiePreset.builtIn
        }
    }
    var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                ForEach(Array(["Presets", "My Presets", "Favorites"].enumerated()), id: \.offset) { i, t in
                    Button { presetPage = i } label: {
                        Text(t).font(.system(size: 12, weight: presetPage == i ? .semibold : .regular)).foregroundStyle(presetPage == i ? Color.kieInk : Color.kieSoft)
                            .padding(.bottom, 3).overlay(alignment: .bottom) { if presetPage == i { Rectangle().fill(Color.gold).frame(height: 2) } }
                    }.buttonStyle(.plain)
                }
            }
            if listedPresets.isEmpty {
                Text(presetPage == 1 ? "Type a prompt and press Save as preset." : "Right-click a preset to add it to Favorites.").font(.system(size: 11)).foregroundStyle(Color.kieSoft).padding(.vertical, 8)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(listedPresets) { p in presetTile(p) }
            }
        }
    }
    func presetTile(_ p: KiePreset) -> some View {
        Button {
            let now = studio.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            studio.prompt = now.isEmpty ? p.text : now + "\n\n" + p.text
        } label: {
            HStack(spacing: 7) {
                Image(systemName: p.icon).font(.system(size: 13)).foregroundStyle(Color.gold).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(p.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Text(p.note).font(.system(size: 10)).foregroundStyle(Color.kieSoft).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).frame(height: 42)
            .background(Color.kieCard, in: RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.kieLine)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(p.text)
        .contextMenu {
            let fav = studio.favorites.contains(p.name)
            Button(fav ? "Remove from Favorites" : "Add to Favorites") { if fav { studio.favorites.removeAll { $0 == p.name } } else { studio.favorites.append(p.name) } }
            if studio.myPresets.contains(p) { Button("Delete preset", role: .destructive) { studio.myPresets.removeAll { $0 == p }; studio.favorites.removeAll { $0 == p.name } } }
        }
    }

    var references: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                label("Reference Images")
                Spacer()
                if !studio.refs.isEmpty { Button("Clear all") { studio.refs = [] }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.gold) }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                ForEach(studio.refs, id: \.self) { u in
                    ZStack(alignment: .topTrailing) {
                        PanelImage(url: u, maxPixel: 240, fit: true).frame(maxWidth: .infinity).frame(height: 76).background(Color.kieCard).clipShape(RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle()).onTapGesture { viewingRef = u }.help("Click to view larger")
                        removeButton { studio.refs.removeAll { $0 == u } }.padding(3)
                    }.help(u.lastPathComponent)
                }
                dropBox("Add images", "Drag & drop", height: 76) { studio.addRefs($0) } browse: { pick(multiple: true) { studio.addRefs($0) } }
                Button { choosingRefs = true } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "photo.on.rectangle.angled").font(.system(size: 14))
                        Text("From gallery").font(.system(size: 10, weight: .medium))
                        Text("Your pictures").font(.system(size: 9)).foregroundStyle(Color.kieSoft)
                    }
                    .frame(maxWidth: .infinity).frame(height: 76)
                    .background(Color.kieCard, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.kieLine, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Choose pictures you've made here as references")
                .popover(isPresented: $choosingRefs, arrowEdge: .trailing) { KieRefPicker(studio: studio) }
            }
            Toggle("Use references in prompt", isOn: $studio.useRefs).toggleStyle(.checkbox).font(.system(size: 11))
        }
    }
    func removeButton(_ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 18, height: 18).background(.black.opacity(0.7), in: Circle()).foregroundStyle(.white).contentShape(Circle())
        }.buttonStyle(.plain)
    }
    func dropBox(_ title: String, _ note: String, height: CGFloat, drop: @escaping ([URL]) -> Void, browse: @escaping () -> Void) -> some View {
        VStack(spacing: 3) {
            Image(systemName: "plus.circle").font(.system(size: 14))
            Text(title).font(.system(size: 10, weight: .medium)).multilineTextAlignment(.center)
            Text(note).font(.system(size: 9)).foregroundStyle(Color.kieSoft)
        }
        .frame(maxWidth: .infinity).frame(height: height)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(refTarget ? Color.gold : Color.kieLine, style: StrokeStyle(lineWidth: 1, dash: [4])))
        .contentShape(Rectangle())
        .onTapGesture(perform: browse)
        .dropDestination(for: URL.self) { urls, _ in drop(urls); return true } isTargeted: { refTarget = $0 }
    }
    func pick(multiple: Bool, _ done: ([URL]) -> Void) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = multiple; p.canChooseDirectories = false; p.allowedContentTypes = [.image]
        if p.runModal() == .OK { done(p.urls) }
    }

    var generateBar: some View {
        VStack(spacing: 6) {
            Button { confirming = true } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text(studio.mode == .edit ? "Edit Image" : "Generate").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(estimateShort).font(.system(size: 11))
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(studio.canSubmit ? Color.gold : Color.gold.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(Color.dark).contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(!studio.canSubmit)
            HStack(spacing: 6) {
                if let b = studio.balance {
                    Text("\(Int(b).formatted()) credits · $\(String(format: "%.2f", b * creditDollars))").foregroundStyle(Color.gold).monospacedDigit()
                } else { Text(studio.balanceFailed ? "Balance unavailable" : "Balance: checking…").foregroundStyle(Color.kieSoft) }
                Button { studio.refreshBalance() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).foregroundStyle(Color.kieSoft).help("Check the balance again")
                Spacer()
            }.font(.system(size: 11))
        }.padding(12).background(Color.kiePanel)
    }
    var estimateShort: String {
        let n = "\(studio.count) image\(studio.count == 1 ? "" : "s")"
        if let c = studio.estimate { return "\(n) · about \(c * max(1, studio.count)) credits" }
        return n
    }

    // MARK: the pictures

    var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Generations").font(.bench(22))
                Text("\(studio.results.count) picture\(studio.results.count == 1 ? "" : "s")\(studio.runs.isEmpty ? "" : " · \(studio.runs.filter { !$0.failed }.count) running")").font(.system(size: 11)).foregroundStyle(Color.kieSoft)
            }
            Spacer()
            HStack(spacing: 2) {
                viewToggle("Grid", "square.grid.2x2.fill", !gallery && viewingRef == nil) { gallery = false; viewingRef = nil }
                viewToggle("Gallery", "photo", gallery && viewingRef == nil) { gallery = true; viewingRef = nil }
            }.padding(2).background(Color.kieCard, in: RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.kieSoft)
                TextField("Search generations…", text: $studio.query).textFieldStyle(.plain).font(.system(size: 12))
            }.padding(.horizontal, 8).frame(width: 170, height: 28).background(Color.kieCard, in: RoundedRectangle(cornerRadius: 7))
            Menu {
                Button("Newest") { studio.oldestFirst = false }
                Button("Oldest") { studio.oldestFirst = true }
            } label: {
                HStack(spacing: 4) { Text(studio.oldestFirst ? "Oldest" : "Newest").font(.system(size: 12)); Image(systemName: "chevron.down").font(.system(size: 9)) }
                    .padding(.horizontal, 9).frame(height: 28).background(Color.kieCard, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
            }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }
    func viewToggle(_ t: String, _ icon: String, _ on: Bool, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Label(t, systemImage: icon).font(.system(size: 11)).padding(.horizontal, 9).frame(height: 24)
                .background(on ? Color.kieRaised : .clear, in: RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(on ? Color.kieInk : Color.kieSoft)
    }

    var grid: some View {
        ScrollView {
            let list = studio.shownResults
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(studio.runs) { r in runCard(r) }
                ForEach(list) { r in resultCard(r) }
            }.padding(14)
            if list.isEmpty && studio.runs.isEmpty {
                Text(studio.results.isEmpty ? "Pictures you make here show up here." : "No pictures match.").foregroundStyle(Color.kieSoft).padding(.top, 60)
            }
        }.scrollIndicators(.never)
    }
    func runCard(_ r: KieRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(r.title).font(.system(size: 11, weight: .semibold))
            ZStack {
                Color.kieRaised
                VStack(spacing: 8) {
                    if r.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.red2) } else { KieRunProgress(run: r) }
                    Text(r.status).font(.system(size: 11)).foregroundStyle(r.failed ? Color.red2 : Color.kieSoft).multilineTextAlignment(.center).textSelection(.enabled).padding(.horizontal, 10)
                    if r.failed { Button("Dismiss") { studio.dismiss(r.id) }.controlSize(.small) }
                }
            }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 6))
        }.padding(9).background(Color.kieCard, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.kieLine))
    }
    func stamp(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }
    func resultCard(_ r: KieResult) -> some View {
        let sel = studio.shown == r
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(r.choice.rawValue).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                Text(stamp(r.date)).font(.system(size: 10)).foregroundStyle(Color.kieSoft).lineLimit(1)
                Spacer(minLength: 2)
                resultMenu(r)
            }
            Color.black.aspectRatio(16 / 9, contentMode: .fit)
                .overlay(PanelImage(url: studio.url(r), maxPixel: 700, fit: true))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(r.prompt).font(.system(size: 11)).foregroundStyle(Color.kieSoft).lineLimit(2, reservesSpace: true).help(r.prompt)
            HStack(spacing: 8) {
                Text(r.res); Text(r.aspect)
                if let c = r.credits { Text("\(c) cr") }
                Spacer(minLength: 2)
                smallButton("Use", "arrow.up.doc") { studio.use(r) }.help("Put this prompt and its settings back in the form").fixedSize()
                smallButton("Edit", "pencil") { edit(r) }.help("Edit this picture").fixedSize()
                finderIcon(r)
            }.font(.system(size: 10)).foregroundStyle(Color.kieSoft)
        }
        .padding(9)
        .background(Color.kieCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(sel ? Color.gold : Color.kieLine, lineWidth: sel ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { studio.shown = r; gallery = true }
        .onTapGesture { studio.shown = r }
    }
    func edit(_ r: KieResult) {
        studio.editSource = studio.url(r); studio.mode = .edit; studio.prompt = r.prompt; studio.choice = r.choice; studio.res = r.res; studio.aspect = r.aspect
    }
    @ViewBuilder func finderButton(_ r: KieResult) -> some View {
        if let u = studio.url(r) {
            smallButton("Finder", "folder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }.help("Show in Finder")
        }
    }
    /// The same button for a grid card, where the word doesn't fit beside Use and Edit.
    @ViewBuilder func finderIcon(_ r: KieResult) -> some View {
        if let u = studio.url(r) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([u]) } label: {
                Image(systemName: "folder").font(.system(size: 10, weight: .medium)).frame(width: 24, height: 22)
                    .background(Color.kieRaised, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(Color.kieInk).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Show in Finder")
        }
    }
    func smallButton(_ t: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Label(t, systemImage: icon).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).frame(height: 22)
                .background(Color.kieRaised, in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(Color.kieInk).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    func resultMenu(_ r: KieResult) -> some View {
        Menu {
            Button("Open in Gallery") { studio.shown = r; gallery = true }
            Button("Copy prompt") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(r.prompt, forType: .string) }
            if let u = studio.url(r) {
                Button("Add as reference") { studio.addRefs([u]) }
            }
            Divider()
            Button("Move to Trash…", role: .destructive) { removing = r }
        } label: { Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Color.kieSoft)
    }

    /// A reference picture at full size, in the same zoomable view as Gallery.
    func refViewer(_ u: URL) -> some View {
        ZoomableImage(url: u, spacePan: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            .overlay(alignment: .topTrailing) { KieZoomControls().padding(8) }
            .overlay(alignment: .topLeading) {
                Button { viewingRef = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                        .background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white).contentShape(Circle())
                }.buttonStyle(.plain).padding(8).help("Close")
            }
            .overlay(alignment: .bottomLeading) {
                Text(u.lastPathComponent).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    .padding(.horizontal, 8).frame(height: 22).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6)).padding(8)
            }
            .padding(10)
    }

    var removingOpen: Bool { removing != nil || removeFailed != nil || choosingRefs || confirming }
    /// Where the shown picture is in the list the grid shows, so Gallery goes through them in the same order.
    var galleryIndex: Int? { studio.shown.flatMap { studio.shownResults.firstIndex(of: $0) } }
    func stepGallery(_ d: Int) {
        let list = studio.shownResults
        guard !list.isEmpty else { return }
        guard let i = galleryIndex else { studio.shown = list.first; return }
        let j = i + d
        if list.indices.contains(j) { studio.shown = list[j] }
    }
    func galleryArrow(_ icon: String, _ d: Int, _ tip: String) -> some View {
        let can = galleryIndex.map { studio.shownResults.indices.contains($0 + d) } ?? false
        return Button { stepGallery(d) } label: {
            Image(systemName: icon).font(.system(size: 15, weight: .bold)).frame(width: 38, height: 38)
                .background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white).contentShape(Circle())
        }.buttonStyle(.plain).disabled(!can).opacity(can ? 1 : 0.25).padding(10).help(tip)
    }

    @ViewBuilder var galleryView: some View {
        if let r = studio.shown, let u = studio.url(r) {
            VStack(alignment: .leading, spacing: 8) {
                ZoomableImage(url: u, spacePan: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .overlay(alignment: .topTrailing) { KieZoomControls().padding(8) }
                    .overlay(alignment: .leading) { galleryArrow("chevron.left", -1, "Previous picture (←)") }
                    .overlay(alignment: .trailing) { galleryArrow("chevron.right", 1, "Next picture (→)") }
                    .overlay(alignment: .topLeading) {
                        Button { gallery = false } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28)
                                .background(.black.opacity(0.55), in: Circle()).foregroundStyle(.white).contentShape(Circle())
                        }
                        .buttonStyle(.plain).padding(8).keyboardShortcut(.cancelAction).help("Close and go back to the grid (Esc)")
                    }
                HStack(spacing: 8) {
                    Text("\(r.choice.rawValue) · \(r.res) · \(r.aspect)\(r.credits.map { " · \($0) credits" } ?? "")").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    smallButton("Use", "arrow.up.doc") { studio.use(r) }
                    smallButton("Edit", "pencil") { edit(r) }
                    finderButton(r)
                    if let u = studio.url(r) {
                        smallButton(studio.refs.contains(u) ? "Reference ✓" : "Reference", "photo.badge.plus") {
                            if studio.refs.contains(u) { studio.refs.removeAll { $0 == u } } else { studio.addRefs([u]) }
                        }.help("Use this picture as a reference, or take it back out")
                    }
                    smallButton("Trash", "trash") { removing = r }
                    resultMenu(r)
                }
                ScrollView { Text(r.prompt).font(.system(size: 12)).foregroundStyle(Color.kieSoft).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 56)
            }.padding(14)
        } else {
            Text("Pick a picture below.").foregroundStyle(Color.kieSoft).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Every image used as a reference so far, newest first.
    var pastRefs: [URL] {
        var seen = Set<String>(), out: [URL] = []
        for r in studio.results { for p in r.refs where seen.insert(p).inserted && FileManager.default.fileExists(atPath: p) { out.append(URL(fileURLWithPath: p)) } }
        return out
    }

    var bottom: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                bottomTab("Generations", 0)
                bottomTab("Reference Images", 1)
                Text("Videos").font(.system(size: 11)).foregroundStyle(Color.kieMute).padding(.horizontal, 10).help("Videos aren't connected yet")
            }
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    if bottomPage == 0 {
                        Button { studio.prompt = ""; studio.mode = .generate; studio.editSource = nil } label: {
                            VStack(spacing: 2) { Image(systemName: "plus").font(.system(size: 14)); Text("New").font(.system(size: 10)) }
                                .frame(width: 92, height: 62).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kieLine, style: StrokeStyle(lineWidth: 1, dash: [4]))).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("Clear the form for a new prompt")
                        ForEach(studio.shownResults) { r in
                            Button { studio.shown = r } label: {
                                PanelImage(url: studio.url(r), maxPixel: 240, fit: true).frame(width: 110, height: 62).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(studio.shown == r ? Color.gold : .clear, lineWidth: 2))
                            }.buttonStyle(.plain)
                        }
                    } else {
                        if pastRefs.isEmpty { Text("Images you've used as references show up here.").font(.system(size: 11)).foregroundStyle(Color.kieSoft).frame(height: 62) }
                        ForEach(pastRefs, id: \.self) { u in
                            Button { studio.addRefs([u]) } label: {
                                PanelImage(url: u, maxPixel: 240, fit: true).frame(width: 110, height: 62).background(Color.black).clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(studio.refs.contains(u) ? Color.gold : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).help("Click to add \(u.lastPathComponent) to the references. Double-click to view larger.")
                            .simultaneousGesture(TapGesture(count: 2).onEnded { viewingRef = u })
                            .contextMenu { Button("View larger") { viewingRef = u } }
                        }
                    }
                }.padding(2)
            }.frame(height: 66).scrollIndicators(.never)
        }.padding(.horizontal, 14).padding(.vertical, 8).background(Color.kiePanel)
    }
    func bottomTab(_ t: String, _ i: Int) -> some View {
        Button { bottomPage = i } label: {
            Text(t).font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).frame(height: 24)
                .background(bottomPage == i ? Color.gold.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(bottomPage == i ? Color.gold : Color.kieSoft)
    }
}

/// Over the gallery picture: how to zoom, and the way back to the whole picture.
struct KieZoomControls: View {
    @ObservedObject var zoom = ZoomState.shared
    var body: some View {
        HStack(spacing: 8) {
            Text("Scroll or pinch to zoom · hold space and drag to pan · double-click for 2×").font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
            if zoom.zoomed {
                Button { zoom.reset() } label: { Label("Fit", systemImage: "arrow.down.right.and.arrow.up.left") }.controlSize(.small).help("Back to the whole picture")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Where a request is: its steps, the time so far, and a percent bar only if Kie reports one.
struct KieRunProgress: View {
    let run: KieRun
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(KieRun.steps.indices, id: \.self) { i in
                    VStack(spacing: 4) {
                        Capsule().fill(i < run.step ? Color.gold : i == run.step ? Color.gold.opacity(0.55) : Color.kieLine).frame(height: 4)
                        Text(KieRun.steps[i]).font(.system(size: 9, weight: i == run.step ? .semibold : .regular))
                            .foregroundStyle(i == run.step ? Color.kieInk : Color.kieSoft).lineLimit(1).minimumScaleFactor(0.7)
                    }.frame(maxWidth: .infinity)
                }
            }
            if let p = run.percent { ProgressView(value: min(100, max(0, p)), total: 100).controlSize(.small).tint(.gold) }
            TimelineView(.periodic(from: .now, by: 1)) { c in
                let e = max(0, Int(c.date.timeIntervalSince(run.started)))
                Text(String(format: "%d:%02d", e / 60, e % 60) + (run.percent.map { String(format: " · %.0f%%", $0) } ?? "")).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
        }.padding(.horizontal, 12)
    }
}

/// Pick references from the pictures made in this tab. Click to add, click again to take it back out.
struct KieRefPicker: View {
    @ObservedObject var studio: KieStudio
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose references").font(.system(size: 13, weight: .semibold))
            if studio.results.isEmpty {
                Text("Pictures you make here show up here.").font(.system(size: 12)).foregroundStyle(Color.kieSoft).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(studio.results) { r in
                            if let u = studio.url(r) {
                                let on = studio.refs.contains(u)
                                Button {
                                    if on { studio.refs.removeAll { $0 == u } } else { studio.addRefs([u]) }
                                } label: {
                                    PanelImage(url: u, maxPixel: 300, fit: true).frame(maxWidth: .infinity).frame(height: 76).background(Color.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? Color.gold : Color.kieLine, lineWidth: on ? 2 : 1))
                                        .overlay(alignment: .topTrailing) {
                                            if on { Image(systemName: "checkmark.circle.fill").font(.system(size: 15)).foregroundStyle(Color.gold).padding(4) }
                                        }
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help(r.prompt)
                            }
                        }
                    }.padding(2)
                }.scrollIndicators(.never)
            }
        }
        .padding(14).frame(width: 440, height: 480).background(Color.kiePanel).foregroundStyle(Color.kieInk)
    }
}
