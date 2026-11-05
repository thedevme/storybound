import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - The trailer's Voiceover and Script boxes, like an episode's. Shots live in shots.json, so edits save there.

extension TrailerShot {
    /// A line that's actually said. "(Jasmine's reaction, no line)" and "(insert)" are notes, not lines.
    var isSpoken: Bool { !line.trimmingCharacters(in: .whitespaces).hasPrefix("(") && !line.isEmpty }
}

/// What a sync would change. Nothing is written until you press Apply: these times are hand-tuned around the videos.
struct TrailerSyncPlan: Identifiable {
    let id = UUID()
    struct Move: Identifiable { var id: String { shot }; let shot: String; let before: String; let after: String }
    let moves: [Move]
    let unsure: [String]     // spoken shots whose words weren't found in the recording
    let matched: [String: String]
    let heard: [HeardWord]
    let note: String
}

extension Store {
    private static let trailerKey = "trailer"

    /// The trailer's recording, or nil if the file is gone.
    func trailerAudioURL(_ t: TrailerFile) -> URL? {
        let u = kitchen.appendingPathComponent(t.audio)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// Spoken shots whose words aren't what the recording says. The first look takes today's lines as matching it.
    func trailerChanged(_ t: TrailerFile) -> [String] {
        guard let rec = state.recordedLines?[Store.trailerKey] else { return [] }
        return t.shots.filter { $0.isSpoken && rec[$0.id].map { [self] in norm($0) } != norm($0.line) }.map(\.id)
    }
    func trailerNoteRecording(_ t: TrailerFile) {
        guard state.recordedLines?[Store.trailerKey] == nil else { return }
        var all = state.recordedLines ?? [:]
        all[Store.trailerKey] = Dictionary(uniqueKeysWithValues: t.shots.filter(\.isSpoken).map { ($0.id, $0.line) })
        state.recordedLines = all; save()
    }
    var trailerSyncNote: String? { state.syncNotes?[Store.trailerKey] }

    /// Listens to the recording on this Mac, finds where each spoken shot starts, and works out new times. Shots without a
    /// line, and shots whose words weren't found, keep their place between their neighbours. A start within 0.3 s of the
    /// recording is left alone, so hand-tuned cuts stay put when the recording hasn't changed.
    func planTrailerSync(_ t: TrailerFile) async -> TrailerSyncPlan? {
        guard let audio = trailerAudioURL(t) else { say("No recording to sync"); return nil }
        syncing[0] = "Listening to the recording…"
        defer { syncing[0] = nil }
        do {
            let words = try await transcribe(audio)
            let dur = (try? await AVURLAsset(url: audio).load(.duration).seconds) ?? t.audio_seconds
            let spoken = t.shots.filter { $0.isSpoken && $0.span != nil }
            let beats = spoken.enumerated().map { Beat(n: $0.offset + 1, text: $0.element.line, kind: "", img: "", what: "", thumb: nil) }
            let fake = Episode(n: 0, title: "Trailer", made: false, logline: "", summary: [], sections: [], beats: beats, gpt: [], built: [], prep: [],
                               audio: nil, timing: nil, words: 0, ends: "")
            let (rows, unsureN) = align(fake, words, duration: dur)
            let unsure = unsureN.map { spoken[$0 - 1].id }
            // anchors: old start -> start heard in the recording
            var anchors: [(Double, Double)] = [(0, 0)]
            for (i, s) in spoken.enumerated() where !unsure.contains(s.id) && i > 0 {
                guard let old = s.span?.0, rows.indices.contains(i), rows[i].count >= 2 else { continue }
                let heardAt = rows[i][1]
                let new = abs(heardAt - old) < 0.3 ? old : heardAt
                // a start that would squash the shots before it to under half a second is a misheard word: ignore it
                if old > anchors.last!.0, new >= anchors.last!.1 + 0.5 { anchors.append((old, new)) }
            }
            let oldEnd = t.shots.compactMap { $0.span?.1 }.max() ?? t.audio_seconds
            let newEnd = abs(dur - oldEnd) < 0.3 ? oldEnd : dur
            if oldEnd > anchors.last!.0, newEnd > anchors.last!.1 { anchors.append((oldEnd, newEnd)) }
            func warp(_ x: Double) -> Double {
                guard let i = anchors.lastIndex(where: { $0.0 <= x }) else { return x }
                guard i + 1 < anchors.count else { return anchors[i].1 + (x - anchors[i].0) }
                let (a, b) = (anchors[i], anchors[i + 1])
                return ((a.1 + (x - a.0) * (b.1 - a.1) / (b.0 - a.0)) * 10).rounded() / 10
            }
            var moves: [TrailerSyncPlan.Move] = []
            for s in t.shots {
                guard let (a, b) = s.span, let b else { continue }
                let after = "\(fmtTime(warp(a)))-\(fmtTime(warp(b)))"
                if after != "\(fmtTime(a))-\(fmtTime(b))" { moves.append(.init(shot: s.id, before: s.time, after: after)) }
            }
            let matched = Dictionary(uniqueKeysWithValues: spoken.filter { !unsure.contains($0.id) }.map { ($0.id, $0.line) })
            let check = unsure.isEmpty ? "All \(spoken.count) spoken shots found in the recording." : "Check \(unsure.joined(separator: ", ")): their words didn't match the recording."
            return TrailerSyncPlan(moves: moves, unsure: unsure, matched: matched, heard: words.map { HeardWord(w: $0.text, t: $0.start) }, note: check)
        } catch {
            var notes = state.syncNotes ?? [:]; notes[Store.trailerKey] = "Sync failed: \(error.localizedDescription)"; state.syncNotes = notes; save()
            return nil
        }
    }

    /// Saves what the sync heard, and writes the new times to shots.json (a dated copy of the old file is kept beside it).
    func applyTrailerSync(_ plan: TrailerSyncPlan, times: Bool) {
        var rec = state.recordedLines ?? [:]; rec[Store.trailerKey] = plan.matched; state.recordedLines = rec
        var hw = state.heard ?? [:]; hw[Store.trailerKey] = plan.heard; state.heard = hw
        var notes = state.syncNotes ?? [:]; notes[Store.trailerKey] = plan.note; state.syncNotes = notes
        save()
        guard times, !plan.moves.isEmpty else { return }
        backupTrailerShots("sync")
        for m in plan.moves { _ = editShot(m.shot, "time", m.after) }
        say("Shots synced to the recording")
    }

    func backupTrailerShots(_ why: String) {
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd_HHmmss"
        let dst = trailerShotsURL.deletingLastPathComponent().appendingPathComponent("_shots-before-\(why)-\(stamp.string(from: Date())).json")
        try? FileManager.default.copyItem(at: trailerShotsURL, to: dst)
    }

    /// Sets (or removes, with nil) a key at the top of shots.json, keeping everything else.
    func editTrailerTop(_ values: [String: Any?]) -> Bool {
        let script = """
        import json, os, sys
        p, v = sys.argv[1:3]
        d = json.load(open(p))
        for k, x in json.loads(v).items():
            if x is None: d.pop(k, None)
            else: d[k] = x
        t = p + '.tmp'
        open(t, 'w').write(json.dumps(d, indent=2))
        os.replace(t, p)
        """
        var d: [String: Any] = [:]
        for (k, x) in values { d[k] = x ?? NSNull() }
        guard let j = try? JSONSerialization.data(withJSONObject: d), let arg = String(data: j, encoding: .utf8) else { return false }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = ["-c", script, trailerShotsURL.path, arg]
        do { try p.run(); p.waitUntilExit() } catch { return false }
        return p.terminationStatus == 0
    }

    /// Puts a new recording beside the old one in Kitchen/episodes and points the trailer at it. The old file stays; the first
    /// replace remembers it so the trash button can go back.
    func setTrailerAudio(_ t: TrailerFile, from url: URL) async -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .audio) else { say("That is not an audio file."); return false }
        let name = "episodes/Trailer-recording-\(Int(Date().timeIntervalSince1970)).\(url.pathExtension.lowercased())"
        let dst = kitchen.appendingPathComponent(name)
        do { try FileManager.default.copyItem(at: url, to: dst) } catch { say("Couldn't save the audio: \(error.localizedDescription)"); return false }
        let seconds = (try? await AVURLAsset(url: dst).load(.duration).seconds) ?? t.audio_seconds
        var values: [String: Any?] = ["audio": name, "audio_seconds": seconds]
        if t.audio_original == nil { values["audio_original"] = t.audio }
        guard editTrailerTop(values) else { say("Couldn't save the recording (shots.json)"); return false }
        say("Recording added to the trailer. Listening to it…")
        return true
    }
    func removeTrailerAudio(_ t: TrailerFile) -> Bool {
        guard let original = t.audio_original else { return false }
        let u = kitchen.appendingPathComponent(original)
        let done = editTrailerTop(["audio": original, "audio_original": nil])
        if done, let s = try? AVAudioPlayer(contentsOf: u).duration { _ = editTrailerTop(["audio_seconds": s]) }
        return done
    }

    /// Saves changed lines to shots.json and keeps scripts/S1-Trailer-vo-script.txt, the recording script, in step.
    func saveTrailerLines(_ t: TrailerFile, _ lines: [String: String]) -> [String] {
        let changed = t.shots.filter { s in lines[s.id].map { $0 != s.line } ?? false }
        guard !changed.isEmpty else { return [] }
        backupTrailerShots("script")
        for s in changed { _ = editShot(s.id, "line", lines[s.id]!) }
        let text = t.shots.map { s -> TrailerShot in var x = s; x.line = lines[s.id] ?? s.line; return x }.filter(\.isSpoken).map(\.line).joined(separator: "\n\n")
        let url = folder.appendingPathComponent("scripts/S1-Trailer-vo-script.txt")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (text + "\n").write(to: url, atomically: true, encoding: .utf8)
        return changed.map(\.id)
    }
}

/// The Voiceover and Script boxes at the top of the trailer page.
struct TrailerProductionBoxes: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var tm: TrailerModel
    let t: TrailerFile
    @State var target = false
    @State var showScript = false
    @State var plan: TrailerSyncPlan?

    func sync(_ file: TrailerFile) { Task { plan = await store.planTrailerSync(file) } }
    func replace(_ url: URL) {
        Task {
            guard await store.setTrailerAudio(t, from: url) else { return }
            tm.reload(store); tm.audio.reload(store.kitchen.appendingPathComponent(tm.trailer?.audio ?? t.audio))
            if let now = tm.trailer { sync(now) }      // like an episode: a new recording syncs by itself; you still approve the times
        }
    }

    var body: some View {
        let has = store.trailerAudioURL(t) != nil, own = t.audio_original != nil
        let changed = store.trailerChanged(t)
        let busy = store.syncing[0]
        HStack(alignment: .top, spacing: 12) {
            ProductionBox(title: "Voiceover", icon: "waveform", headline: has ? (own ? "Your recording" : "Original voiceover") : "No recording yet",
                          detail: has ? (busy ?? store.trailerSyncNote ?? "Shots follow the voiceover's timing.") : "Drop the trailer's recording on this box.",
                          busy: busy != nil, highlight: target) {
                HStack(spacing: 8) {
                    if has {
                        Button { sync(t) } label: { Label("Sync shots", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(.borderedProminent).tint(.gold).disabled(busy != nil)
                            .help("Listen to the recording on this Mac and find where every line is said. Shows you the new times before anything changes.")
                    }
                    Button { nav.choose([.audio]) { replace($0) } } label: { Label(has ? "Replace…" : "Choose MP3…", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered)
                    if own {
                        Button(role: .destructive) {
                            if store.removeTrailerAudio(t) { tm.reload(store); tm.audio.reload(store.kitchen.appendingPathComponent(tm.trailer?.audio ?? t.audio)) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered).help("Go back to the original voiceover. The new file stays in Kitchen/episodes.")
                    }
                }
            }
            .fileDrop(targeted: $target) { replace($0) }
            ProductionBox(title: "Script", icon: "text.quote",
                          headline: changed.isEmpty ? "Matches the recording" : "Re-record \(changed.count) line\(changed.count == 1 ? "" : "s")",
                          detail: changed.isEmpty ? "Edit any line; the ones you change are listed here to record again." : "Changed since the recording: \(changed.joined(separator: ", ")).",
                          alert: !changed.isEmpty) {
                Button { showScript = true } label: { Label("Edit script…", systemImage: "pencil") }
                    .buttonStyle(.borderedProminent).tint(.gold)
            }
        }
        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 760)
        .onAppear { store.trailerNoteRecording(t) }
        .sheet(isPresented: $showScript) { TrailerScriptSheet(t: t).environmentObject(store).environmentObject(tm) }
        .sheet(item: $plan) { p in TrailerSyncSheet(plan: p).environmentObject(store).environmentObject(tm) }
    }
}

/// What a sync found. Apply writes the times; Keep my times saves only which lines match the recording.
struct TrailerSyncSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    @Environment(\.dismiss) var dismiss
    let plan: TrailerSyncPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync shots to the recording").font(.serif(22))
            Text(plan.note).font(.system(size: 12)).foregroundStyle(plan.unsure.isEmpty ? Color.soft : Color.gold)
            if plan.moves.isEmpty {
                Text("Every shot already matches the recording. No times change.").font(.system(size: 13))
            } else {
                Text("\(plan.moves.count) shot\(plan.moves.count == 1 ? "" : "s") would move. A copy of shots.json is kept first.").font(.system(size: 13, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(plan.moves) { m in
                            HStack(spacing: 10) {
                                Text(m.shot).font(.system(size: 12, weight: .bold)).frame(width: 44, alignment: .leading)
                                Text(m.before).foregroundStyle(Color.soft).frame(width: 110, alignment: .leading)
                                Image(systemName: "arrow.right").foregroundStyle(Color.soft)
                                Text(m.after)
                            }.font(.system(size: 12).monospacedDigit())
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 340)
            }
            HStack {
                Spacer()
                Button("Keep my times") { store.applyTrailerSync(plan, times: false); dismiss() }.keyboardShortcut(.cancelAction)
                if !plan.moves.isEmpty {
                    Button("Apply new times") { store.applyTrailerSync(plan, times: true); tm.reload(store); dismiss() }
                        .buttonStyle(.borderedProminent).tint(.gold)
                }
            }
        }.padding(24).frame(width: 520)
    }
}

/// The trailer's script, one editable line per shot, like an episode's.
struct TrailerScriptSheet: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var tm: TrailerModel
    @Environment(\.dismiss) var dismiss
    let t: TrailerFile
    @State var lines: [String: String] = [:]
    @State var find = ""
    @State var hit = 0
    @State var jump: String? = nil
    @State var result: String? = nil

    var shots: [TrailerShot] { (tm.trailer ?? t).shots }
    func text(_ s: TrailerShot) -> String { lines[s.id] ?? s.line }
    var numbered: String { shots.map { "[\($0.id)] \(text($0))" }.joined(separator: "\n\n") }
    var voiceover: String { shots.filter { $0.isSpoken }.map { text($0) }.joined(separator: "\n\n") }
    var hits: [String] {
        let q = find.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let id = q.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        return shots.filter { $0.id.lowercased() == id || text($0).range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }.map(\.id)
    }
    func go(_ d: Int) {
        let h = hits; guard !h.isEmpty else { return }
        hit = (hit + d + h.count) % h.count
        jump = h[hit]
    }

    var body: some View {
        let h = hits, redo = Set(store.trailerChanged(tm.trailer ?? t))
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Season 1 Trailer · script").font(.serif(22))
                Spacer()
                CopyButton(text: numbered, title: "Copy with shot numbers")
                CopyButton(text: voiceover, title: "Copy voiceover only")
                Button { paste() } label: { Label("Paste script", systemImage: "doc.on.clipboard") }.controlSize(.small)
                    .help("Bring back a script you copied out and fixed: every [T02] line replaces that shot's line here")
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.soft)
                TextField("Find a word or a shot number", text: $find).textFieldStyle(.roundedBorder)
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
                        ForEach(shots) { s in
                            let edited = text(s) != s.line, match = h.contains(s.id), current = jump == s.id
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(s.id).font(.system(size: 12, weight: .bold).monospacedDigit())
                                    .foregroundStyle(match ? Color.gold : Color.soft).frame(width: 36, alignment: .trailing)
                                TextField("", text: Binding(get: { text(s) }, set: { lines[s.id] = $0 }), axis: .vertical)
                                    .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(s.isSpoken ? Color.ink : Color.soft)
                                if redo.contains(s.id) { Text("RE-RECORD").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.gold) }
                                else if edited { Text("EDITED").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.soft) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(current ? Color.gold.opacity(0.16) : match ? Color.gold.opacity(0.07) : Color.card, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(current ? Color.gold : .clear, lineWidth: 1.5))
                            .id(s.id)
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
                    let changed = store.saveTrailerLines(tm.trailer ?? t, lines)
                    tm.reload(store); lines = [:]
                    result = changed.isEmpty ? "No lines changed." : "Saved. Changed: \(changed.joined(separator: ", ")). The recording script is updated too."
                }.keyboardShortcut("s").buttonStyle(.borderedProminent).tint(.gold)
            }
        }
        .padding(24).frame(minWidth: 860, minHeight: 680)
    }

    /// Reads a [T02] script from the clipboard into the lines here (nothing is saved until Save).
    func paste() {
        guard let c = NSPasteboard.general.string(forType: .string) else { result = "The clipboard has no text."; return }
        var n = 0
        let ids = Set(shots.map(\.id))
        for p in c.components(separatedBy: "[") {
            guard let close = p.firstIndex(of: "]") else { continue }
            let id = p[..<close].trimmingCharacters(in: .whitespaces)
            guard ids.contains(id) else { continue }
            let line = p[p.index(after: close)...].split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
            if !line.isEmpty { lines[id] = line; n += 1 }
        }
        result = n == 0 ? "No [T02] lines found in the clipboard." : "Pasted \(n) lines. Check them, then Save."
    }
}
