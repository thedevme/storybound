import Foundation
import AVFoundation

extension Notification.Name {
    static let readThroughStarted = Notification.Name("readThroughStarted")
    static let listenStarted = Notification.Name("listenStarted")
}

/// Plays the whole season's audio, episode after episode, and knows which section and line you're in.
final class Listener: ObservableObject {
    @Published var ep: Int? = nil
    @Published var playing = false
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Float = 1 { didSet { player?.volume = volume } }

    weak var store: Store?
    private var player: AVPlayer?
    private var tick: Any?
    private var endWatch: NSObjectProtocol?
    private var times: [(Double, Double)] = []
    private var ready: NSKeyValueObservation?
    private var pending: Double? = nil      // where to start once the file is ready

    init() {
        NotificationCenter.default.addObserver(forName: .readThroughStarted, object: nil, queue: .main) { [weak self] _ in self?.pause() }
    }

    // MARK: what the season looks like

    /// An episode's sections; an episode without sections is one section.
    static func sections(_ e: Episode) -> [Section] {
        e.sections.isEmpty ? [Section(span: "1-\(e.beats.count)", title: "The full episode", opts: [])] : e.sections
    }
    /// How long an episode runs: measured when we have it, else by word count.
    func length(_ e: Episode) -> Double {
        if ep == e.n, duration > 0 { return duration }
        if let store, !store.isOwnAudio(e), let last = e.timing?.last, last.count >= 3 { return last[2] + 1 }
        return Double(e.words) / 150 * 60
    }
    func beatTimes(_ e: Episode) -> [(Double, Double)] {
        if ep == e.n, !times.isEmpty { return times }
        return store?.beatTimes(e, duration: length(e)) ?? []
    }
    /// Where each section starts in the recording.
    func sectionStarts(_ e: Episode) -> [Double] {
        let t = beatTimes(e)
        return Listener.sections(e).map { s in
            let i = e.beats.firstIndex { s.range.contains($0.n) } ?? 0
            return t.indices.contains(i) ? t[i].0 : 0
        }
    }
    func sectionIndex(_ e: Episode, at t: Double) -> Int {
        let s = sectionStarts(e)
        return max(0, (s.lastIndex { $0 <= t + 0.05 }) ?? 0)
    }
    func beatIndex(_ e: Episode, at t: Double) -> Int {
        let bt = beatTimes(e)
        if let i = bt.firstIndex(where: { t >= $0.0 && t < $0.1 }) { return i }
        return max(0, (bt.lastIndex { $0.0 <= t }) ?? 0)
    }
    /// Beat times moved while this episode is loaded.
    func refreshTimes(_ e: Episode) { if ep == e.n, duration > 0, let store { times = store.beatTimes(e, duration: duration) } }
    var episode: Episode? { store?.season?.eps.first { $0.n == ep } }

    // MARK: playback

    func play(_ e: Episode, at start: Double = 0) {
        guard let store, let url = store.audioURL(e) else { store?.say("\(e.label) has no recording yet"); return }
        NotificationCenter.default.post(name: .listenStarted, object: nil)
        if ep != e.n || player == nil {
            teardown()
            let p = AVPlayer(url: url)
            p.volume = volume
            player = p; ep = e.n; times = []; duration = 0; time = start
            tick = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
                guard let self else { return }
                self.time = t.seconds
                if self.duration == 0, let d = p.currentItem?.duration, d.isNumeric, d.seconds > 0 {
                    self.duration = d.seconds
                    self.times = store.beatTimes(e, duration: d.seconds)
                }
            }
            endWatch = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
                self?.nextEpisode()
            }
        }
        playing = true
        if player?.currentItem?.status == .readyToPlay { seek(start); player?.play() }
        else {
            pending = start
            ready = player?.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                guard item.status == .readyToPlay else { return }
                DispatchQueue.main.async {
                    guard let self, let at = self.pending else { return }
                    self.pending = nil; self.seek(at); if self.playing { self.player?.play() }
                }
            }
        }
    }
    /// Plays an episode from the start of one of its beats.
    func play(_ e: Episode, beat n: Int?) {
        let i = e.beats.firstIndex { $0.n == n } ?? 0
        let t = beatTimes(e)
        play(e, at: t.indices.contains(i) ? t[i].0 : 0)
    }
    /// Play or pause this episode; a different episode starts at the beat given.
    func toggle(_ e: Episode, from n: Int?) {
        if ep == e.n { toggle() } else { play(e, beat: n) }
    }
    /// The beat the recording is on, while this episode is loaded.
    func nowBeat(_ e: Episode) -> Int? {
        guard ep == e.n else { return nil }
        let i = beatIndex(e, at: time)
        return e.beats.indices.contains(i) ? e.beats[i].n : nil
    }

    func seek(_ t: Double) {
        time = t
        player?.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func toggle() {
        if playing { pause() }
        else if let e = episode { play(e, at: time) }
        else if let first = store?.season?.eps.first(where: { store?.audioURL($0) != nil }) { play(first) }
    }
    func pause() { player?.pause(); playing = false }
    func stop() { teardown(); ep = nil; time = 0; duration = 0 }

    func nextSection() {
        guard let e = episode else { return }
        let s = sectionStarts(e), i = sectionIndex(e, at: time)
        if i + 1 < s.count { play(e, at: s[i + 1]) } else { nextEpisode() }
    }
    func prevSection() {
        guard let e = episode else { return }
        let s = sectionStarts(e), i = sectionIndex(e, at: time)
        // a couple of seconds into a section goes back to its start, like a music player
        if time - s[i] > 3 { play(e, at: s[i]) }
        else if i > 0 { play(e, at: s[i - 1]) }
        else { prevEpisode() }
    }
    func nextEpisode() {
        guard let eps = store?.season?.eps, let n = ep else { return }
        if let next = eps.first(where: { $0.n > n && store?.audioURL($0) != nil }) { play(next) }
        else { pause(); seek(0); store?.say("End of the season") }
    }
    func prevEpisode() {
        guard let eps = store?.season?.eps, let n = ep else { return }
        if let prev = eps.last(where: { $0.n < n && store?.audioURL($0) != nil }) { play(prev) } else { seek(0) }
    }

    private func teardown() {
        player?.pause()
        if let tick { player?.removeTimeObserver(tick) }
        if let endWatch { NotificationCenter.default.removeObserver(endWatch) }
        tick = nil; endWatch = nil; ready = nil; pending = nil; player = nil; playing = false
    }
}
