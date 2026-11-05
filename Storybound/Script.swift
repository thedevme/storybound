import SwiftUI
import AVFoundation

// MARK: - Editing the script

extension Store {
    /// The episode's lines as you last saved them, else as written. Your edits live in your saved state, so a rebuild of
    /// season.json never loses them.
    func applyLineEdits() {
        guard var s = season else { return }
        if originalLines.isEmpty {
            for e in s.eps { originalLines[e.n] = Dictionary(uniqueKeysWithValues: e.beats.map { ($0.n, $0.text) }) }
        }
        for i in s.eps.indices {
            let n = s.eps[i].n
            for j in s.eps[i].beats.indices {
                let b = s.eps[i].beats[j]
                s.eps[i].beats[j].text = state.lines?["e\(n)b\(b.n)"] ?? originalLines[n]?[b.n] ?? b.text
            }
        }
        season = s
    }

    /// "[12] The line." per beat, a blank line between: what you copy, edit and paste back.
    func numberedScript(_ e: Episode) -> String { e.beats.map { "[\($0.n)] \($0.text)" }.joined(separator: "\n\n") }

    /// Just the voiceover: one paragraph per chapter, the way the recording script is written.
    func voScript(_ e: Episode) -> String {
        let secs = e.sections.isEmpty ? [Section(span: "1-\(e.beats.count)", title: "", opts: [])] : e.sections
        return secs.map { s in e.beats.filter { s.range.contains($0.n) }.map(\.text).joined(separator: " ") }
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The lines as they were when the current recording was made: saved when you sync a recording, else the original script.
    func recordedLine(_ e: Episode, _ n: Int) -> String? { state.recordedLines?["e\(e.n)"]?[String(n)] ?? originalLines[e.n]?[n] }
    /// Beats whose words aren't what the recording says, so they need recording again. After a sync it compares each
    /// line with the words actually heard in that beat; before one, with the lines as they were written.
    func changedSinceRecording(_ e: Episode) -> [Int] {
        // the times as synced, not any cut you've moved: moving a cut doesn't change what's in the recording
        if let heard = state.heard?["e\(e.n)"], let times = state.alignedTimes?["e\(e.n)"] ?? state.syncTimes?["e\(e.n)"] {
            let at = Dictionary(uniqueKeysWithValues: times.compactMap { r in r.count >= 3 ? (Int(r[0]), (r[1], r[2])) : nil })
            return e.beats.filter { b in
                guard let (a, z) = at[b.n] else { return false }
                var pool = heard.filter { $0.t >= a - 0.6 && $0.t <= z + 0.6 }.flatMap { $0.w.split(separator: " ").map(String.init) }
                // numbers are said as words ("112,000"), so they don't count either way
                let want = norm(b.text).split(separator: " ").map(String.init).filter { !$0.allSatisfy(\.isNumber) }
                var missed = 0
                for w in want { if let k = pool.firstIndex(where: { sameWord($0, w) }) { pool.remove(at: k) } else { missed += 1 } }
                return !want.isEmpty && missed >= 2 && Double(missed) / Double(want.count) > 0.2
            }.map(\.n)
        }
        return e.beats.filter { b in recordedLine(e, b.n).map { norm($0) != norm(b.text) } ?? false }.map(\.n)
    }
    /// Close enough to be the same spoken word: whisper writes "Vos" for Voss and "herd" for heard.
    func sameWord(_ a: String, _ b: String) -> Bool { sameSpokenWord(a, b) }
    func norm(_ s: String) -> String { normalizedWords(s) }
    /// The "[n] line" pieces of a numbered script.
    func numberedLines(_ text: String) -> [Int: String] {
        var found: [Int: String] = [:]
        for p in text.components(separatedBy: "[") {
            guard let close = p.firstIndex(of: "]"), let n = Int(p[..<close].trimmingCharacters(in: .whitespaces)) else {
                if let last = found.keys.max(), !p.isEmpty { found[last, default: ""] += "[" + p }   // a "[" inside a line
                continue
            }
            found[n] = String(p[p.index(after: close)...])
        }
        return found
    }
    /// What importing this script would do, saving nothing.
    func previewScript(_ e: Episode, _ text: String) -> (changed: [Int], unknown: [Int], found: Int) {
        let found = numberedLines(text), known = Dictionary(uniqueKeysWithValues: e.beats.map { ($0.n, $0.text) })
        let changed = found.compactMap { n, raw -> Int? in
            guard let was = known[n] else { return nil }
            let t = oneLine(raw)
            return !t.isEmpty && t != was ? n : nil
        }
        return (changed.sorted(), found.keys.filter { known[$0] == nil }.sorted(), found.count)
    }
    func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// One beat's line, typed in place. False when there was nothing to save (no change, or left blank).
    @discardableResult func saveLine(_ e: Episode, _ n: Int, _ text: String) -> Bool {
        let t = oneLine(text)
        guard !t.isEmpty, let was = e.beats.first(where: { $0.n == n })?.text, t != was else { return false }
        var lines = state.lines ?? [:]
        lines["e\(e.n)b\(n)"] = t == originalLines[e.n]?[n] ? nil : t
        state.lines = lines; save(); applyLineEdits()
        if let ep = season?.eps.first(where: { $0.n == e.n }) { writeVOScript(ep) }
        return true
    }

    /// Reads a pasted "[n] line" script and saves every line that differs. Returns what changed and anything it couldn't read.
    func saveScript(_ e: Episode, _ text: String) -> (changed: [Int], unknown: [Int], missing: [Int]) {
        let found = numberedLines(text)
        var lines = state.lines ?? [:], changed: [Int] = []
        let known = Set(e.beats.map(\.n))
        for (n, raw) in found where known.contains(n) {
            let t = raw.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            guard !t.isEmpty else { continue }
            let key = "e\(e.n)b\(n)"
            let before = lines[key] ?? originalLines[e.n]?[n] ?? ""
            if t != before { changed.append(n) }
            lines[key] = t == originalLines[e.n]?[n] ? nil : t
        }
        state.lines = lines; save(); applyLineEdits()
        if !changed.isEmpty, let ep = season?.eps.first(where: { $0.n == e.n }) { writeVOScript(ep) }
        return (changed.sorted(), found.keys.filter { !known.contains($0) }.sorted(), known.subtracting(found.keys).sorted())
    }

    /// Keeps scripts/S1-EPnn-Title-vo-script.txt (the recording script) in step with your edits. The first time, the
    /// original is kept beside it as .bak-before-app-edits.
    func writeVOScript(_ e: Episode) {
        let dir = folder.appendingPathComponent("scripts")
        let name = String(format: "S1-EP%02d-", e.n) + e.title.replacingOccurrences(of: " ", with: "-") + "-vo-script.txt"
        let url = dir.appendingPathComponent(name), bak = dir.appendingPathComponent(name + ".bak-before-app-edits")
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) && !fm.fileExists(atPath: bak.path) { try? fm.copyItem(at: url, to: bak) }
        try? (voScript(e) + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The episode's script, one editable line per beat. Search jumps to the beats that match; Copy takes it out
/// numbered (or as plain voiceover), Paste brings a numbered script back in, Save keeps it.
struct ScriptSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let e: Episode
    @State var lines: [Int: String] = [:]
    @State var find = ""
    @State var hit = 0
    @State var jump: Int? = nil
    @State var result: String? = nil

    var numbered: String { e.beats.map { "[\($0.n)] \(lines[$0.n] ?? $0.text)" }.joined(separator: "\n\n") }
    /// The beats whose line (or number, like "52" or "[52]") matches the search.
    var hits: [Int] {
        let q = find.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let num = Int(q.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")))
        return e.beats.filter { b in b.n == num || (lines[b.n] ?? b.text).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.n)
    }
    func go(_ d: Int) {
        let h = hits; guard !h.isEmpty else { return }
        hit = (hit + d + h.count) % h.count
        jump = h[hit]
    }

    var body: some View {
        let h = hits, redo = Set(store.changedSinceRecording(e))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(e.label) · \(e.title) · script").font(.serif(22))
                Spacer()
                CopyButton(text: numbered, title: "Copy with beat numbers")
                CopyButton(text: store.voScript(e), title: "Copy voiceover only")
                Button { paste() } label: { Label("Paste script", systemImage: "doc.on.clipboard") }.controlSize(.small)
                    .help("Bring back a script you copied out and fixed: every [number] line replaces that beat's line here")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.soft)
                TextField("Find a word or a beat number", text: $find).textFieldStyle(.roundedBorder)
                    .onSubmit { go(1) }
                    .onChange(of: find) { _, _ in hit = -1; go(1) }
                Text(find.isEmpty ? "" : h.isEmpty ? "No match" : "\(max(1, hit + 1)) of \(h.count)")
                    .font(.system(size: 12)).foregroundStyle(Color.soft).frame(minWidth: 64)
                Button { go(-1) } label: { Image(systemName: "chevron.up") }.disabled(h.isEmpty).help("Previous match")
                Button { go(1) } label: { Image(systemName: "chevron.down") }.disabled(h.isEmpty).help("Next match (Return)")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(e.beats) { b in
                            let edited = (lines[b.n] ?? b.text) != b.text, match = h.contains(b.n), current = jump == b.n
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(b.n)").font(.system(size: 12, weight: .bold).monospacedDigit())
                                    .foregroundStyle(match ? Color.gold : Color.soft).frame(width: 28, alignment: .trailing)
                                TextField("", text: Binding(get: { lines[b.n] ?? b.text }, set: { lines[b.n] = $0 }), axis: .vertical)
                                    .textFieldStyle(.plain).font(.system(size: 15))
                                if redo.contains(b.n) { Text("RE-RECORD").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.gold) }
                                else if edited { Text("EDITED").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.soft) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(current ? Color.gold.opacity(0.16) : match ? Color.gold.opacity(0.07) : Color.card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Color.gold : .clear, lineWidth: 1.5))
                            .id(b.n)
                        }
                    }.padding(2)
                }
                .onChange(of: jump) { _, n in if let n { withAnimation { proxy.scrollTo(n, anchor: .center) } } }
            }
            if let result { Text(result).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.gold) }
            HStack {
                Button("Undo my changes here") { lines = [:]; result = nil }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let r = store.saveScript(e, numbered)
                    var msg = r.changed.isEmpty ? "No lines changed." : "Saved. Changed: beat \(r.changed.map(String.init).joined(separator: ", ")). The recording script file is updated too."
                    if !r.unknown.isEmpty { msg += " Ignored unknown beat numbers: \(r.unknown.map(String.init).joined(separator: ", "))." }
                    result = msg
                    lines = [:]
                }.keyboardShortcut("s").buttonStyle(.borderedProminent).tint(.gold)
            }
        }
        .padding(24).frame(minWidth: 860, minHeight: 680)
    }

    /// Reads a numbered script from the clipboard into the lines here (nothing is saved until Save).
    func paste() {
        guard let t = NSPasteboard.general.string(forType: .string) else { result = "The clipboard has no text."; return }
        var n = 0
        for p in t.components(separatedBy: "[") {
            guard let close = p.firstIndex(of: "]"), let k = Int(p[..<close].trimmingCharacters(in: .whitespaces)),
                  e.beats.contains(where: { $0.n == k }) else { continue }
            let line = p[p.index(after: close)...].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ")
            if !line.isEmpty { lines[k] = line; n += 1 }
        }
        result = n == 0 ? "No [number] lines found in the clipboard." : "Pasted \(n) lines. Check them, then Save."
    }
}

// MARK: - Syncing the beats to a recording

/// One word heard in a recording and when it starts, kept so the app can tell which lines no longer match it.
struct HeardWord: Codable { var w: String; var t: Double }

extension Store {
    /// The Edit page listens for word times when it opens. The off-screen check turns this off.
    static var listensForWords = true
    /// 2: whisper's word-level alignment, each start then checked against the sound of the recording.
    static let wordMethodNow = 2
    func noteWordMethod(_ e: Episode) { var w = state.wordMethod ?? [:]; w["e\(e.n)"] = Store.wordMethodNow; state.wordMethod = w }
    var whisperModel: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/whisper-cpp/ggml-small.en.bin") }

    /// Listens to the recording on this Mac (whisper, offline), finds where every beat's words start, and saves those times.
    /// Each cut lands 0.15 s before the line starts. Beats whose words couldn't be found are placed between their neighbours
    /// and listed, so you can check them.
    @MainActor func syncBeats(_ e: Episode) async {
        guard let audio = audioURL(e) else { say("No recording to sync"); return }
        syncing[e.n] = "Listening to the recording…"
        defer { syncing[e.n] = nil }
        do {
            let words = try await transcribe(audio)
            let dur = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? (words.last?.end ?? 0)
            let (times, unsure) = align(e, words, duration: dur)
            var all = state.syncTimes ?? [:]; all["e\(e.n)"] = times; state.syncTimes = all
            state.alignedTimes?["e\(e.n)"] = nil
            setCutBase(e, times); retimeUndo[e.n] = nil
            var hw = state.heard ?? [:]; hw["e\(e.n)"] = words.map { HeardWord(w: $0.text, t: $0.start) }; state.heard = hw; noteWordMethod(e)
            var rec = state.recordedLines ?? [:]; rec["e\(e.n)"] = Dictionary(uniqueKeysWithValues: e.beats.map { (String($0.n), $0.text) }); state.recordedLines = rec
            var notes = state.syncNotes ?? [:]
            notes["e\(e.n)"] = unsure.isEmpty ? "Synced \(e.beats.count) beats to the recording."
                : "Synced \(e.beats.count) beats. Check beat \(unsure.map(String.init).joined(separator: ", ")): their words didn't match the recording."
            state.syncNotes = notes
            save(); say("Beats synced to the recording")
        } catch {
            var notes = state.syncNotes ?? [:]; notes["e\(e.n)"] = "Sync failed: \(error.localizedDescription)"; state.syncNotes = notes; save()
        }
    }

    /// Listens to the recording and saves when each word is said. Every cut stays where it is; where the lines really
    /// fall goes in alignedTimes, for the check of lines that don't match the recording. One recording at a time.
    @MainActor func getWords(_ e: Episode) async {
        guard let audio = audioURL(e), syncing[e.n] == nil else { return }
        syncing[e.n] = "Waiting to listen…"
        let previous = wordJob
        let job = Task { @MainActor in
            await previous?.value
            defer { syncing[e.n] = nil }
            syncing[e.n] = "Listening to the recording…"
            do {
                let words = try await transcribe(audio)
                guard audioURL(e) == audio else { return }
                let dur = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? (words.last?.end ?? 0)
                let (times, _) = align(e, words, duration: dur)
                var kept = state.alignedTimes ?? [:]; kept["e\(e.n)"] = times; state.alignedTimes = kept
                var hw = state.heard ?? [:]; hw["e\(e.n)"] = words.map { HeardWord(w: $0.text, t: $0.start) }; state.heard = hw; noteWordMethod(e)
                save(); say("Word times ready for \(e.label)")
            } catch { say("Couldn't get word times: \(error.localizedDescription)") }
        }
        wordJob = job
        await job.value
    }

    /// Where an episode's lined-up words are kept, so they're only worked out once.
    func wordCacheFile(_ e: Episode) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("AgainstTheGrain-words").appendingPathComponent(folder.path.replacingOccurrences(of: "/", with: "_") + "-e\(e.n).json")
    }

    /// Listens to the recording again and moves only this beat's start and end; its neighbours meet it there.
    /// An episode that has never been synced gets every beat's times, since it has none to keep.
    @MainActor func syncBeat(_ e: Episode, _ n: Int) async {
        guard let audio = audioURL(e) else { say("No recording to sync"); return }
        syncing[e.n] = "Listening to the recording…"
        defer { syncing[e.n] = nil }
        do {
            let words = try await transcribe(audio)
            let dur = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? (words.last?.end ?? 0)
            let (times, unsure) = align(e, words, duration: dur)
            guard let row = times.first(where: { $0.first == Double(n) }) else { return }
            var all = state.syncTimes ?? [:]
            if var mine = all["e\(e.n)"], let i = mine.firstIndex(where: { $0.first == Double(n) }) {
                mine[i] = row
                if i > 0, mine[i - 1].count >= 3 { mine[i - 1][2] = row[1] }
                if i + 1 < mine.count, mine[i + 1].count >= 3 { mine[i + 1][1] = row[2] }
                all["e\(e.n)"] = mine
            } else { all["e\(e.n)"] = times }
            state.syncTimes = all
            if var base = state.cutBase?["e\(e.n)"] {
                base[String(n)] = row[1]
                if let i = e.beats.firstIndex(where: { $0.n == n }), i + 1 < e.beats.count { base[String(e.beats[i + 1].n)] = row[2] }
                state.cutBase?["e\(e.n)"] = base
            }
            if var kept = state.alignedTimes?["e\(e.n)"], let i = kept.firstIndex(where: { $0.first == Double(n) }) { kept[i] = row; state.alignedTimes?["e\(e.n)"] = kept }
            var hw = state.heard ?? [:]; hw["e\(e.n)"] = words.map { HeardWord(w: $0.text, t: $0.start) }; state.heard = hw; noteWordMethod(e)
            var rec = state.recordedLines ?? [:]; var mineRec = rec["e\(e.n)"] ?? Dictionary(uniqueKeysWithValues: e.beats.map { (String($0.n), $0.text) })
            mineRec[String(n)] = e.beats.first { $0.n == n }?.text; rec["e\(e.n)"] = mineRec; state.recordedLines = rec
            var notes = state.syncNotes ?? [:]
            notes["e\(e.n)"] = unsure.contains(n) ? "Synced beat \(n), but its words didn't match the recording. Check it." : "Synced beat \(n) to the recording."
            state.syncNotes = notes
            save(); say("Beat \(n) synced")
        } catch {
            var notes = state.syncNotes ?? [:]; notes["e\(e.n)"] = "Sync failed: \(error.localizedDescription)"; state.syncNotes = notes; save()
        }
    }

    /// Moves a beat's start or end by hand. The beat next to it moves with it, so there's never a gap or an overlap.
    func setBeatTime(_ e: Episode, _ n: Int, start: Double? = nil, end: Double? = nil) {
        var t = beatTimes(e, duration: estimatedLength(e))
        guard let i = e.beats.firstIndex(where: { $0.n == n }), t.indices.contains(i) else { return }
        let gap = 0.1
        // before the first move, note where the cuts were, so a re-time can tell this one was set by hand
        if state.cutBase?["e\(e.n)"] == nil {
            setCutBase(e, savedCutRows(e) ?? e.beats.indices.map { [Double(e.beats[$0].n), t[$0].0, t[$0].1] })
        }
        if let s = start {
            let lo = i > 0 ? t[i - 1].0 + gap : 0, hi = t[i].1 - gap
            guard lo <= hi else { return }
            t[i].0 = min(hi, max(lo, s))
            if i > 0 { t[i - 1].1 = t[i].0 }
        }
        if let z = end {
            let lo = t[i].0 + gap, hi = i + 1 < t.count ? t[i + 1].1 - gap : Double.infinity
            guard lo <= hi else { return }
            t[i].1 = min(hi, max(lo, z))
            if i + 1 < t.count { t[i + 1].0 = t[i].1 }
        }
        var all = state.syncTimes ?? [:]
        // the first move keeps the synced times, so the check for lines that don't match the recording still has them
        if state.heard?["e\(e.n)"] != nil, state.alignedTimes?["e\(e.n)"] == nil, let was = all["e\(e.n)"] {
            var kept = state.alignedTimes ?? [:]; kept["e\(e.n)"] = was; state.alignedTimes = kept
        }
        all["e\(e.n)"] = e.beats.indices.map { [Double(e.beats[$0].n), t[$0].0, t[$0].1] }
        state.syncTimes = all
        save()
    }
    /// Puts an episode's beat times back, for Undo.
    func restoreBeatTimes(_ e: Episode, _ was: [[Double]]?) {
        var all = state.syncTimes ?? [:]; all["e\(e.n)"] = was; state.syncTimes = all
        if let r = retimeUndo[e.n], r.times == was { state.cutBase?["e\(e.n)"] = r.base; retimeUndo[e.n] = nil }
        save()
    }

    func setCutBase(_ e: Episode, _ rows: [[Double]]) {
        var all = state.cutBase ?? [:]
        all["e\(e.n)"] = Dictionary(rows.compactMap { $0.count >= 2 ? (String(Int($0[0])), $0[1]) : nil }, uniquingKeysWith: { a, _ in a })
        state.cutBase = all
    }
    /// The times in the newest backup that has this episode: from before the app started keeping track of moved cuts.
    func savedCutRows(_ e: Episode) -> [[Double]]? {
        let files = (try? FileManager.default.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil)) ?? []
        for f in files.filter({ $0.lastPathComponent.hasPrefix("state.backup") && $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            if let d = try? Data(contentsOf: f), let s = try? JSONDecoder().decode(UserState.self, from: d), let rows = s.syncTimes?["e\(e.n)"] { return rows }
        }
        return nil
    }
    /// The beats whose cuts you've set by hand: the ones that aren't where the app last put them.
    func movedCuts(_ e: Episode) -> [Int] {
        guard let current = state.syncTimes?["e\(e.n)"] else { return [] }
        let base = state.cutBase?["e\(e.n)"] ?? savedCutRows(e).map { Dictionary($0.compactMap { $0.count >= 2 ? (String(Int($0[0])), $0[1]) : nil }, uniquingKeysWith: { a, _ in a }) }
        guard let base else { return [] }
        return current.compactMap { r in
            guard r.count >= 2, let b = base[String(Int(r[0]))], abs(b - r[1]) > 0.005 else { return nil }
            return Int(r[0])
        }
    }

    /// Lines the cuts up with the word times, leaving alone every cut you set by hand and any line that doesn't match the recording.
    @MainActor func retimeCuts(_ e: Episode) async {
        if state.alignedTimes?["e\(e.n)"] == nil || (state.wordMethod?["e\(e.n)"] ?? 1) < Store.wordMethodNow { await getWords(e) }
        guard let auto = state.alignedTimes?["e\(e.n)"] else { say("Couldn't re-time: no word times for this recording yet"); return }
        let moved = movedCuts(e), unmatched = changedSinceRecording(e).filter { !moved.contains($0) }
        let now = beatTimes(e, duration: estimatedLength(e))
        var want: [Int: Double] = [:]; var lastEnd = now.last?.1 ?? 0
        for r in auto where r.count >= 3 { want[Int(r[0])] = r[1]; lastEnd = max(lastEnd, r[2]) }
        let beats = e.beats.map(\.n)
        let starts = mergedCuts(beats: beats, current: now.map(\.0), wanted: beats.map { want[$0] }, keep: Set(moved + unmatched))
        retimeUndo[e.n] = (state.syncTimes?["e\(e.n)"], state.cutBase?["e\(e.n)"])
        var all = state.syncTimes ?? [:]
        all["e\(e.n)"] = beats.indices.map { [Double(beats[$0]), starts[$0], $0 + 1 < beats.count ? starts[$0 + 1] : lastEnd] }
        state.syncTimes = all
        // where the app would have put each; a cut you set stays different, so it stays yours
        var base = state.cutBase?["e\(e.n)"] ?? [:]
        for (k, n) in beats.enumerated() where !moved.contains(n) { base[String(n)] = starts[k] }
        var bases = state.cutBase ?? [:]; bases["e\(e.n)"] = base; state.cutBase = bases
        var notes = state.syncNotes ?? [:]
        notes["e\(e.n)"] = "Re-timed \(beats.count - moved.count - unmatched.count) cuts."
            + (moved.isEmpty ? "" : " Kept your cuts on beat \(moved.map(String.init).joined(separator: ", ")).")
            + (unmatched.isEmpty ? "" : " Left beat \(unmatched.map(String.init).joined(separator: ", ")) alone: the line doesn't match the recording.")
        state.syncNotes = notes
        save(); say("Cuts re-timed")
    }

    /// The words heard in the recording during this beat, from the last sync.
    func heardLine(_ e: Episode, _ n: Int) -> String? {
        guard let heard = state.heard?["e\(e.n)"], let r = (state.alignedTimes?["e\(e.n)"] ?? state.syncTimes?["e\(e.n)"])?.first(where: { $0.first == Double(n) }), r.count >= 3 else { return nil }
        let w = heard.filter { $0.t >= r[1] - 0.05 && $0.t < r[2] }.map(\.w)
        return w.isEmpty ? nil : w.joined(separator: " ")
    }

    /// Which words of the new line aren't in the old one, as (word, isNew) in order. A standard longest-common-subsequence.
    func addedWords(old: String, new: String) -> [(String, Bool)] {
        // "critic's" is heard as "critic s": a word is compared by its first piece
        func word(_ x: String) -> String { norm(x).split(separator: " ").first.map(String.init) ?? "" }
        let a = old.split(whereSeparator: \.isWhitespace).map { word(String($0)) }
        let bRaw = new.split(whereSeparator: \.isWhitespace).map(String.init), b = bRaw.map { word($0) }
        guard !bRaw.isEmpty else { return [] }
        var c = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    c[i][j] = sameWord(a[i], b[j]) ? c[i + 1][j + 1] + 1 : max(c[i + 1][j], c[i][j + 1])
                }
            }
        }
        var out: [(String, Bool)] = [], i = 0, j = 0
        while j < b.count {
            if i < a.count, sameWord(a[i], b[j]) { out.append((bRaw[j], false)); i += 1; j += 1 }
            else if i < a.count, c[i + 1][j] >= c[i][j + 1] { i += 1 }
            else { out.append((bRaw[j], true)); j += 1 }
        }
        return out
    }

    struct Word { var text: String; var start: Double; var end: Double }

    /// whisper.cpp, word by word: ffmpeg makes a 16 kHz WAV, whisper-cli writes JSON with each word's time.
    func transcribe(_ audio: URL) async throws -> [Word] {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("atg-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let wav = tmp.appendingPathComponent("a.wav")
        try await run("/opt/homebrew/bin/ffmpeg", ["-v", "error", "-y", "-i", audio.path, "-ar", "16000", "-ac", "1", wav.path])
        let out = tmp.appendingPathComponent("w")
        // -dtw is whisper's word-level alignment, and it needs -nfa to run; the plain word times can be most of a second out
        try await run("/opt/homebrew/bin/whisper-cli", ["-m", whisperModel.path, "-f", wav.path, "-dtw", "small.en", "-nfa", "-ojf", "-of", out.path, "-np"])
        let data = try Data(contentsOf: out.appendingPathExtension("json"))
        struct J: Decodable {
            struct Seg: Decodable { var tokens: [T] }
            struct T: Decodable { struct O: Decodable { var from: Int; var to: Int }; var text: String; var offsets: O; var t_dtw: Int? }
            var transcription: [Seg]
        }
        let tokens = try JSONDecoder().decode(J.self, from: data).transcription.flatMap(\.tokens)
            .map { WhisperToken(text: $0.text, from: Double($0.offsets.from) / 1000, wordEnd: ($0.t_dtw ?? -1) >= 0 ? Double($0.t_dtw!) / 100 : nil) }
        let found = await Task.detached(priority: .userInitiated) { placeWords(tokens, levels: soundLevels(wav)) }.value
        // one entry per word: "didn't" heard as one piece becomes "didn" and "t", like the script's words
        return found.flatMap { w in norm(w.text).split(separator: " ").map { Word(text: String($0), start: w.start, end: w.end) } }
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // waits on its own thread, holding the process, so the end of a quick tool can't be missed
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
                p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                do {
                    try p.run(); p.waitUntilExit()
                    if p.terminationStatus == 0 { c.resume() } else {
                        c.resume(throwing: NSError(domain: "sync", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: tool).lastPathComponent) stopped with code \(p.terminationStatus)"]))
                    }
                } catch { c.resume(throwing: error) }
            }
        }
    }

    /// Lines the script's words up with the heard words (a standard edit-distance alignment), then takes each beat's
    /// first matched word as its start. Returns [n, start, end] per beat and the beats that matched poorly.
    func align(_ e: Episode, _ heard: [Word], duration: Double) -> ([[Double]], [Int]) {
        var script: [(word: String, beat: Int)] = []
        for (i, b) in e.beats.enumerated() { for w in norm(b.text).split(separator: " ") { script.append((String(w), i)) } }
        let n = script.count, m = heard.count
        // dp over (script word, heard word): 0 cost for a match, 1 for a skip or a substitution
        var cost = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = Int32(i) }
        for j in 0...m { cost[0][j] = Int32(j) }
        if n > 0 && m > 0 {
            for i in 1...n { for j in 1...m {
                let same = script[i - 1].word == heard[j - 1].text
                cost[i][j] = min(cost[i - 1][j - 1] + (same ? 0 : 1), cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            } }
        }
        var match = [Int?](repeating: nil, count: n)      // script word -> heard word
        var i = n, j = m
        while i > 0 && j > 0 {
            let same = script[i - 1].word == heard[j - 1].text
            if cost[i][j] == cost[i - 1][j - 1] + (same ? 0 : 1) { if same { match[i - 1] = j - 1 }; i -= 1; j -= 1 }
            else if cost[i][j] == cost[i - 1][j] + 1 { i -= 1 } else { j -= 1 }
        }
        // each beat: its first matched word's start, and how much of it matched
        var starts = [Double?](repeating: nil, count: e.beats.count), unsure: [Int] = []
        for b in e.beats.indices {
            let idx = script.indices.filter { script[$0].beat == b }
            let hits = idx.compactMap { match[$0] }
            if let first = idx.first(where: { match[$0] != nil }).flatMap({ match[$0] }) {
                // back off by how far into the beat the first matched word is (so a missed first word doesn't cut late)
                let lead = Double(idx.firstIndex { match[$0] != nil } ?? 0) * 0.3
                starts[b] = max(0, heard[first].start - lead)
            }
            if idx.isEmpty || Double(hits.count) / Double(idx.count) < 0.5 { unsure.append(e.beats[b].n) }
        }
        starts[0] = 0
        // fill gaps between known starts, then cut 0.15 s early and keep them in order
        var k = 0
        while k < starts.count {
            if starts[k] == nil {
                let a = (0..<k).last { starts[$0] != nil }.map { starts[$0]! } ?? 0
                let nx = (k..<starts.count).first { starts[$0] != nil }
                let b = nx.map { starts[$0]! } ?? duration
                let span = (nx ?? starts.count) - ((0..<k).last { starts[$0] != nil } ?? 0)
                let step = (b - a) / Double(max(1, span))
                starts[k] = a + step * Double(k - ((0..<k).last { starts[$0] != nil } ?? 0))
            }
            k += 1
        }
        var t = starts.enumerated().map { $0.offset == 0 ? 0 : max(0, $0.element! - 0.15) }
        for x in 1..<max(1, t.count) { t[x] = max(t[x], t[x - 1] + 0.3) }
        let rows = e.beats.indices.map { b in [Double(e.beats[b].n), t[b], b + 1 < t.count ? t[b + 1] : max(duration, t[b] + 0.5)] }
        return (rows, unsure)
    }
}

// MARK: - Words

nonisolated func normalizedWords(_ s: String) -> String { s.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ") }
/// Close enough to be the same spoken word: whisper writes "Vos" for Voss and "herd" for heard.
nonisolated func sameSpokenWord(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    guard a.count >= 3, b.count >= 3 else { return false }
    if a.hasPrefix(b) || b.hasPrefix(a) { return abs(a.count - b.count) <= 1 }
    guard a.count >= 4, abs(a.count - b.count) <= 1 else { return false }
    // one letter different, added or dropped
    let x = Array(a), y = Array(b)
    var d = [Int](0...y.count)
    for i in 1...x.count {
        var prev = d[0]; d[0] = i
        for j in 1...y.count { let t = d[j]; d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (x[i - 1] == y[j - 1] ? 0 : 1)); prev = t }
    }
    return d[y.count] <= 1
}

/// One word in the recording and when it's said: spelled as in the script when it lines up with the script, else as heard.
struct TimedWord: Identifiable, Sendable, Codable {
    let t: Double; let text: String; let inScript: Bool
    var id: Double { t * 1000 + Double(text.count) / 100 }
}

/// Each beat's new start: the wanted time, unless it's kept or has none. A cut can't land on or before the one ahead of it.
nonisolated func mergedCuts(beats: [Int], current: [Double], wanted: [Double?], keep: Set<Int>) -> [Double] {
    var out: [Double] = []
    for i in beats.indices {
        var t = keep.contains(beats[i]) ? current[i] : (wanted[i] ?? current[i])
        // the next kept cut is fixed, so this one has to come in before it
        if !keep.contains(beats[i]), let next = beats.indices.dropFirst(i + 1).first(where: { keep.contains(beats[$0]) }), t >= current[next] - 0.1 * Double(next - i) { t = current[i] }
        if let last = out.last, t <= last + 0.1, !keep.contains(beats[i]) { t = last + 0.1 }
        out.append(t)
    }
    return out
}

struct WhisperToken: Sendable { let text: String; let from: Double; let wordEnd: Double? }

/// How loud the recording is every 10 ms. Reads the 16-bit wav the sync makes.
nonisolated func soundLevels(_ wav: URL) -> [Float] {
    guard let d = try? Data(contentsOf: wav, options: .mappedIfSafe) else { return [] }
    return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
        func u32(_ at: Int) -> Int { Int(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
        var at = 12
        while at + 8 <= raw.count {
            let size = u32(at + 4)
            if raw[at] == 0x64, raw[at + 1] == 0x61, raw[at + 2] == 0x74, raw[at + 3] == 0x61 {   // "data"
                let samples = min(size, raw.count - at - 8) / 2, start = at + 8, hop = 160
                var out = [Float](); out.reserveCapacity(samples / hop + 1)
                var i = 0
                while i + hop <= samples {
                    var sum: Float = 0
                    for k in i..<(i + hop) { let v = Float(raw.loadUnaligned(fromByteOffset: start + k * 2, as: Int16.self)); sum += v * v }
                    out.append((sum / Float(hop)).squareRoot()); i += hop
                }
                return out
            }
            at += 8 + size + (size & 1)
        }
        return []
    }
}

/// Puts whisper's pieces together into words and finds where each starts. Whisper's alignment says where each piece ends,
/// so a word starts about where the piece before it ended; then the sound decides. In silence, it starts when the sound does.
/// With silence just before it, it starts right after that. Otherwise it moves to a nearby dip between two words, if there's one.
nonisolated func placeWords(_ tokens: [WhisperToken], levels env: [Float]) -> [(text: String, start: Double, end: Double)] {
    var pieces: [(text: String, raw: Double, end: Double)] = [], before: Double? = nil
    for t in tokens where !t.text.hasPrefix("[") {
        let end = t.wordEnd ?? t.from
        if pieces.isEmpty || (t.text.hasPrefix(" ") && !t.text.trimmingCharacters(in: .whitespaces).isEmpty) {
            pieces.append((t.text.trimmingCharacters(in: .whitespaces), before ?? t.from, end))
        } else { pieces[pieces.count - 1].text += t.text; pieces[pieces.count - 1].end = end }
        before = end
    }
    guard !env.isEmpty else { return pieces.map { ($0.text, $0.raw, max($0.end, $0.raw)) } }
    let sorted = env.sorted(), quiet = max(sorted[sorted.count / 10] * 3, sorted[sorted.count * 95 / 100] * 0.03)
    func frame(_ t: Double) -> Int { min(env.count - 1, max(0, Int((t * 100).rounded()))) }
    func place(_ raw: Double, after last: Double) -> Double {
        let i = frame(raw), earliest = frame(last) + 6
        if env[i] < quiet {
            var j = i
            while j < env.count - 1, j - i < 200, env[j] < quiet { j += 1 }
            return env[j] >= quiet ? Double(j) / 100 : raw
        }
        var j = i
        while j > max(earliest, i - 15) { if env[j] < quiet { return Double(j + 1) / 100 }; j -= 1 }
        let lo = max(earliest, i - 8), hi = min(env.count, i + 9)
        guard lo < hi else { return max(raw, last + 0.06) }
        let k = (lo..<hi).min { env[$0] < env[$1] } ?? i
        return env[k] < 0.6 * env[i] ? Double(k) / 100 : max(raw, last + 0.06)
    }
    var out: [(text: String, start: Double, end: Double)] = [], last = -1.0
    for p in pieces {
        let t = max(place(p.raw, after: last), last + 0.06)
        out.append((p.text, t, max(p.end, t + 0.05))); last = t
    }
    return out
}

/// The lined-up words from the last time, if the script and the heard words are still the same. Otherwise works them out and keeps them.
nonisolated func savedTimedWords(file: URL, script: [String], heard: [(w: String, t: Double)]) -> [TimedWord] {
    guard !heard.isEmpty else { return [] }
    struct Saved: Codable { var key: String; var words: [TimedWord] }
    let key = script.joined(separator: " ") + "|" + heard.map { "\($0.w)@\($0.t)" }.joined(separator: " ")
    if let d = try? Data(contentsOf: file), let s = try? JSONDecoder().decode(Saved.self, from: d), s.key == key { return s.words }
    let words = timedWords(script: script, heard: heard)
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(Saved(key: key, words: words)) { try? d.write(to: file, options: .atomic) }
    return words
}

/// Lines the script's words up with the heard words, so the timeline can show "Voss" where whisper wrote "vos".
nonisolated func timedWords(script: [String], heard: [(w: String, t: Double)]) -> [TimedWord] {
    var pieces: [(word: String, token: Int, first: Bool)] = []
    for (k, tok) in script.enumerated() {
        for (p, w) in normalizedWords(tok).split(separator: " ").enumerated() { pieces.append((String(w), k, p == 0)) }
    }
    let n = pieces.count, m = heard.count, w = m + 1
    guard m > 0 else { return [] }
    var c = [Int32](repeating: 0, count: (n + 1) * w)
    if n > 0 {
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                c[i * w + j] = sameSpokenWord(pieces[i].word, heard[j].w) ? c[(i + 1) * w + j + 1] + 1 : max(c[(i + 1) * w + j], c[i * w + j + 1])
            }
        }
    }
    var out: [TimedWord] = [], i = 0, j = 0, said = Set<Int>()
    func tidy(_ s: String) -> String { s.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
    while j < m {
        if i < n, sameSpokenWord(pieces[i].word, heard[j].w) {
            if said.insert(pieces[i].token).inserted { out.append(TimedWord(t: heard[j].t, text: tidy(script[pieces[i].token]), inScript: true)) }
            i += 1; j += 1
        } else if i < n, c[(i + 1) * w + j] >= c[i * w + j + 1] { i += 1 }
        else { out.append(TimedWord(t: heard[j].t, text: heard[j].w, inScript: false)); j += 1 }
    }
    return out
}
