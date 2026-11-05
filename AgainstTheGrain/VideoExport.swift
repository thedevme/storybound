import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Renders an episode to an MP4 on this Mac, no internet or Claude needed: every beat with its move and transition
/// (the same ones the read-through plays), at 1920 × 1080, 23.976 fps, timed to the voiceover and with it as the sound.
/// Saves to ~/Movies/Against the Grain/Ep N/.
@MainActor
final class VideoExporter: ObservableObject {
    @Published var running = false
    @Published var progress = 0.0
    @Published var status = ""
    @Published var output: URL? = nil
    private var cancelled = false

    static let size = CGSize(width: 1920, height: 1080)
    static let timescale: CMTimeScale = 24000, frameTicks: Int64 = 1001      // 23.976 fps

    func cancel() { cancelled = true; status = "Stopping…"; tallProcess?.terminate() }
    private var tallProcess: Process?

    /// Makes a 1080 × 1920 copy of a finished video for phones: the whole picture, with a blurred copy of itself filling
    /// the space above and below. Same sound, same frame rate. Saved beside it as NAME_9x16.mp4; the original stays.
    func makeTall(from source: URL? = nil) async {
        guard !running, let src = source ?? output else { return }
        running = true; cancelled = false; progress = 0
        defer { running = false; tallProcess = nil }
        status = "Making the 9:16 version…"
        let out = src.deletingLastPathComponent().appendingPathComponent(src.deletingPathExtension().lastPathComponent + "_9x16.mp4")
        let length = (try? await AVURLAsset(url: src).load(.duration).seconds) ?? 0
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-v", "error", "-nostdin", "-y", "-i", src.path, "-filter_complex", Self.tallFilter, "-map", "[v]", "-map", "0:a?", "-c:v", "libx264", "-crf", "18", "-preset", "medium",
                       "-pix_fmt", "yuv420p", "-c:a", "copy", "-movflags", "+faststart", "-progress", "pipe:1", "-nostats", out.path]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            guard let text = String(data: h.availableData, encoding: .utf8), length > 0,
                  let line = text.split(separator: "\n").last(where: { $0.hasPrefix("out_time_us=") }), let us = Double(line.dropFirst(12)) else { return }
            Task { @MainActor in self?.progress = min(1, us / 1_000_000 / length) }
        }
        tallProcess = p
        let code: Int32 = await withCheckedContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try p.run(); p.waitUntilExit(); c.resume(returning: p.terminationStatus) } catch { c.resume(returning: -1) }
            }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        if cancelled { try? FileManager.default.removeItem(at: out); status = "Stopped"; return }
        if code == 0 { output = out; progress = 1; status = "Saved \(out.lastPathComponent)" }
        else { try? FileManager.default.removeItem(at: out); status = "Export failed: couldn't make the 9:16 version (ffmpeg stopped with code \(code))" }
    }
    /// Asks which video, then makes its 9:16 copy beside it.
    func chooseAndMakeTall() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.message = "Choose a video to make a 9:16 copy of"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        guard panel.runModal() == .OK, let u = panel.url else { return }
        output = nil
        Task { await makeTall(from: u) }
    }
    /// The same look as the stills: the background fills the frame, blurred and a little darker, with the whole picture across the middle.
    nonisolated static let tallFilter = "[0:v]split=2[a][c];[a]scale=-2:1920,crop=1080:1920,gblur=sigma=40,eq=brightness=-0.12[b];[c]scale=1080:-2[f];[b][f]overlay=0:(H-h)/2,setsar=1[v]"
    var isCancelled: Bool { cancelled }
    func resetForRun() { cancelled = false }
    func writeFrames(frames: Int, to url: URL, frame: (Int, Double) async throws -> CGImage?) async throws { try await writeMovie(frames: frames, to: url, frame: frame) }
    func joinFinished(video: URL, m4a: URL, to out: URL) async throws { try await join(video: video, m4a: m4a, to: out) }

    /// One beat's plan for the video: its picture, framing, move, how it arrives, and when it plays.
    struct Shot { var image: Image?; var frame: BeatFrame; var prev: BeatFrame?; var move: Move; var transition: Transition; var sketch: Image?; var start: Double; var end: Double; var label: String }

    func export(_ e: Episode, store: Store, firstBeats: Int? = nil) async {
        guard !running else { return }
        running = true; cancelled = false; progress = 0; output = nil
        defer { running = false }
        status = "Getting the pictures ready…"
        await Task.yield()

        // timing: the voiceover's beat times when there is one, else 150 words a minute
        let audio = store.audioURL(e)
        var duration = Double(e.words) / 150 * 60
        if let audio, let d = try? await AVURLAsset(url: audio).load(.duration).seconds, d.isFinite, d > 0 { duration = d }
        var times = store.beatTimes(e, duration: duration)
        if times.contains(where: { $0.1 <= $0.0 }) {   // missing timing rows: spread by words
            let w = e.beats.map { Double(max(3, $0.wordCount)) }, tot = w.reduce(0, +)
            var t = 0.0; times = w.map { x in let a = t; t += duration * x / tot; return (a, t) }
        }
        let count = min(e.beats.count, firstBeats ?? e.beats.count)
        var shots: [Shot] = []
        for i in 0..<count {
            let b = e.beats[i], m = store.motion(e, b)
            let start = i == 0 ? 0 : times[i].0
            let end = i == count - 1 ? (firstBeats == nil ? max(times[i].1, duration) : times[i].1) : times[i + 1].0
            shots.append(Shot(image: store.fullPicture(e, b), frame: store.shownFrame(e, b) ?? BeatFrame(),
                              prev: i > 0 ? store.shownFrame(e, e.beats[i - 1]) : nil, move: m.move, transition: m.transition,
                              sketch: store.storyboard(e, b).flatMap { store.image(store.sceneSketchKey(e, $0)) },
                              start: start, end: max(end, start + 0.5), label: Store.ids(b.img).first ?? ""))
        }
        let total = shots.last?.end ?? 0
        let frames = Int((total * Double(Self.timescale) / Double(Self.frameTicks)).rounded(.up))

        // where it goes
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/\(store.projectName)/\(e.seasonN > 1 ? "Season \(e.seasonN)/" : "")Ep \(e.number)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let slug = e.title.replacingOccurrences(of: " ", with: "")
        let final = folder.appendingPathComponent("\(store.hasTrailer ? "AtG" : store.projectName.replacingOccurrences(of: " ", with: ""))_\(e.seasonN > 1 ? "S\(e.seasonN)" : "")Ep\(e.number)_\(slug)\(firstBeats.map { "_test-first\($0)" } ?? "")_23976.mp4")
        let silent = folder.appendingPathComponent(".video-only-\(UUID().uuidString).mp4")

        do {
            try await writeVideo(shots, frames: frames, to: silent)
            if cancelled { try? FileManager.default.removeItem(at: silent); status = "Stopped"; return }
            try? FileManager.default.removeItem(at: final)
            if let audio {
                status = "Adding the voiceover…"
                try await addAudio(video: silent, audio: audio, length: total, to: final, scratch: folder)
                try? FileManager.default.removeItem(at: silent)
            } else {
                try FileManager.default.moveItem(at: silent, to: final)
            }
            output = final; progress = 1
            status = "Done: \(final.lastPathComponent)"
            store.say("Video exported")
        } catch {
            try? FileManager.default.removeItem(at: silent)
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    // MARK: frames

    /// The move's progress at `t` seconds into a beat lasting `d`, eased the way the read-through eases it.
    static func moveP(_ m: Move, _ t: Double, _ d: Double) -> Double {
        func io(_ x: Double) -> Double { let x = min(1, max(0, x)); return x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }
        func out(_ x: Double) -> Double { let x = min(1, max(0, x)); return 1 - pow(1 - x, 3) }
        switch m {
        case .whip: return io(t / 0.45)
        case .reveal: return out(t / min(2.4, d * 0.7))
        case .shake: return min(1, t / 1.0)
        default: return io(t / d)
        }
    }

    func picture(_ s: Shot, _ t: Double) -> AnyView {
        if let img = s.image {
            return AnyView(MovingPicture(image: img, frame: s.frame, from: s.prev, move: s.move, p: Self.moveP(s.move, t, s.end - s.start)))
        }
        return AnyView(ZStack { Color.panel; Text(s.label).font(.serif(96)).foregroundStyle(Color.line) })
    }

    /// The whole picture at `t` seconds: the beat on screen, mixed with the beat before while its transition runs.
    func frameView(_ shots: [Shot], _ t: Double) -> some View {
        let i = shots.lastIndex { $0.start <= t } ?? 0
        let s = shots[i], lt = t - s.start
        var old: AnyView? = nil, p = 1.0, kind = Transition.cut
        if s.transition != .cut, lt < s.transition.seconds {
            kind = s.transition
            let x = lt / s.transition.seconds
            p = kind == .smashBlack ? x : (x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2)
            if i > 0 { let o = shots[i - 1]; old = picture(o, t - o.start) }
        }
        return TransitionMix(old: old, new: picture(s, lt), kind: kind, sketch: s.sketch, frame: s.frame, p: p)
            .frame(width: Self.size.width, height: Self.size.height).background(Color.black).clipped()
    }

    private func writeVideo(_ shots: [Shot], frames: Int, to url: URL) async throws {
        var lastKey = "", lastImage: CGImage? = nil
        try await writeMovie(frames: frames, to: url) { f, t in
            // a beat that holds still renders once and repeats
            let i = shots.lastIndex { $0.start <= t } ?? 0, s = shots[i], lt = t - s.start
            let still = s.move == .hold && (s.transition == .cut || lt >= s.transition.seconds)
            let key = still ? "hold\(i)" : "f\(f)"
            var cg = key == lastKey ? lastImage : nil
            if cg == nil {
                let r = ImageRenderer(content: self.frameView(shots, t))
                r.scale = 1
                cg = r.cgImage
            }
            lastKey = key; lastImage = cg
            return cg
        }
    }

    /// Writes `frames` frames at 1920 × 1080, 23.976 fps, H.264, asking for each picture by frame number and time.
    private func writeMovie(frames: Int, to url: URL, frame: (Int, Double) async throws -> CGImage?) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(Self.size.width), AVVideoHeightKey: Int(Self.size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(Self.size.width), kCVPixelBufferHeightKey as String: Int(Self.size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let began = Date()
        for f in 0..<frames {
            if cancelled { break }
            let t = Double(Int64(f) * Self.frameTicks) / Double(Self.timescale)
            let cg = try await frame(f, t)
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            if let cg, let pool = adaptor.pixelBufferPool, let buf = Self.buffer(cg, pool) {
                adaptor.append(buf, withPresentationTime: CMTime(value: Int64(f) * Self.frameTicks, timescale: Self.timescale))
            }
            if f % 6 == 0 {
                progress = Double(f) / Double(frames) * (0.97)
                let el = Date().timeIntervalSince(began), left = f > 24 ? el / Double(f) * Double(frames - f) : 0
                status = "Rendering frame \(f) of \(frames)" + (left > 0 ? " · about \(Int(left / 60) + 1) min left" : "")
                await Task.yield()
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    private static func buffer(_ cg: CGImage, _ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(origin: .zero, size: size))
        return pb
    }

    // MARK: sound

    /// Puts the voiceover under the video: the MP3 becomes AAC first, then both are joined without re-encoding the picture.
    private func addAudio(video: URL, audio: URL, length: Double, to out: URL, scratch: URL) async throws {
        let m4a = scratch.appendingPathComponent(".voice-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: m4a) }
        guard let toAAC = AVAssetExportSession(asset: AVURLAsset(url: audio), presetName: AVAssetExportPresetAppleM4A) else { throw CocoaError(.fileWriteUnknown) }
        try await toAAC.export(to: m4a, as: .m4a)
        try await join(video: video, m4a: m4a, to: out)
    }

    /// Joins a finished picture and a finished AAC track without re-encoding either.
    private func join(video: URL, m4a: URL, to out: URL) async throws {
        let comp = AVMutableComposition()
        let v = AVURLAsset(url: video), a = AVURLAsset(url: m4a)
        let vd = try await v.load(.duration)
        if let src = try await v.loadTracks(withMediaType: .video).first,
           let dst = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try dst.insertTimeRange(CMTimeRange(start: .zero, duration: vd), of: src, at: .zero)
        }
        if let src = try await a.loadTracks(withMediaType: .audio).first,
           let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let ad = try await a.load(.duration)
            try dst.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(ad, vd)), of: src, at: .zero)
        }
        guard let join = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
        try await join.export(to: out, as: .mp4)
    }
}

// MARK: - The trailer

extension VideoExporter {
    /// Renders the trailer to an MP4, frame for frame what Watch trailer plays (the same TrailerPlanner decides every
    /// frame), with the recording and, if asked, the ambience and any video's own sound. Saves to
    /// ~/Movies/Against the Grain/Trailer/ under a new timestamped name, never over an old file.
    func exportTrailer(_ tm: TrailerModel, store: Store, seconds: Double? = nil, ambience: Bool, folder: URL? = nil) async {
        guard !running else { return }
        running = true; resetForRun(); output = nil; progress = 0
        defer { running = false }
        status = "Getting the pictures ready…"
        await Task.yield()
        tm.reload(store)
        guard let t = tm.trailer else { status = "Export failed: no trailer shot list"; return }
        let timeline = trailerTimeline(t)
        let total = timeline.values.map(\.1).max() ?? t.audio_seconds
        let length = min(total, seconds ?? total)
        let recording = store.kitchen.appendingPathComponent(t.audio)
        let bed = store.kitchen.appendingPathComponent("episodes/ambience/ambience.wav")

        // video lengths, read now (the page reads them in the background)
        var lengths: [String: Double] = [:]
        for s in t.shots { if let v = tm.files[s.id]?.video, let d = try? await AVURLAsset(url: v).load(.duration).seconds, d.isFinite { lengths[s.id] = d } }

        // anything missing is named, before anything renders
        let problems = Self.trailerProblems(t, timeline: timeline, files: tm.files, lengths: lengths, upTo: length)
            + (FileManager.default.fileExists(atPath: recording.path) ? [] : ["the recording \(t.audio)"])
            + (ambience && !FileManager.default.fileExists(atPath: bed.path) ? ["episodes/ambience/ambience.wav (or untick Include ambience)"] : [])
        guard problems.isEmpty else { status = "Export failed: missing \(problems.joined(separator: "; "))"; return }

        let planner = TrailerPlanner(trailer: t, timeline: timeline, files: tm.files, videoLengths: lengths, logoShots: store.logoShots(t))
        let logoFile = store.logoURL
        let frames = Int((length * Double(Self.timescale) / Double(Self.frameTicks)).rounded(.up))

        // a new name every time
        let dir = folder ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Against the Grain/Trailer")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HHmmss"
        let base = "AtG_Trailer_\(f.string(from: Date()))\(seconds.map { "_test-first\(Int($0))s" } ?? "")_23976"
        var final = dir.appendingPathComponent(base + ".mp4"), n = 2
        while FileManager.default.fileExists(atPath: final.path) { final = dir.appendingPathComponent("\(base)-\(n).mp4"); n += 1 }
        let silent = dir.appendingPathComponent(".video-only-\(UUID().uuidString).mp4")
        let m4a = dir.appendingPathComponent(".sound-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: silent); try? FileManager.default.removeItem(at: m4a) }

        do {
            let draw = TrailerFrameDrawer(planner: planner, lengths: lengths, logoFile: logoFile)
            try await writeFrames(frames: frames, to: silent) { _, time in
                try await draw.image(at: min(time, total - 0.001))
            }
            if isCancelled { status = "Stopped"; return }
            status = "Mixing the sound…"
            try await Self.mixTrailerSound(t, timeline: timeline, files: tm.files, recording: recording, ambience: ambience ? bed : nil, length: length, to: m4a)
            status = "Adding the sound…"
            try await joinFinished(video: silent, m4a: m4a, to: final)
            output = final; progress = 1
            status = "Done: \(final.lastPathComponent)"
            store.say("Trailer exported")
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    /// What would come out black or wrong in the first `upTo` seconds, by shot: missing pictures and videos, and gaps in the timing.
    static func trailerProblems(_ t: TrailerFile, timeline: [String: (Double, Double)], files: [String: PanelFiles], lengths: [String: Double], upTo: Double) -> [String] {
        var out: [String] = []
        for s in t.shots {
            guard let span = timeline[s.id] else { out.append("\(s.id): no time (\(s.time))"); continue }
            guard span.0 < upTo else { continue }
            if let v = s.video {
                if files[s.id]?.video == nil { out.append("\(s.id): video \(v)") }
                else if lengths[s.id] == nil { out.append("\(s.id): can't read video \(v)") }
            } else if s.kind == "montage" {
                for p in s.montage ?? [] where files["\(p.episode)/\(p.id)"]?.shown == nil { out.append("\(s.id): panel \(p.id)") }
            } else if files[s.id]?.shown == nil { out.append("\(s.id): no sketch or painting") }
        }
        // every moment needs a shot
        let frame = Double(frameTicks) / Double(timescale)
        var time = 0.0
        while time < upTo - frame {
            if trailerShot(at: time, timeline) == nil { out.append("no shot at \(fmtTime(time))"); break }
            time += frame
        }
        return out
    }

    /// The recording, the ambience from 0:00, and each video's own sound at its video_volume, mixed to AAC.
    static func mixTrailerSound(_ t: TrailerFile, timeline: [String: (Double, Double)], files: [String: PanelFiles], recording: URL, ambience: URL?, length: Double, to out: URL) async throws {
        let comp = AVMutableComposition()
        var params: [AVMutableAudioMixInputParameters] = []
        let scale: CMTimeScale = 48000
        func cm(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: scale) }
        func add(_ url: URL, from: Double, count: Double, at: Double, volume: Float) async throws {
            let asset = AVURLAsset(url: url)
            guard let src = try await asset.loadTracks(withMediaType: .audio).first else { return }
            let have = try await asset.load(.duration).seconds
            let dur = min(count, have - from, length - at)
            guard dur > 0, let dst = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
            try dst.insertTimeRange(CMTimeRange(start: cm(from), duration: cm(dur)), of: src, at: cm(at))
            let p = AVMutableAudioMixInputParameters(track: dst); p.setVolume(volume, at: .zero); params.append(p)
        }
        try await add(recording, from: 0, count: length, at: 0, volume: 1)
        if let ambience { try await add(ambience, from: 0, count: length, at: 0, volume: 1) }
        for s in t.shots {
            guard let v = files[s.id]?.video, let span = timeline[s.id], span.0 < length else { continue }
            let plan = s.videoPlan
            guard plan.volume > 0, let file = try? await AVURLAsset(url: v).load(.duration).seconds else { continue }
            let len = plan.length(file), slot = span.1 - span.0
            if plan.end == "loop" {
                var at = 0.0
                while at < slot { try await add(v, from: plan.inPoint, count: min(len, slot - at), at: span.0 + at, volume: Float(plan.volume / 100)); at += len }
            } else {
                try await add(v, from: plan.inPoint, count: min(len, slot), at: span.0, volume: Float(plan.volume / 100))
            }
        }
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetAppleM4A) else { throw CocoaError(.fileWriteUnknown) }
        let mix = AVMutableAudioMix(); mix.inputParameters = params
        session.audioMix = mix
        session.timeRange = CMTimeRange(start: .zero, duration: cm(length))
        try await session.export(to: out, as: .m4a)
    }
}

/// Draws one trailer frame from the shared plan: pictures read at up to 3840 px, video frames read from the file at the
/// exact time the plan says. A frame identical to the last is reused.
@MainActor
final class TrailerFrameDrawer {
    let planner: TrailerPlanner
    let lengths: [String: Double]
    let logoFile: URL?
    private var pictures: [String: CGImage] = [:]
    private var order: [String] = []
    private var logo: CGImage?
    private var videos: [String: AVAssetImageGenerator] = [:]
    private var lastSig = ""
    private var last: CGImage?
    static let size = VideoExporter.size

    init(planner: TrailerPlanner, lengths: [String: Double], logoFile: URL?) { self.planner = planner; self.lengths = lengths; self.logoFile = logoFile }

    func image(at time: Double) async throws -> CGImage? {
        guard let plan = planner.plan(at: time) else { throw ExportProblem("No shot at \(fmtTime(time))") }
        let sig = [plan.a, plan.b].compactMap { $0 }.map { $0.signature(fileLength: length($0)) }.joined(separator: "+") + "|\(plan.kind.rawValue)|\((plan.q * 1000).rounded())"
        if sig == lastSig, let last { return last }
        let a = try await layer(plan.a)
        let cg: CGImage?
        if let bl = plan.b {
            let b = try await layer(bl)
            let r = ImageRenderer(content: TrailerBlend(k: plan.kind, q: plan.q, a: a, b: b, size: Self.size)
                .frame(width: Self.size.width, height: Self.size.height).background(Color.black).clipped())
            r.scale = 1; cg = r.cgImage
        } else {
            let r = ImageRenderer(content: a.frame(width: Self.size.width, height: Self.size.height).background(Color.black).clipped())
            r.scale = 1; cg = r.cgImage
        }
        guard let cg else { throw ExportProblem("Couldn't draw \(plan.shot) at \(fmtTime(time))") }
        lastSig = sig; last = cg
        return cg
    }
    private func length(_ l: ShotLayer) -> Double? { if case .video(_, _, _, _, let id) = l { return lengths[id] }; return nil }

    private func layer(_ l: ShotLayer) async throws -> AnyView {
        let size = Self.size
        switch l {
        case .video(let u, let into, let plan, let black, let id):
            let time = plan.frame(into, file: lengths[id] ?? .nan).time
            let cg = try await videoFrame(u, time, shot: id)
            return AnyView(ZStack {
                Color.black
                Image(decorative: cg, scale: 1).resizable().scaledToFit()
                if black > 0 { Color.black.opacity(black) }
            }.frame(width: size.width, height: size.height))
        case .montage(let u, let tile, let id):
            guard let u else { throw ExportProblem("\(id): panel \(tile) is missing") }
            let cg = try await picture(u, shot: id)
            return AnyView(Color.black.frame(width: size.width, height: size.height)
                .overlay { Image(decorative: cg, scale: 1).resizable().scaledToFill() }.clipped())
        case .picture(let u, let r, let wantsLogo, let sub, let id):
            guard let u else { throw ExportProblem("\(id) has no sketch or painting") }
            let cg = try await picture(u, shot: id)
            var logoCG: CGImage? = nil
            if wantsLogo, let f = logoFile {
                if logo == nil { logo = await Task.detached { PictureCache.load(f, crop: nil, maxPixel: 1920) }.value }
                logoCG = logo
                if logoCG == nil { throw ExportProblem("\(id): can't read the logo") }
            }
            return AnyView(ZStack {
                Color.black
                Framed(cg: cg, region: r)
                ShotTitles(logo: nil, logoImage: logoCG, subscribe: sub, size: size)
            }.frame(width: size.width, height: size.height).clipped())
        }
    }
    /// Keeps the last few pictures; a transition needs two at once.
    private func picture(_ u: URL, shot: String) async throws -> CGImage {
        if let hit = pictures[u.path] { return hit }
        guard let cg = await Task.detached(priority: .userInitiated, operation: { PictureCache.load(u, crop: nil, maxPixel: 3840) }).value else {
            throw ExportProblem("\(shot): can't read \(u.lastPathComponent)")
        }
        pictures[u.path] = cg; order.append(u.path)
        if order.count > 3 { pictures[order.removeFirst()] = nil }
        return cg
    }
    private func videoFrame(_ u: URL, _ time: Double, shot: String) async throws -> CGImage {
        let g: AVAssetImageGenerator
        if let hit = videos[u.path] { g = hit } else {
            g = AVAssetImageGenerator(asset: AVURLAsset(url: u)); g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            g.maximumSize = CGSize(width: 1920, height: 1080)
            videos[u.path] = g
        }
        do { return try await g.image(at: CMTime(seconds: max(0, time), preferredTimescale: 600)).image }
        catch { throw ExportProblem("\(shot): can't read \(u.lastPathComponent) at \(String(format: "%.2f", time)) s") }
    }
}

struct ExportProblem: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// The trailer's Export video menu, in its toolbar like an episode's.
struct TrailerExportMenu: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var exporter: VideoExporter
    @EnvironmentObject var tm: TrailerModel
    @State var ambience = true
    var body: some View {
        Menu {
            Button("Export the whole trailer") { Task { await exporter.exportTrailer(tm, store: store, ambience: ambience) } }
            Button("Export the whole trailer + 9:16 version") { Task { await exporter.exportTrailer(tm, store: store, ambience: ambience); if exporter.output != nil { await exporter.makeTall() } } }
            Button("Quick test: first 10 seconds") { Task { await exporter.exportTrailer(tm, store: store, seconds: 10, ambience: ambience) } }
            Button("Make 9:16 from a video…") { exporter.chooseAndMakeTall() }
            Divider()
            Toggle("Include ambience", isOn: $ambience)
        } label: { Label("Export video", systemImage: "film") }
        .disabled(exporter.running)
        .help("Render the trailer to an MP4 on this Mac, exactly what Watch trailer plays, into Movies/Against the Grain/Trailer. No internet needed.")
    }
}

/// The Export video menu and, while it runs, its progress. Sits in the episode page's toolbar.
struct ExportVideoMenu: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var exporter: VideoExporter
    let e: Episode
    var body: some View {
        Menu {
            Button("Export the whole episode") { Task { await exporter.export(e, store: store) } }
            Button("Export the whole episode + 9:16 version") { Task { await exporter.export(e, store: store); if exporter.output != nil { await exporter.makeTall() } } }
            Button("Quick test: first 10 beats") { Task { await exporter.export(e, store: store, firstBeats: 10) } }
            Button("Make 9:16 from a video…") { exporter.chooseAndMakeTall() }
        } label: { Label("Export video", systemImage: "film") }
        .disabled(exporter.running)
        .help("Render this episode to an MP4 on this Mac, with every beat's move and transition and the voiceover. No internet needed.")
    }
}

/// While an export runs, a bar at the bottom of the episode page: progress, time left, Stop; then where the file went.
struct ExportStatusBar: View {
    @EnvironmentObject var exporter: VideoExporter
    @Environment(\.openURL) var openURL
    var body: some View {
        if exporter.running || exporter.output != nil || exporter.status.hasPrefix("Export failed") || exporter.status == "Stopped" {
            HStack(spacing: 12) {
                Image(systemName: exporter.running ? "film" : exporter.output != nil ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(exporter.output != nil && !exporter.running ? Color.done : Color.gold)
                if exporter.running { ProgressView(value: exporter.progress).frame(width: 220) }
                Text(exporter.status).font(.system(size: 12)).lineLimit(1)
                Spacer()
                if exporter.running { Button("Stop") { exporter.cancel() }.controlSize(.small) }
                else if let out = exporter.output {
                    Button("Play it") { openURL(out) }.controlSize(.small)
                    if !out.lastPathComponent.hasSuffix("_9x16.mp4") { Button("Make 9:16") { Task { await exporter.makeTall() } }.controlSize(.small).help("Make a tall phone version with a blurred background") }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([out]) }.controlSize(.small)
                }
                if !exporter.running { Button { exporter.output = nil; exporter.status = "" } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.card).overlay(alignment: .top) { Divider() }
        }
    }
}
