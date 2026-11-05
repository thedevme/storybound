import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - The Script stage: read and edit the episode's lines, with each beat's timing, picture and recording status

enum ScriptPanelPage: String, CaseIterable { case recording = "Recording", picture = "Picture" }

func benchTenths(_ t: Double) -> String {
    let d = Int((max(0, t) * 10).rounded())
    return String(format: "%02d:%02d.%d", d / 600, d / 10 % 60, d % 10)
}

struct ScriptPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let season: Season; let n: Int; let isRoot: Bool
    var e: Episode { season.eps.first { $0.n == n } ?? season.eps[0] }
    @State var find = ""
    @State var hit = -1
    @State var panel = ScriptPanelPage.recording
    @State var collapsed: Set<Int> = []
    @State var savedAt: Date? = nil
    @State var importing: ScriptImport? = nil
    @State var importProblem: String? = nil
    @FocusState var searching: Bool

    /// Beats whose line (or number) matches the search.
    func hits(_ e: Episode) -> [Int] {
        let q = find.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let num = Int(q)
        return e.beats.filter { $0.n == num || $0.text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.n)
    }
    func go(_ d: Int) {
        let h = hits(e); guard !h.isEmpty else { return }
        hit = (hit + d + h.count) % h.count
        nav.selected = h[hit]; nav.scrollTo = h[hit]
    }

    var body: some View {
        let _ = store.imageVersion
        let e = self.e
        let changed = store.changedSinceRecording(e)
        let times = store.beatTimes(e, duration: store.estimatedLength(e))
        let words = e.beats.map(\.wordCount).reduce(0, +)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                page(e, changed: changed, times: times, words: words).frame(minWidth: 0, maxWidth: .infinity)
                if nav.inspector, let b = e.beats.first(where: { $0.n == nav.selected }) {
                    Rectangle().fill(Color.benchLine).frame(width: 1)
                    ScriptPanel(e: e, b: b, span: span(e, b, times), changed: Set(changed), page: $panel).id(b.n).frame(width: 340)
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            Rectangle().fill(Color.benchLine).frame(height: 1)
            footer(e, words: words)
        }
        .background(Color.benchBG)
        .foregroundStyle(Color.benchInk)
        .modifier(StageChrome(season: season, e: e, isRoot: isRoot))
        .modifier(BeatGenerateSheets(e: e))
        .onAppear(perform: selectFirst)
        .onChange(of: nav.selected) { _, v in if v == nil { selectFirst() } }
        .onChange(of: searching) { _, _ in nav.refreshTyping() }
        .alert(importing?.title ?? "", isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } })) {
            Button("Cancel", role: .cancel) { importing = nil }
            if let i = importing, !i.changed.isEmpty {
                Button("Import") {
                    _ = store.saveScript(e, i.text); savedAt = Date(); importing = nil
                }
            }
        } message: { Text(importing?.detail ?? "") }
        .alert("Can't import that file", isPresented: Binding(get: { importProblem != nil }, set: { if !$0 { importProblem = nil } })) {
            Button("OK") { importProblem = nil }
        } message: { Text(importProblem ?? "") }
    }

    func selectFirst() {
        if nav.selected == nil { nav.selected = e.beats.first?.n }
        nav.inspector = true; nav.drawer = .beat
    }
    func span(_ e: Episode, _ b: Beat, _ times: [(Double, Double)]) -> (Double, Double) {
        guard let i = e.beats.firstIndex(where: { $0.n == b.n }), times.indices.contains(i) else { return (0, 0) }
        return times[i]
    }

    @ViewBuilder func page(_ e: Episode, changed: [Int], times: [(Double, Double)], words: Int) -> some View {
        let h = hits(e), redo = Set(changed), secs = Listener.sections(e)
        VStack(spacing: 0) {
            header(e, words: words, hits: h).padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
            if !changed.isEmpty { banner(e, changed).padding(.horizontal, 18).padding(.bottom, 8) }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(secs.enumerated()), id: \.offset) { i, s in
                            let beats = e.beats.filter { s.range.contains($0.n) }
                            if !beats.isEmpty {
                                sectionHeader(s, index: i)
                                if !collapsed.contains(i) {
                                    ForEach(beats) { b in
                                        ScriptRow(e: e, b: b, span: span(e, b, times), redo: redo, match: h.contains(b.n), found: hit >= 0 && h.indices.contains(hit) && h[hit] == b.n) { savedAt = Date() }
                                            .id(b.n)
                                    }
                                }
                            }
                        }
                        if e.beats.isEmpty {
                            Text("No beats yet. Add them on the Beats tab.").foregroundStyle(Color.benchSoft).padding(.top, 20)
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 18)
                }
                .scrollIndicators(.never)
                .onChange(of: nav.scrollTo) { _, v in
                    guard let v else { return }
                    if let i = secs.firstIndex(where: { $0.range.contains(v) }) { collapsed.remove(i) }
                    DispatchQueue.main.async { withAnimation { proxy.scrollTo(v, anchor: .center) }; nav.scrollTo = nil }
                }
                .onAppear { if let v = nav.scrollTo ?? nav.selected { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(v, anchor: .center); nav.scrollTo = nil } } }
            }
            ExportStatusBar()
        }
    }

    func header(_ e: Episode, words: Int, hits h: [Int]) -> some View {
        HStack(spacing: 14) {
            Text("Episode script").font(.bench(26)).lineLimit(1).fixedSize()
            Text("\(words, format: .number) words · \(e.beats.count) beats · About \(max(1, Int((store.estimatedLength(e) / 60).rounded()))) min")
                .font(.system(size: 12)).foregroundStyle(Color.benchSoft).lineLimit(1)
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                TextField("Search script", text: $find).textFieldStyle(.plain).font(.system(size: 12)).focused($searching)
                    .onSubmit { go(1) }
                    .onChange(of: find) { _, _ in hit = -1; go(1) }
                if !find.isEmpty {
                    Text(h.isEmpty ? "None" : "\(max(1, hit + 1)) of \(h.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.benchSoft).fixedSize()
                    Button { go(-1) } label: { Image(systemName: "chevron.up").font(.system(size: 10)) }.buttonStyle(.plain).disabled(h.isEmpty).help("Previous match")
                    Button { go(1) } label: { Image(systemName: "chevron.down").font(.system(size: 10)) }.buttonStyle(.plain).disabled(h.isEmpty).help("Next match (Return)")
                }
            }
            .padding(.horizontal, 10).frame(width: 220, height: 30)
            .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(searching ? Color.benchBlue : Color.benchLine))
            Button { chooseImport(e) } label: {
                Label("Import script", systemImage: "square.and.arrow.up").font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).frame(height: 30)
                    .background(Color.benchBlue, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).contentShape(Rectangle())
            }.buttonStyle(.plain).fixedSize().disabled(e.beats.isEmpty)
            .help("Replace lines from a text file with [12] before each beat's line. You see what changes before anything is saved.")
        }
    }

    func chooseImport(_ e: Episode) {
        nav.choose([.plainText]) { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { importProblem = "That file couldn't be read as text."; return }
            let p = store.previewScript(e, text)
            guard p.found > 0 else { importProblem = "No beat numbers found. Each line needs its beat number in front, like [12] The line."; return }
            importing = ScriptImport(text: text, changed: p.changed, unknown: p.unknown)
        }
    }

    func banner(_ e: Episode, _ changed: [Int]) -> some View {
        // an edited line really changed; otherwise the line is the same but the recording says something else
        let edited = changed.allSatisfy { n in store.recordedLine(e, n) != e.beats.first { $0.n == n }?.text }
        let c = changed.count
        return HStack(spacing: 10) {
            Circle().fill(Color.benchAmber).frame(width: 9, height: 9)
            Text(edited ? "\(c) line\(c == 1 ? "" : "s") changed since recording" : "\(c) line\(c == 1 ? "" : "s") \(c == 1 ? "doesn't" : "don't") match the recording").font(.system(size: 13, weight: .medium))
            Spacer()
            Button(c == 1 ? "Review change" : "Next change") {
                let next = changed.first { $0 > (nav.selected ?? 0) } ?? changed[0]
                nav.selected = c == 1 ? changed[0] : next; nav.scrollTo = nav.selected; panel = .recording; nav.inspector = true
            }.controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Color.benchAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.benchAmber.opacity(0.55)))
    }

    func sectionHeader(_ s: Section, index i: Int) -> some View {
        Button {
            if collapsed.contains(i) { collapsed.remove(i) } else { collapsed.insert(i) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: collapsed.contains(i) ? "chevron.right" : "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.benchSoft).frame(width: 16)
                Text(s.title).font(.bench(22)).lineLimit(1)
                Spacer()
                Text("Beats \(String(format: "%02d", s.range.lowerBound))–\(String(format: "%02d", s.range.upperBound))").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
            }
            .padding(.vertical, 10).contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Color.benchLine).frame(height: 1) }
        }.buttonStyle(.plain).padding(.top, 6)
    }

    func footer(_ e: Episode, words: Int) -> some View {
        ZStack {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.benchGreen)
                    TimelineView(.periodic(from: .now, by: 30)) { c in Text(savedLabel(c.date)) }
                }
                Spacer()
                Text("\(words, format: .number) words")
            }
            if let b = e.beats.first(where: { $0.n == nav.selected }) { Text("Beat \(String(format: "%02d", b.n)) of \(e.beats.count)") }
        }
        .font(.system(size: 12)).foregroundStyle(Color.benchSoft)
        .padding(.horizontal, 18).frame(height: 34).background(Color.benchPanel)
    }
    func savedLabel(_ now: Date) -> String {
        guard let savedAt else { return "All changes saved" }
        let m = Int(now.timeIntervalSince(savedAt) / 60)
        return m < 1 ? "Saved just now" : "Saved \(m) min ago"
    }
}

struct ScriptImport {
    let text: String; let changed: [Int]; let unknown: [Int]
    var title: String { changed.isEmpty ? "Nothing to import" : "Replace \(changed.count) line\(changed.count == 1 ? "" : "s")?" }
    var detail: String {
        var s = changed.isEmpty ? "Every line in the file already matches the script." : "Beat \(changed.map(String.init).joined(separator: ", ")). Beats not in the file keep their lines."
        if !unknown.isEmpty { s += " Ignored, no such beat: \(unknown.map(String.init).joined(separator: ", "))." }
        return s
    }
}

extension Nav {
    /// Single-key shortcuts stay off whenever any text box has the cursor.
    func refreshTyping() {
        DispatchQueue.main.async { [weak self] in self?.typing = NSApp.keyWindow?.firstResponder is NSTextView }
    }
}

// MARK: - One line of the script

struct ScriptRow: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    let e: Episode; let b: Beat; let span: (Double, Double); let redo: Set<Int>; let match: Bool; let found: Bool
    let saved: () -> Void
    @State var draft = ""
    @FocusState var typing: Bool

    func commit() {
        // a project or episode switch can get here after the store has moved on: only save onto the line this row was showing
        guard store.season?.eps.first(where: { $0.n == e.n })?.beats.first(where: { $0.n == b.n })?.text == b.text else { return }
        if store.saveLine(e, b.n, draft) { saved() } else { draft = b.text }
    }

    var body: some View {
        let sel = nav.selected == b.n
        let status = store.audioStatus(e, b, changed: redo)
        HStack(spacing: 14) {
            Text(String(format: "%02d", b.n)).font(.bench(24)).frame(width: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(benchTenths(span.0) + " –")
                Text(benchTenths(span.1))
            }.font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.benchSoft).fixedSize()
            Rectangle().fill(Color.benchLine).frame(width: 1, height: 52)
            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(.bench(17)).lineSpacing(3).focused($typing)
                .onSubmit { typing = false }
                .frame(maxWidth: .infinity, alignment: .leading)
            BeatPicture(e: e, b: b).frame(width: 136).clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(dot(status)).frame(width: 9, height: 9).padding(.top, 4)
                Text(label(status)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }.frame(width: 96, alignment: .leading)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(sel ? Color.benchRaised.opacity(0.55) : found ? Color.benchAmber.opacity(0.16) : match ? Color.benchAmber.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(sel ? Color.benchBlue : found ? Color.benchAmber : .clear, lineWidth: sel || found ? 1.5 : 0))
        .overlay(BenchNowRing(e: e, n: b.n, corner: 8))
        .overlay(alignment: .bottom) { if !sel { Rectangle().fill(Color.benchLine.opacity(0.6)).frame(height: 1) } }
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)   // clicking another line finishes the one being typed
            nav.selected = b.n; nav.drawer = .beat; nav.inspector = true
        }
        .onAppear { draft = b.text }
        .onChange(of: b.text) { _, t in if !typing { draft = t } }
        .onChange(of: typing) { _, t in
            nav.refreshTyping()
            if t { nav.selected = b.n; nav.drawer = .beat; nav.inspector = true } else { commit() }
        }
        .onDisappear { if draft != b.text { commit() } }
    }
    func label(_ s: AudioStatus) -> String {
        switch s { case .synced: return "Synced"; case .unsynced: return "Not synced"; case .needsRecording: return "Needs recording"; case .none: return "No audio" }
    }
    func dot(_ s: AudioStatus) -> Color {
        switch s { case .synced: return .benchGreen; case .unsynced, .needsRecording: return .benchAmber; case .none: return .benchMute }
    }
}

// MARK: - The panel: Recording and Picture

struct ScriptPanel: View {
    let e: Episode; let b: Beat; let span: (Double, Double); let changed: Set<Int>
    @Binding var page: ScriptPanelPage
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Beat \(String(format: "%02d", b.n))").font(.bench(22))
                    Spacer()
                    BeatMenu(e: e, b: b)
                }
                HStack(spacing: 2) {
                    ForEach(ScriptPanelPage.allCases, id: \.self) { p in
                        Button { page = p } label: {
                            Text(p.rawValue).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).frame(height: 26)
                                .background(page == p ? Color.benchBlue : .clear, in: RoundedRectangle(cornerRadius: 6)).contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(page == p ? Color.white : Color.benchSoft)
                    }
                }.padding(2).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 8))
                switch page {
                case .recording: RecordingPage(e: e, b: b, span: span, changed: changed, page: $page)
                case .picture:
                    BeatPicture(e: e, b: b).clipShape(RoundedRectangle(cornerRadius: 6))
                    ArtworkPage(e: e, b: b)
                }
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .background(Color.benchPanel)
    }
}

struct RecordingPage: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var listener: Listener
    let e: Episode; let b: Beat; let span: (Double, Double); let changed: Set<Int>
    @Binding var page: ScriptPanelPage
    @State var confirmImport = false

    var body: some View {
        let status = store.audioStatus(e, b, changed: changed)
        let has = store.audioURL(e) != nil, own = store.isOwnAudio(e)
        let flagged = changed.contains(b.n), recorded = store.recordedLine(e, b.n)
        let edited = flagged && recorded != nil && recorded != b.text
        let timed = has && (store.state.syncTimes?["e\(e.n)"] != nil || (e.timing != nil && !own))
        VStack(alignment: .leading, spacing: 12) {
            chip(flagged ? (edited ? "Script changed" : "Doesn't match recording") : status == .synced ? "Synced" : status.label, status)
            if edited, let recorded {
                label("Recorded line"); lineBox(Text(recorded))
                label("Current script"); lineBox(diff(old: recorded))
            } else if flagged, let heard = store.heardLine(e, b.n) {
                label("Heard in the recording"); lineBox(Text(heard))
                label("Current script"); lineBox(diff(old: heard))
            } else {
                label("Current script"); lineBox(Text(b.text))
            }

            label("Recording")
            HStack(spacing: 8) {
                Image(systemName: "mic").font(.system(size: 12)).foregroundStyle(Color.benchSoft)
                Text(has ? "Episode \(String(format: "%02d", e.number)) · \(own ? "Your recording" : "Original voiceover")" : "None yet").font(.system(size: 12))
                Spacer()
            }.padding(8).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
            if has { BeatClipPlayer(e: e, b: b, span: span) }

            Button {} label: { Label("Record replacement", systemImage: "mic").frame(maxWidth: .infinity) }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.benchBlue).disabled(true).help("Recording in the app isn't built yet")
            Button { if has { confirmImport = true } else { pick() } } label: {
                Label("Import recording", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }.controlSize(.large).help("Choose the recording for the whole episode")
            .confirmationDialog("Replace the whole episode's recording?", isPresented: $confirmImport) {
                Button("Choose a file…") { pick() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(own ? "A recording here covers every beat, not just this one. The current file is deleted, and the beats sync to the new one." : "A recording here covers every beat, not just this one. The beats sync to the new one.")
            }

            Rectangle().fill(Color.benchLine).frame(height: 1)
            Text("Alignment").font(.system(size: 13, weight: .semibold))
            timeRow("Start time", span.0, enabled: timed) { store.setBeatTime(e, b.n, start: $0); listener.refreshTimes(current) }
            timeRow("End time", span.1, enabled: timed) { store.setBeatTime(e, b.n, end: $0); listener.refreshTimes(current) }
            PanelRow(label: "Status") {
                HStack(spacing: 6) {
                    Circle().fill(status == .synced ? Color.benchGreen : status == .none ? Color.benchMute : Color.benchAmber).frame(width: 8, height: 8)
                    Text(flagged ? "Needs re-sync" : status == .synced ? "Synced" : status.label).font(.system(size: 12))
                }
            }
            if let note = store.syncing[e.n] ?? store.state.syncNotes?["e\(e.n)"] {
                Text(note).font(.system(size: 11)).foregroundStyle(Color.benchSoft).fixedSize(horizontal: false, vertical: true)
            }
            Button { Task { await store.syncBeat(current, b.n); listener.refreshTimes(current) } } label: {
                Label("Sync this beat", systemImage: "arrow.triangle.2.circlepath").frame(maxWidth: .infinity)
            }.controlSize(.large).disabled(!has || store.syncing[e.n] != nil)
            .help("Listen to the recording on this Mac and move this beat to where its words are said")

            linked
        }
    }
    var current: Episode { store.season?.eps.first { $0.n == e.n } ?? e }
    func pick() { nav.choose([.audio]) { store.setAudio(e, from: $0) } }

    @ViewBuilder var linked: some View {
        let shared = store.sharedBeats(e, b).count + 1
        let name = store.storyboard(e, b)?.name ?? Store.ids(b.img).first.flatMap { store.stillFor(e, id: $0)?.name } ?? "This beat's picture"
        Rectangle().fill(Color.benchLine).frame(height: 1)
        Text("Linked artwork").font(.system(size: 13, weight: .semibold))
        HStack(alignment: .top, spacing: 10) {
            BeatPicture(e: e, b: b).frame(width: 120).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                Text("Used in \(shared) beat\(shared == 1 ? "" : "s")").font(.system(size: 11)).foregroundStyle(Color.benchSoft)
                Button { page = .picture } label: { Label("Open artwork", systemImage: "arrow.up.forward.square") }.controlSize(.small)
            }
        }
    }
    func label(_ t: String) -> some View { Text(t).font(.system(size: 12)).foregroundStyle(Color.benchSoft) }
    func lineBox(_ t: Text) -> some View {
        t.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(8)
            .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
    }
    /// The current line with the words that aren't in the old one marked.
    func diff(old: String) -> Text {
        var out = AttributedString()
        for (i, part) in store.addedWords(old: old, new: b.text).enumerated() {
            if i > 0 { out += AttributedString(" ") }
            var w = AttributedString(part.0)
            if part.1 { w.backgroundColor = Color.benchAmber.opacity(0.35) }
            out += w
        }
        return Text(out)
    }
    func chip(_ t: String, _ s: AudioStatus) -> some View {
        HStack(spacing: 6) {
            Circle().fill(s == .synced ? Color.benchGreen : s == .none ? Color.benchMute : Color.benchAmber).frame(width: 8, height: 8)
            Text(t).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(s == .needsRecording ? Color.benchAmber.opacity(0.12) : Color.benchCard, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(s == .needsRecording ? Color.benchAmber.opacity(0.55) : Color.benchLine))
    }
    func timeRow(_ title: String, _ t: Double, enabled: Bool, _ set: @escaping (Double) -> Void) -> some View {
        PanelRow(label: title) {
            HStack(spacing: 6) {
                Text(benchTenths(t)).font(.system(size: 12).monospacedDigit()).frame(maxWidth: .infinity, alignment: .leading)
                Stepper("", value: Binding(get: { t }, set: { set($0) }), step: 0.1).labelsHidden().controlSize(.small)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
            .disabled(!enabled).opacity(enabled ? 1 : 0.5)
            .help(enabled ? "Moves the next or previous beat with it" : "Sync the recording first")
        }
    }
}

/// Play button and this beat's slice of the waveform. Its own view, so only this redraws as the audio plays.
struct BeatClipPlayer: View {
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var store: Store
    let e: Episode; let b: Beat; let span: (Double, Double)
    @State var peaks: [Float] = []
    @State var length = 0.0
    var slice: [Float] {
        guard length > 0, !peaks.isEmpty else { return [] }
        let c = Double(peaks.count), a = max(0, Int(span.0 / length * c)), z = min(peaks.count, Int(span.1 / length * c))
        return a < z ? Array(peaks[a..<z]) : []
    }
    var body: some View {
        let here = listener.ep == e.n, now = here && listener.playing && listener.nowBeat(e) == b.n
        let part = max(0.01, span.1 - span.0)
        HStack(spacing: 10) {
            Button { now ? listener.pause() : listener.play(e, beat: b.n) } label: {
                Image(systemName: now ? "pause.fill" : "play.fill").font(.system(size: 12)).frame(width: 30, height: 30)
                    .background(Color.benchBlue, in: Circle()).foregroundStyle(.white).contentShape(Circle())
            }.buttonStyle(.plain).help("Play from this beat")
            BeatsWaveform(peaks: slice, progress: here ? (listener.time - span.0) / part : 0) { f in
                let t = span.0 + f * part
                if here { listener.seek(t) } else { listener.play(e, at: t) }
            }.frame(height: 30)
            VStack(alignment: .trailing, spacing: 1) {
                Text(benchTenths(span.0) + " –")
                Text(benchTenths(span.1))
            }.font(.system(size: 10).monospacedDigit()).foregroundStyle(Color.benchSoft).fixedSize()
        }
        .padding(8).background(Color.benchCard, in: RoundedRectangle(cornerRadius: 6)).overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.benchLine))
        .task(id: store.audioURL(e)) {
            guard let u = store.audioURL(e) else { peaks = []; return }
            length = (try? await AVURLAsset(url: u).load(.duration).seconds) ?? 0
            peaks = await Waveforms.peaks(u, count: 12000)
        }
    }
}
