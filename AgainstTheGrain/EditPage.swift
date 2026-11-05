import SwiftUI
import AppKit
import AVFoundation

// MARK: - The Edit stage: preview, beat panel and a timeline where you decide when each picture comes in

extension Store {
    /// Every word in the recording with its time, from the last sync. Empty until an episode has been synced.
    func wordsInRecording(_ e: Episode) -> [TimedWord] {
        guard let h = state.heard?["e\(e.n)"] else { return [] }
        return timedWords(script: e.beats.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }, heard: h.map { ($0.w, $0.t) })
    }
    /// The audio can be lined up by hand once its beats have real times.
    func canMoveCuts(_ e: Episode) -> Bool {
        audioURL(e) != nil && (state.syncTimes?["e\(e.n)"] != nil || (e.timing != nil && !isOwnAudio(e)))
    }
}

enum EditPanelPage: String, CaseIterable { case shot = "Shot", audio = "Audio" }

/// A picture comes in this far ahead of the word, the same lead the beat sync uses.
let cutLead = 0.15

struct EditPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var listener: Listener
    let season: Season; let n: Int; let isRoot: Bool
    var e: Episode { season.eps.first { $0.n == n } ?? season.eps[0] }

    @AppStorage("editZoom") var pps = 120.0                 // points per second
    @AppStorage("editSnap") var snapping = true
    @AppStorage("editTrackHeight") var pictureHeight = 84.0
    var inspectorPage = EditPanelPage.shot
    @State var head = 0.0
    @State var pinned: Double? = nil
    @State var words: [TimedWord] = []
    @State var peaks: [Float] = []
    @State var audioLength = 0.0
    @State var undo: [[[Double]]?] = []
    @State var savedAt: Date? = nil
    @State var drag: CutDrag? = nil
    @State var confirmRetime = false
    @State var keyMonitor: Any? = nil
    @State var pageHeight = 0.0
    @State var resizeBase: Double? = nil
    @State var isFullScreen = false
    @State var hidSidebar = false

    struct CutDrag { let index: Int; let base: Double; var t: Double; var word: String? }

    /// The beat times, with the cut being dragged where it is right now.
    func shownTimes(_ e: Episode) -> [(Double, Double)] {
        var t = store.beatTimes(e, duration: store.estimatedLength(e))
        if let d = drag, t.indices.contains(d.index), d.index > 0 { t[d.index].0 = d.t; t[d.index - 1].1 = d.t }
        return t
    }
    var here: Bool { listener.ep == n }

    var body: some View {
        let _ = store.imageVersion
        let e = self.e
        let changed = Set(store.changedSinceRecording(e))
        let times = shownTimes(e)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                EditPreview(e: e, head: $head).frame(minWidth: 0, maxWidth: .infinity)
                if nav.inspector, let b = e.beats.first(where: { $0.n == nav.selected }) {
                    Rectangle().fill(Color.benchLine).frame(width: 1)
                    EditPanel(e: e, b: b, span: span(e, b, times), changed: changed, page: inspectorPage,
                              beforeTimeChange: { undo.append(store.state.syncTimes?["e\(e.n)"]); savedAt = Date() }).id(b.n).frame(width: 340)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            resizeBar
            timeline(e, times: times)
            ExportStatusBar()
            Rectangle().fill(Color.benchLine).frame(height: 1)
            footer(e)
        }
        .background(Color.benchBG)
        .background(GeometryReader { g in Color.clear.onAppear { pageHeight = g.size.height }.onChange(of: g.size.height) { _, h in pageHeight = h } })
        .foregroundStyle(Color.benchInk)
        .modifier(StageChrome(season: season, e: e, isRoot: isRoot))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in isFullScreen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
            if hidSidebar { hidSidebar = false; nav.sidebarRequest = .all }
        }
        .onAppear {
            if nav.selected == nil { nav.selected = e.beats.first?.n }
            nav.inspector = true; nav.drawer = .beat
            let t = times, i = e.beats.firstIndex { $0.n == nav.selected } ?? 0
            head = here ? listener.time : (t.indices.contains(i) ? t[i].0 : 0)
            startKeys()
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
        .onChange(of: nav.selected) { _, v in
            guard let v else { nav.selected = e.beats.first?.n; return }
            if let p = pinned { pinned = nil; head = p; return }
            guard !(here && listener.playing), let i = e.beats.firstIndex(where: { $0.n == v }), times.indices.contains(i) else { return }
            head = times[i].0
            if here { listener.seek(head) }
        }
        .task(id: wordsKey(e)) {
            let script = e.beats.flatMap { $0.text.split(whereSeparator: \.isWhitespace).map(String.init) }
            let heard = (store.state.heard?["e\(e.n)"] ?? []).map { (w: $0.w, t: $0.t) }
            let file = store.wordCacheFile(e)
            words = await Task.detached(priority: .userInitiated) { savedTimedWords(file: file, script: script, heard: heard) }.value
        }
        .task(id: store.audioURL(e)) {
            guard let u = store.audioURL(e) else { peaks = []; audioLength = 0; return }
            audioLength = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 0
            peaks = await Waveforms.peaks(u, count: 12000)
        }
        .confirmationDialog("Line the cuts up with the word times?", isPresented: $confirmRetime) {
            Button("Re-time cuts") {
                undo.append(store.state.syncTimes?["e\(e.n)"])
                Task { await store.retimeCuts(e); listener.refreshTimes(self.e); savedAt = Date() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let moved = store.movedCuts(e)
            Text(moved.isEmpty ? "No cuts look hand-set, so every cut can move. Undo puts them back." : "Your cuts on beat \(moved.map(String.init).joined(separator: ", ")) stay where they are. Undo puts the others back.")
        }
        .task(id: n) {
            // an episode with a recording gets its words the first time it's opened here, or better ones if they're from the old way; no cut moves
            let current = store.state.heard?["e\(e.n)"] != nil && (store.state.wordMethod?["e\(e.n)"] ?? 1) >= Store.wordMethodNow
            if Store.listensForWords, store.audioURL(e) != nil, !current { await store.getWords(e) }
        }
    }
    /// Space plays from the playhead and stops, unless you're typing. A click outside a text box ends the typing.
    func startKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { ev in
            guard let w = ev.window, w.attachedSheet == nil else { return ev }
            func isText(_ r: Any?) -> Bool { r is NSText || r is NSTextField }
            if ev.type == .leftMouseDown {
                let hit = w.contentView?.hitTest(ev.locationInWindow)
                if isText(w.firstResponder), !isText(hit) { DispatchQueue.main.async { if !isText(hit) { w.makeFirstResponder(nil) } } }
                return ev
            }
            guard ev.keyCode == 49, ev.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty, !isText(w.firstResponder), !ev.isARepeat else { return ev }
            if here { listener.toggle() } else { listener.play(self.e, at: head) }
            return nil
        }
    }
    /// Moves the playhead, from dragging or clicking the ruler or the waveform.
    func scrub(to x: CGFloat, e: Episode, times: [(Double, Double)], total: Double) {
        let t = min(total, max(0, x / pps))
        head = t
        if here { listener.seek(t) }
        if let i = times.firstIndex(where: { t >= $0.0 && t < $0.1 }), nav.selected != e.beats[i].n { pinned = t; nav.selected = e.beats[i].n }
    }
    func scrubZone(_ e: Episode, times: [(Double, Double)], total: Double, height: CGFloat) -> some View {
        Color.white.opacity(0.001).frame(height: height).frame(maxWidth: .infinity)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .help("Drag to move the playhead")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { v in scrub(to: v.location.x, e: e, times: times, total: total) })
    }
    func wordsKey(_ e: Episode) -> String { "\(e.n)|\(store.state.heard?["e\(e.n)"]?.count ?? 0)|\(e.beats.map(\.text).joined().hashValue)" }
    func span(_ e: Episode, _ b: Beat, _ times: [(Double, Double)]) -> (Double, Double) {
        guard let i = e.beats.firstIndex(where: { $0.n == b.n }), times.indices.contains(i) else { return (0, 0) }
        return times[i]
    }

    // MARK: moving a cut

    /// Beat `i` comes in at `t`. The beat before it runs up to there.
    func moveCut(_ e: Episode, _ i: Int, to t: Double) {
        guard e.beats.indices.contains(i), i > 0 else { return }
        undo.append(store.state.syncTimes?["e\(e.n)"])
        store.setBeatTime(e, e.beats[i].n, start: t)
        listener.refreshTimes(e)
        savedAt = Date()
    }
    func undoCut(_ e: Episode) {
        guard let was = undo.popLast() else { return }
        store.restoreBeatTimes(e, was)
        listener.refreshTimes(e)
        savedAt = Date()
    }
    /// The nearest word to a time, if it's close enough on screen to snap to.
    func nearestWord(_ t: Double, among list: [TimedWord]) -> TimedWord? {
        guard let w = list.min(by: { abs($0.t - cutLead - t) < abs($1.t - cutLead - t) }), abs(w.t - cutLead - t) * pps <= 10 else { return nil }
        return w
    }
    func cutHandle(_ e: Episode, _ i: Int, times: [(Double, Double)], height: CGFloat) -> some View {
        Rectangle().fill(Color.white.opacity(0.001)).frame(width: 15, height: height)
            .overlay { if drag?.index == i { Rectangle().fill(Color.benchAmber).frame(width: 2) } }
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .help("Drag to change when this picture comes in")
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                    .onChanged { v in
                        let base = drag?.base ?? times[i].0
                        var t = base + (v.location.x - v.startLocation.x) / pps
                        // it stays between the start of the beat before and the end of this one
                        t = min(times[i].1 - 0.1, max(times[i - 1].0 + 0.1, t))
                        var word: String? = nil
                        if snapping, let w = nearestWord(t, among: words), w.t - cutLead > times[i - 1].0, w.t - cutLead < times[i].1 { t = w.t - cutLead; word = w.text }
                        drag = CutDrag(index: i, base: base, t: t, word: word)
                    }
                    .onEnded { _ in
                        if let d = drag { let to = d.t; drag = nil; moveCut(e, i, to: to) }
                    }
            )
    }

    // MARK: the timeline

    /// The tallest the Picture track can go and still leave room for the preview.
    var tallestPicture: Double { pageHeight > 0 ? max(56, pageHeight - 500) : 420 }
    func trackHeights() -> (ruler: CGFloat, picture: CGFloat, script: CGFloat, words: CGFloat, wave: CGFloat) {
        let picture = min(pictureHeight, tallestPicture)
        return (22, picture, picture > 100 ? 56 : 42, 22, max(34, min(80, picture * 0.4)))
    }
    /// The bar between the preview and the timeline: drag it up or down to resize the timeline.
    var resizeBar: some View {
        ZStack {
            Rectangle().fill(Color.benchLine).frame(height: 1)
            Capsule().fill(resizeBase == nil ? Color.benchSoft.opacity(0.6) : Color.benchBlue).frame(width: 44, height: 4)
        }
        .frame(height: 9).frame(maxWidth: .infinity).contentShape(Rectangle())
        .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
        .help("Drag to make the timeline bigger or smaller")
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let base = resizeBase ?? min(pictureHeight, tallestPicture)
                    resizeBase = base
                    pictureHeight = min(tallestPicture, max(56, base - v.translation.height))
                }
                .onEnded { _ in resizeBase = nil }
        )
    }
    /// Takes the window full screen with the sidebar out of the way; the same button brings both back.
    func toggleFullScreen() {
        guard let w = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        if !w.styleMask.contains(.fullScreen) { hidSidebar = true; nav.sidebarRequest = .detailOnly }
        w.toggleFullScreen(nil)
    }

    func timeline(_ e: Episode, times: [(Double, Double)]) -> some View {
        let h = trackHeights(), selIndex = e.beats.firstIndex { $0.n == nav.selected }
        let total = times.last.map { max($0.1, audioLength) } ?? audioLength
        let movable = store.canMoveCuts(e)
        let contentHeight = h.ruler + h.picture + h.script + h.words + h.wave + 8
        return VStack(spacing: 0) {
            timelineBar(e, sel: selIndex, movable: movable)
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    Color.clear.frame(height: h.ruler)
                    trackLabel("Picture", "film", h.picture)
                    trackLabel("Script", "doc.text", h.script)
                    trackLabel("Voiceover", "mic", h.words + h.wave + 2)
                }.frame(width: 104).padding(.leading, 8)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 0) {
                            ForEach(Array(e.beats.enumerated()), id: \.element.id) { i, b in
                                column(e, i, b, times: times, sel: selIndex, movable: movable, h: h, height: contentHeight)
                            }
                        }
                        .frame(width: max(1, total * pps), alignment: .leading)
                        .overlay(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                scrubZone(e, times: times, total: total, height: h.ruler)
                                Spacer(minLength: 0)
                                scrubZone(e, times: times, total: total, height: h.wave)
                            }.frame(height: h.ruler + 2 + h.picture + 2 + h.script + 2 + h.words + 2 + h.wave)
                        }
                        .overlay(alignment: .topLeading) {
                            EditPlayhead(e: e, head: head, pps: pps, height: contentHeight).allowsHitTesting(false)
                        }
                        .overlay(alignment: .topLeading) {
                            if let d = drag {
                                Text((d.word.map { "“\($0)”  " } ?? "") + benchTenths(d.t)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                                    .padding(.horizontal, 7).frame(height: 20).background(Color.benchAmber, in: Capsule()).foregroundStyle(Color.black).fixedSize()
                                    .offset(x: d.t * pps + 6, y: 1).allowsHitTesting(false)
                            }
                        }
                        .coordinateSpace(name: "timeline")
                    }
                    .scrollIndicators(.visible)
                    .background(EditFollower(e: e) { n in withAnimation { proxy.scrollTo(n, anchor: .center) } })
                    .onChange(of: nav.scrollTo) { _, v in if let v { withAnimation { proxy.scrollTo(v, anchor: .center) }; nav.scrollTo = nil } }
                    .onChange(of: pps) { _, _ in if let v = nav.selected { proxy.scrollTo(v, anchor: .center) } }
                    .onChange(of: audioLength) { _, _ in if let v = nav.selected { proxy.scrollTo(v, anchor: .center) } }
                    .onAppear { if let v = nav.selected { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(v, anchor: .center) } } }
                }
            }
            .frame(height: contentHeight + 14)
            .padding(.bottom, 4)
        }
        .background(Color.benchPanel)
    }

    @ViewBuilder func column(_ e: Episode, _ i: Int, _ b: Beat, times: [(Double, Double)], sel: Int?, movable: Bool, h: (ruler: CGFloat, picture: CGFloat, script: CGFloat, words: CGFloat, wave: CGFloat), height: CGFloat) -> some View {
        let a = i < times.count ? times[i].0 : 0, z = i < times.count ? times[i].1 : 0
        // a word can bring the selected beat in only if it's said during that beat or the one before
        let lo = sel.flatMap { $0 > 0 && times.indices.contains($0) ? times[$0 - 1].0 : nil }, hi = sel.flatMap { $0 > 0 && times.indices.contains($0) ? times[$0].1 : nil }
        let cut = sel.flatMap { times.indices.contains($0) ? times[$0].0 : nil }
        let mine = words.filter { $0.t >= a && $0.t < z }
        // the one word the selected beat comes in on, even when two are said close together
        let cutWord = cut.flatMap { c in words.min { abs($0.t - cutLead - c) < abs($1.t - cutLead - c) }.flatMap { abs($0.t - cutLead - c) < 0.12 ? $0 : nil } }
        EditColumn(e: e, b: b, start: a, end: z, pps: pps, h: h, selected: sel == i, length: audioLength, peaks: peaks, words: mine, nextWordAfter: words.first { $0.t >= z }?.t ?? z,
                   usable: { w in movable && lo != nil && w.t - cutLead > lo! + 0.05 && w.t - cutLead < hi! - 0.05 },
                   current: { w in w.id == cutWord?.id },
                   pick: { w in if let s = sel { moveCut(e, s, to: w.t - cutLead) } },
                   select: { nav.selected = b.n; nav.drawer = .beat; nav.inspector = true; if here && listener.playing { listener.seek(a) } },
                   seek: { t in
                       head = t
                       if here { listener.seek(t) }
                       if nav.selected != b.n { pinned = t; nav.selected = b.n }
                   })
            .id(b.n)
            .overlay(alignment: .topLeading) {
                if movable && i > 0 {
                    cutHandle(e, i, times: times, height: h.picture + h.script + 2).offset(x: -7.5, y: h.ruler + 2)
                }
            }
    }

    func trackLabel(_ t: String, _ icon: String, _ height: CGFloat) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Color.benchSoft)
            Text(t).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).frame(height: height)
        .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
    }

    func timelineBar(_ e: Episode, sel: Int?, movable: Bool) -> some View {
        let section = Listener.sections(e).first { s in nav.selected.map { s.range.contains($0) } ?? false }?.title ?? ""
        return HStack(spacing: 14) {
            Text(section).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            hint(e, sel: sel, movable: movable)
            Spacer(minLength: 8)
            if store.audioURL(e) != nil, store.syncing[e.n] != nil || store.state.heard?["e\(e.n)"] == nil {
                Button { Task { await store.getWords(e) } } label: { Label(store.syncing[e.n] ?? "Get word times", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small).disabled(store.syncing[e.n] != nil)
                    .help("Listen to the recording on this Mac so cuts can snap to words. No cut moves.")
            }
            if movable {
                Button { confirmRetime = true } label: { Label("Re-time cuts", systemImage: "text.word.spacing") }.controlSize(.small)
                    .disabled(store.syncing[e.n] != nil).help("Line the cuts up with the word times. Cuts you set by hand stay where they are.")
            }
            Button { undoCut(e) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }.controlSize(.small).disabled(undo.isEmpty)
                .keyboardShortcut("z", modifiers: .command).help("Put the last cut you moved back")
            Toggle("Snap to words", isOn: $snapping).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12)).fixedSize()
            HStack(spacing: 6) {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 11))
                Slider(value: $pps, in: 20...220).frame(width: 110).controlSize(.mini).tint(.benchBlue)
                Image(systemName: "plus.magnifyingglass").font(.system(size: 11))
            }.foregroundStyle(Color.benchSoft).help("Timeline zoom")
            Picker("", selection: Binding(get: { [56.0, 84.0, 124.0].min { abs($0 - pictureHeight) < abs($1 - pictureHeight) } ?? 84 }, set: { pictureHeight = $0 })) {
                Text("Small").tag(56.0); Text("Medium").tag(84.0); Text("Large").tag(124.0)
            }.labelsHidden().controlSize(.small).fixedSize().help("Track height")
            Button(action: toggleFullScreen) {
                Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right").font(.system(size: 11, weight: .semibold))
            }.controlSize(.small).help(isFullScreen ? "Exit full screen" : "Full screen, with the sidebar hidden")
        }
        .padding(.horizontal, 14).frame(height: 36)
    }
    @ViewBuilder func hint(_ e: Episode, sel: Int?, movable: Bool) -> some View {
        Group {
            if store.audioURL(e) == nil { Text("No recording yet") }
            else if store.syncing[e.n] != nil { Text("Finding each word's time. Your cuts stay where they are.") }
            else if !movable { Text("Sync the recording before moving cuts") }
            else if words.isEmpty { Text("Drag the edge between two pictures to move a cut") }
            else if let s = sel, s > 0 { Text("Click a word: beat \(e.beats[s].n) comes in on it. Or drag the edge between pictures.") }
            else { Text("Select a later beat, then click the word it should come in on") }
        }.font(.system(size: 11)).foregroundStyle(Color.benchSoft).lineLimit(1)
    }

    func footer(_ e: Episode) -> some View {
        let status = store.episodeAudioStatus(e)
        return HStack {
            HStack(spacing: 8) {
                Image(systemName: status == .synced ? "checkmark.circle.fill" : "circle.fill").font(.system(size: status == .synced ? 13 : 8))
                    .foregroundStyle(status == .synced ? Color.benchGreen : status.color)
                Text("\(status == .synced ? "Voiceover synced" : status == .unsynced ? "Voiceover not synced" : "No voiceover") · \(e.beats.count) beats")
            }
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { c in
                if let savedAt {
                    let m = Int(c.date.timeIntervalSince(savedAt) / 60)
                    Text(m < 1 ? "Saved just now" : "Saved \(m) min ago")
                } else { Text("All changes saved") }
            }
        }
        .font(.system(size: 12)).foregroundStyle(Color.benchSoft)
        .padding(.horizontal, 18).frame(height: 30).background(Color.benchPanel)
    }
}

// MARK: - One beat on the timeline

struct EditColumn: View {
    @EnvironmentObject var store: Store
    let e: Episode; let b: Beat; let start: Double; let end: Double; let pps: Double
    let h: (ruler: CGFloat, picture: CGFloat, script: CGFloat, words: CGFloat, wave: CGFloat)
    let selected: Bool; let length: Double; let peaks: [Float]; let words: [TimedWord]; let nextWordAfter: Double
    let usable: (TimedWord) -> Bool; let current: (TimedWord) -> Bool
    let pick: (TimedWord) -> Void; let select: () -> Void; let seek: (Double) -> Void

    var body: some View {
        let w = max(2, (end - start) * pps)
        VStack(alignment: .leading, spacing: 2) {
            EditRuler(start: start, end: end, pps: pps)
                .frame(width: w, height: h.ruler)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { seek(start + $0.location.x / pps) })
            pictureClip(w).onTapGesture(perform: select)
            scriptClip(w).onTapGesture(perform: select)
            wordLane(w)
            WaveSlice(peaks: slice).frame(width: w, height: h.wave)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { seek(start + $0.location.x / pps) })
        }
        .frame(width: w, alignment: .leading)
    }

    var slice: [Float] {
        guard length > 0, !peaks.isEmpty else { return [] }
        let c = Double(peaks.count), a = max(0, Int(start / length * c)), z = min(peaks.count, Int(end / length * c))
        return a < z ? Array(peaks[a..<z]) : []
    }

    func pictureClip(_ w: CGFloat) -> some View {
        // the picture repeats along a long beat, like a film strip
        let tile = max(1, h.picture * 16 / 9)
        return HStack(spacing: 0) {
            ForEach(0..<max(1, Int((w / tile).rounded(.up))), id: \.self) { _ in BeatPicture(e: e, b: b).frame(width: tile, height: h.picture) }
        }
            .frame(width: w, height: h.picture, alignment: .leading).clipped()
            .overlay(alignment: .top) {
                if w > 44 {
                    HStack(spacing: 4) {
                        Text("Beat \(String(format: "%02d", b.n))").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if w > 110 { Text(String(format: "%.1f s", end - start)).font(.system(size: 10).monospacedDigit()).lineLimit(1) }
                    }
                    .padding(.horizontal, 6).frame(height: 18).background(Color.benchBG.opacity(0.82)).foregroundStyle(Color.benchInk)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.benchBlue : Color.benchLine, lineWidth: selected ? 2 : 1))
            .padding(.horizontal, 0.5)
            .contentShape(Rectangle())
    }
    func scriptClip(_ w: CGFloat) -> some View {
        Text(b.text).font(.system(size: 11)).lineLimit(pictureTall ? 3 : 2).padding(.horizontal, 6)
            .frame(width: w, height: h.script, alignment: .leading).clipped()
            .background(selected ? Color.benchBlue.opacity(0.35) : Color.benchCard, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(selected ? Color.benchBlue : Color.benchLine))
            .padding(.horizontal, 0.5)
            .contentShape(Rectangle())
            .help(b.text)
    }
    var pictureTall: Bool { h.script > 50 }

    /// Each word sits at the time it's said. Too zoomed out to read them, they stay out of the way.
    func wordLane(_ w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if pps >= 40 {
                ForEach(Array(words.enumerated()), id: \.element.id) { i, word in
                    let next = i + 1 < words.count ? words[i + 1].t : nextWordAfter
                    let cell = max(6, (next - word.t) * pps)
                    let can = usable(word), on = current(word)
                    Button { pick(word) } label: {
                        Text(word.text).font(.system(size: 10, weight: on ? .bold : .regular)).fixedSize()
                            .padding(.horizontal, 2).frame(width: cell, height: h.words, alignment: .leading).clipped()
                            .background(on ? Color.benchBlue : .clear, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(on ? Color.white : can ? (word.inScript ? Color.benchInk : Color.benchAmber) : Color.benchMute)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!can)
                    .help(word.inScript ? word.text : "\(word.text): heard in the recording, not in the script")
                    .offset(x: (word.t - start) * pps)
                }
            }
        }
        .frame(width: w, height: h.words, alignment: .topLeading).clipped()
    }
}

struct EditRuler: View {
    let start: Double; let end: Double; let pps: Double
    var body: some View {
        Canvas { c, size in
            let minor = major / 3
            var t = (start / minor).rounded(.up) * minor
            while t < end {
                let x = (t - start) * pps, isMajor = abs((t / major).rounded() - t / major) < 0.001
                c.fill(Path(CGRect(x: x, y: size.height - (isMajor ? 8 : 4), width: 1, height: isMajor ? 8 : 4)), with: .color(isMajor ? .benchSoft : .benchLine))
                t += minor
            }
        }
        .overlay(alignment: .topLeading) {
            // not drawn in the canvas: a label near the end of a beat runs on past it
            ForEach(labels, id: \.self) { t in
                let s = Int(t.rounded())
                Text(String(format: "%02d:%02d", s / 60, s % 60)).font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.benchSoft)
                    .fixedSize().offset(x: (t - start) * pps + 3).allowsHitTesting(false)
            }
        }
    }
    var major: Double { pps < 30 ? 10 : pps < 60 ? 5 : pps < 130 ? 3 : 1 }
    var labels: [Double] {
        var out: [Double] = [], t = (start / major).rounded(.up) * major
        while t < end { out.append(t); t += major }
        return out
    }
}

struct WaveSlice: View {
    let peaks: [Float]
    var body: some View {
        Canvas { c, size in
            guard !peaks.isEmpty else { return }
            let bars = max(1, Int(size.width / 3)), mid = size.height / 2
            for i in 0..<bars {
                let v = CGFloat(peaks[min(peaks.count - 1, i * peaks.count / bars)])
                let h = max(1.5, v * size.height)
                c.fill(Path(CGRect(x: CGFloat(i) * 3, y: mid - h / 2, width: 2, height: h)), with: .color(.benchBlue))
            }
        }
    }
}

/// Its own view, so only the line redraws as the audio plays.
struct EditPlayhead: View {
    @EnvironmentObject var listener: Listener
    let e: Episode; let head: Double; let pps: Double; let height: CGFloat
    var body: some View {
        let t = listener.ep == e.n ? listener.time : head
        Rectangle().fill(Color.benchInk).frame(width: 2, height: height)
            .overlay(alignment: .top) { Circle().fill(Color.benchBlue).overlay(Circle().stroke(Color.benchInk, lineWidth: 1.5)).frame(width: 16, height: 16).offset(y: 3) }
            .offset(x: t * pps - 1)
    }
}

/// Keeps the timeline on the beat that's playing.
struct EditFollower: View {
    @EnvironmentObject var listener: Listener
    let e: Episode; let go: (Int) -> Void
    var body: some View {
        Color.clear.onChange(of: listener.nowBeat(e)) { _, n in if let n, listener.playing { go(n) } }
    }
}

// MARK: - The preview and its transport

struct EditPreview: View {
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var nav: Nav
    let e: Episode
    @Binding var head: Double
    var body: some View {
        let here = listener.ep == e.n
        let len = max(listener.length(e), 0.1)
        let index = here && listener.playing ? listener.beatIndex(e, at: listener.time) : (e.beats.firstIndex { $0.n == nav.selected } ?? 0)
        VStack(spacing: 10) {
            ZStack {
                if !e.beats.isEmpty {
                    PlayerStage(e: e, index: min(index, e.beats.count - 1))
                        .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
                } else { Text("No beats yet.").foregroundStyle(Color.benchSoft) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 14) {
                step("backward.end.fill", "Previous beat", -1)
                Button {
                    if here { listener.toggle() } else { listener.play(e, at: head) }
                } label: {
                    Image(systemName: here && listener.playing ? "pause.fill" : "play.fill").font(.system(size: 13))
                        .frame(width: 32, height: 32).background(Color.benchBlue, in: Circle()).foregroundStyle(.white).contentShape(Circle())
                }.buttonStyle(.plain).help("Play or pause (Space)")
                step("forward.end.fill", "Next beat", 1)
                Rectangle().fill(Color.benchLine).frame(width: 1, height: 20)
                Text("\(benchTenths(here ? listener.time : head)) / \(benchClock(len))").font(.system(size: 12).monospacedDigit())
                Spacer()
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 11)).foregroundStyle(Color.benchSoft)
                Slider(value: Binding(get: { Double(listener.volume) }, set: { listener.volume = Float($0) }), in: 0...1).frame(width: 90).controlSize(.mini).tint(.benchBlue)
            }
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.benchLine))
        }
        .padding(14)
    }
    func step(_ icon: String, _ tip: String, _ d: Int) -> some View {
        Button {
            guard !e.beats.isEmpty else { return }
            let i = e.beats.firstIndex { $0.n == nav.selected } ?? 0
            let n = e.beats[min(e.beats.count - 1, max(0, i + d))].n
            nav.selected = n; nav.scrollTo = n
        } label: { Image(systemName: icon).font(.system(size: 13)).frame(width: 24, height: 24).contentShape(Rectangle()) }
        .buttonStyle(.plain).help(tip)
    }
}

struct EditPanel: View {
    let e: Episode; let b: Beat; let span: (Double, Double); let changed: Set<Int>
    @State var page: EditPanelPage
    var beforeTimeChange: (() -> Void)? = nil
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Beat \(String(format: "%02d", b.n))").font(.bench(22))
                    Spacer()
                    BeatMenu(e: e, b: b)
                }
                HStack(spacing: 2) {
                    ForEach(EditPanelPage.allCases, id: \.self) { p in
                        Button { page = p } label: {
                            Text(p.rawValue).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 26)
                                .background(page == p ? Color.benchBlue : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(page == p ? Color.white : Color.benchSoft)
                    }
                }.padding(2).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
                switch page {
                case .shot: ShotPage(e: e, b: b, span: span, beforeTimeChange: beforeTimeChange)
                case .audio: AudioPage(e: e, b: b, span: span, changed: changed)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(Color.benchPanel)
    }
}
