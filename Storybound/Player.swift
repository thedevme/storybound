import Foundation
import AVFoundation

/// Read-through: plays an episode beat by beat with its recording, the computer voice, or silently.
final class Player: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    enum Mode: String { case audio, voice, silent }
    @Published var isOpen = false
    @Published var index = 0
    @Published var running = true
    @Published var mode: Mode = .silent
    @Published var secondsLeft: Double = 0
    @Published var watching = false        // the picture alone, filling the window (F or the Watch button; Esc leaves)
    @Published var sidebar = UserDefaults.standard.bool(forKey: "playerSidebar") {
        didSet { UserDefaults.standard.set(sidebar, forKey: "playerSidebar") }
    }

    private(set) var episode: Episode?
    private weak var store: Store?
    private var player: AVPlayer?
    private var observer: Any?
    private var times: [(Double, Double)] = []
    private var timer: Timer?
    private let speech = AVSpeechSynthesizer()

    override init() {
        super.init(); speech.delegate = self
        NotificationCenter.default.addObserver(forName: .listenStarted, object: nil, queue: .main) { [weak self] _ in
            if self?.isOpen == true { self?.close() }
        }
    }

    func hasAudio(_ e: Episode, _ s: Store) -> Bool { s.audioURL(e) != nil }

    func open(_ e: Episode, store s: Store, at beat: Int?) {
        NotificationCenter.default.post(name: .readThroughStarted, object: nil)
        store = s; episode = e
        index = max(0, e.beats.firstIndex { $0.n == beat } ?? 0)
        running = true
        mode = hasAudio(e, s) ? .audio : .voice
        setupAudio()
        isOpen = true
        drive()
    }

    func close() { stopAll(); isOpen = false; watching = false; player = nil; observer = nil }

    func setMode(_ m: Mode) { mode = m; stopAll(); drive() }
    func toggle() { running.toggle(); if running { drive() } else { stopAll(); updateLeft() } }
    func step(_ d: Int) { jump(index + d) }
    func jump(_ i: Int) {
        guard let e = episode else { return }
        index = min(e.beats.count - 1, max(0, i)); drive()
    }

    private func setupAudio() {
        if let o = observer { player?.removeTimeObserver(o); observer = nil }
        player = nil; times = []
        guard let e = episode, let s = store, let url = s.audioURL(e) else { return }
        let p = AVPlayer(url: url)
        player = p
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] t in
            self?.tick(t.seconds)
        }
    }

    private func ensureTimes() {
        guard times.isEmpty, let e = episode, let s = store, let item = player?.currentItem else { return }
        let d = item.duration.seconds
        times = s.beatTimes(e, duration: d.isFinite ? d : Double(e.words) / 150 * 60)
    }

    private func tick(_ t: Double) {
        guard mode == .audio, running, isOpen else { return }
        ensureTimes()
        guard !times.isEmpty else { return }
        var i = times.firstIndex { t >= $0.0 && t < $0.1 } ?? -1
        if i < 0, let last = times.last, t >= last.1 { i = times.count - 1 }
        if i >= 0 && i != index { index = i }
        updateLeft(t)
        if let item = player?.currentItem, item.duration.isNumeric, t >= item.duration.seconds - 0.05 { running = false }
    }

    private func stopAll() {
        timer?.invalidate(); timer = nil
        player?.pause()
        if speech.isSpeaking { speech.stopSpeaking(at: .immediate) }
    }

    private func updateLeft(_ t: Double? = nil) {
        guard let e = episode else { return }
        if mode == .audio, let item = player?.currentItem, item.duration.isNumeric {
            secondsLeft = max(0, item.duration.seconds - (t ?? player?.currentTime().seconds ?? 0))
        } else {
            secondsLeft = Double(e.beats[index...].reduce(0) { $0 + $1.wordCount }) / 150 * 60
        }
    }

    func drive() {
        guard let e = episode else { return }
        stopAll(); updateLeft()
        guard running else { return }
        switch mode {
        case .audio:
            guard let p = player else { mode = .voice; drive(); return }
            let start = {
                self.ensureTimes()
                let s = self.times.indices.contains(self.index) ? self.times[self.index].0 : 0
                p.seek(to: CMTime(seconds: s + 0.01, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in p.play() }
            }
            if p.currentItem?.status == .readyToPlay { start() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.mode == .audio { start() } } }
        case .voice:
            let u = AVSpeechUtterance(string: e.beats[index].text)
            if let v = AVSpeechSynthesisVoice.speechVoices().first(where: { ["Samantha", "Ava", "Allison", "Susan", "Karen", "Moira"].contains($0.name) && $0.language.hasPrefix("en") }) { u.voice = v }
            speech.speak(u)
        case .silent:
            let secs = max(2.2, Double(e.beats[index].wordCount) / 150 * 60)
            timer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
                guard let self, let e = self.episode, self.index < e.beats.count - 1 else { return }
                self.index += 1; self.drive()
            }
        }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async {
            guard self.mode == .voice, self.running, let e = self.episode, self.index < e.beats.count - 1 else { return }
            self.index += 1; self.drive()
        }
    }

    /// When each beat starts in the recording, for the sidebar.
    func startTime(of i: Int) -> Double? {
        if times.isEmpty, let e = episode, let t = e.timing, let s = store, !s.isOwnAudio(e) {
            let m = Dictionary(uniqueKeysWithValues: t.filter { $0.count >= 3 }.map { (Int($0[0]), $0[1]) })
            return episode.flatMap { m[$0.beats[i].n] }
        }
        return times.indices.contains(i) ? times[i].0 : nil
    }
}

func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
