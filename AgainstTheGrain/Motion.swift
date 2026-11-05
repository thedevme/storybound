import SwiftUI

// MARK: - What each beat does on screen

/// How the camera moves on a beat's picture while the line plays.
enum Move: String, CaseIterable, Codable {
    case hold, drift, pushIn, pullOut, panLeft, panRight, reveal, whip, shake
    var label: String {
        switch self {
        case .hold: return "Hold (no move)"
        case .drift: return "Slow drift"
        case .pushIn: return "Push in"
        case .pullOut: return "Pull out"
        case .panLeft: return "Pan left"
        case .panRight: return "Pan right"
        case .reveal: return "Reveal (tight, then out)"
        case .whip: return "Whip from the last beat"
        case .shake: return "Shake (a hit)"
        }
    }
}

/// How the picture arrives from the beat before.
enum Transition: String, CaseIterable, Codable {
    case cut, dissolve, fadeBlack, smashBlack, wash, sketchToPaint, porthole, pageTurn, whip
    var label: String {
        switch self {
        case .cut: return "Cut"
        case .dissolve: return "Dissolve"
        case .fadeBlack: return "Fade through black"
        case .smashBlack: return "Smash to black"
        case .wash: return "Watercolor wash"
        case .sketchToPaint: return "Sketch paints in"
        case .porthole: return "Round window"
        case .pageTurn: return "Page turn"
        case .whip: return "Whip pan"
        }
    }
    var seconds: Double {
        switch self {
        case .cut: return 0
        case .dissolve: return 0.6
        case .fadeBlack: return 1.0
        case .smashBlack: return 0.9
        case .wash: return 1.2
        case .sketchToPaint: return 2.0
        case .porthole: return 0.9
        case .pageTurn: return 0.8
        case .whip: return 0.35
        }
    }
}

/// Your choice for a beat; nil means "use the suggestion".
struct BeatMotion: Codable, Equatable { var move: Move?; var transition: Transition? }

extension Store {
    /// What the beat's picture belongs to, so beats in the same picture cut and whip instead of dissolving.
    func pictureGroup(_ e: Episode, _ b: Beat) -> String { storyboard(e, b).map { "scene:" + $0.id } ?? b.img }

    /// A varied pattern for the whole episode: never the same move three times running, cuts inside a picture,
    /// washes on time jumps, holds on short lines, a shake on hits. Your own choices are left alone.
    func suggestedMotions(_ e: Episode) -> [Int: BeatMotion] {
        let cycle: [Move] = [.pushIn, .panRight, .pullOut, .drift, .panLeft, .reveal]
        let hits = ["roar", "flame", "slam", "cut out", "cuts out", "shout", "crash", "hiss", "burst", "snap", "smash"]
        let jumps = ["earlier", "later", "months", "weeks", "january", "february", "march", "april", "may ", "june", "july",
                     "august", "september", "october", "november", "december", "the next", "years"]
        var out: [Int: BeatMotion] = [:], recent: [Move] = [], k = 0, lastSmash = -99
        for (i, b) in e.beats.enumerated() {
            let prev = i > 0 ? e.beats[i - 1] : nil
            let t = b.text.lowercased()
            let same = prev.map { pictureGroup(e, $0) == pictureGroup(e, b) } ?? false
            let still = b.kind == "built" || stillOf(e, b) != nil
            let sectionStart = i > 0 && e.sections.contains { $0.range.lowerBound == b.n }
            let stillName = stillOf(e, b)?.name.lowercased() ?? ""

            var tr: Transition = .dissolve
            if i == 0 { tr = .fadeBlack }
            else if stillName.contains("month") || stillName.contains("calendar") || stillName.contains("page") { tr = .pageTurn }
            else if sectionStart && jumps.contains(where: t.contains) { tr = .wash }
            else if sectionStart { tr = .fadeBlack }
            else if same || still { tr = .cut }
            else if t.contains("round window") || t.contains("through the glass") || t.contains("porthole") { tr = .porthole }
            else if let p = prev, p.wordCount <= 6, i - lastSmash > 8 { tr = .smashBlack; lastSmash = i }

            var mv: Move
            let f = shownFrame(e, b), pf = prev.flatMap { shownFrame(e, $0) }
            if still { mv = b.wordCount <= 8 ? .hold : .drift }
            else if hits.contains(where: t.contains) { mv = .shake }
            else if b.wordCount <= 5 { mv = .hold }
            else if same, let f, let pf, abs(f.x - pf.x) + abs(f.y - pf.y) > 0.25 { mv = .whip }
            else if !same, (f?.scale ?? 1) >= 1.6 { mv = .reveal }
            else {
                repeat { mv = cycle[k % cycle.count]; k += 1 } while recent.suffix(2).contains(mv)
            }
            recent.append(mv)
            out[b.n] = BeatMotion(move: mv, transition: tr)
        }
        return out
    }

    func motionKey(_ e: Episode, _ b: Beat) -> String { "e\(e.n)b\(b.n)" }
    func chosenMotion(_ e: Episode, _ b: Beat) -> BeatMotion? { state.motion?[motionKey(e, b)] }
    /// What the beat does: your choice where you made one, the suggestion otherwise.
    func motion(_ e: Episode, _ b: Beat) -> (move: Move, transition: Transition) {
        let s = suggestedMotions(e)[b.n] ?? BeatMotion(move: .drift, transition: .dissolve)
        let c = chosenMotion(e, b)
        return (c?.move ?? s.move ?? .drift, c?.transition ?? s.transition ?? .dissolve)
    }
    func setMotion(_ e: Episode, _ b: Beat, move: Move?? = nil, transition: Transition?? = nil) {
        var m = state.motion ?? [:]
        var v = m[motionKey(e, b)] ?? BeatMotion()
        if let move { v.move = move }
        if let transition { v.transition = transition }
        m[motionKey(e, b)] = (v.move == nil && v.transition == nil) ? nil : v
        state.motion = m; save()
    }
    /// About how long the beat is on screen: the line at 150 words a minute, never under two seconds.
    func beatSeconds(_ b: Beat) -> Double { max(2, Double(b.wordCount) / 2.5) }
}

// MARK: - A picture with its move

/// The beat's picture, moving from its start framing to its end framing over the beat. `p` runs 0 to 1.
struct MovingPicture: View, Animatable {
    let image: Image
    let frame: BeatFrame
    let from: BeatFrame?        // the previous beat's framing, for a whip
    let move: Move
    var p: Double
    var animatableData: Double { get { p } set { p = newValue } }

    var body: some View {
        let (a, z) = ends
        let f = BeatFrame(scale: a.scale + (z.scale - a.scale) * p, x: a.x + (z.x - a.x) * p, y: a.y + (z.y - a.y) * p).clamped()
        let shake = move == .shake ? sin(p * 90) * 14 * exp(-7 * p) : 0
        FramedPicture(image: image, frame: f)
            .offset(x: shake, y: shake * 0.6)
            .blur(radius: move == .whip ? sin(.pi * min(1, p * 3)) * 12 : 0)
    }

    /// Where the move starts and ends. Every move ends on the beat's own framing, so what you framed is what holds.
    var ends: (BeatFrame, BeatFrame) {
        let f = frame
        func at(_ s: Double, _ dx: Double = 0, _ dy: Double = 0) -> BeatFrame { BeatFrame(scale: max(1, s), x: f.x + dx, y: f.y + dy).clamped() }
        switch move {
        case .hold, .shake: return (f, f)
        case .drift: return (at(f.scale * 0.97), f)
        case .pushIn: return (at(f.scale * 0.86), f)
        case .pullOut: return (at(f.scale * 1.18), f)
        case .panLeft: return (at(max(f.scale, 1.15), 0.08 / max(f.scale, 1.15)), at(max(f.scale, 1.15)))
        case .panRight: return (at(max(f.scale, 1.15), -0.08 / max(f.scale, 1.15)), at(max(f.scale, 1.15)))
        case .reveal: return (at(f.scale * 2), f)
        case .whip: return (from ?? f, f)
        }
    }
}

/// One beat's moving picture. Starts its move when it appears; give it a new id per beat to restart.
struct BeatShot: View {
    @EnvironmentObject var store: Store
    let e: Episode; let b: Beat
    @State var p = 0.0
    var body: some View {
        let m = store.motion(e, b).move
        let i = e.beats.firstIndex { $0.n == b.n } ?? 0
        let prevFrame = i > 0 ? store.shownFrame(e, e.beats[i - 1]) : nil
        ZStack {
            Color.panel
            if let img = store.picture(e, b) {
                MovingPicture(image: img, frame: store.shownFrame(e, b) ?? BeatFrame(), from: prevFrame, move: m, p: p)
            } else { Text(Store.ids(b.img).first ?? "").font(.serif(64)).foregroundStyle(Color.line) }
        }
        .clipped()
        .onAppear {
            p = 0
            let d = store.beatSeconds(b)
            switch m {
            case .whip: withAnimation(.easeInOut(duration: 0.45)) { p = 1 }
            case .reveal: withAnimation(.easeOut(duration: min(2.4, d * 0.7))) { p = 1 }
            case .shake: withAnimation(.linear(duration: 1.0)) { p = 1 }
            default: withAnimation(.easeInOut(duration: d)) { p = 1 }
            }
        }
    }
}

// MARK: - Transitions between beats

/// The old beat and the new one, mixed by the new beat's transition. `p` runs 0 to 1.
struct TransitionMix: View, Animatable {
    let old: AnyView?
    let new: AnyView
    let kind: Transition
    let sketch: Image?          // for "sketch paints in": the scene's pencil sketch at the same framing
    let frame: BeatFrame?
    var p: Double
    var animatableData: Double { get { p } set { p = newValue } }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, diag = sqrt(w * w + h * h)
            ZStack {
                Color.black
                switch kind {
                case .cut:
                    new
                case .dissolve:
                    old; new.opacity(p)
                case .fadeBlack:
                    old?.opacity(max(0, 1 - 2 * p)); new.opacity(max(0, 2 * p - 1))
                case .smashBlack:
                    new.opacity(p < 0.6 ? 0 : 1)
                case .wash:
                    old
                    new.mask {
                        Circle().fill(.white).frame(width: diag * 1.3 * p, height: diag * 1.3 * p)
                            .position(x: w * 0.35, y: h * 0.55).blur(radius: 60 * (1 - p) + 8)
                    }
                case .porthole:
                    old
                    new.mask { Circle().frame(width: diag * p, height: diag * p).position(x: w / 2, y: h / 2) }
                    Circle().stroke(Color(hex: 0x8d9298), lineWidth: 26 * (1 - p))
                        .frame(width: diag * p, height: diag * p).position(x: w / 2, y: h / 2).opacity(p < 1 ? 1 : 0)
                case .pageTurn:
                    old
                    new.rotation3DEffect(.degrees((1 - p) * -100), axis: (0, 1, 0), anchor: .leading, perspective: 0.45)
                        .shadow(color: .black.opacity(0.5 * (1 - p)), radius: 30)
                case .whip:
                    old?.offset(x: -p * w).blur(radius: sin(.pi * p) * 20)
                    new.offset(x: (1 - p) * w).blur(radius: sin(.pi * p) * 20)
                case .sketchToPaint:
                    if let sketch {
                        FramedPicture(image: sketch, frame: frame)
                        new.mask {
                            LinearGradient(stops: [.init(color: .white, location: max(0, p * 1.4 - 0.4)), .init(color: .clear, location: min(1, p * 1.4))],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                    } else { old; new.opacity(p) }
                }
            }
        }
    }
}

/// The player's picture: each new beat arrives by its transition, then plays its move.
struct PlayerStage: View {
    @EnvironmentObject var store: Store
    let e: Episode
    let index: Int
    @State var from: Int? = nil
    @State var shown = 0
    @State var p = 1.0

    var body: some View {
        let b = e.beats[min(shown, e.beats.count - 1)]
        let t = store.motion(e, b).transition
        let sketch = store.storyboard(e, b).flatMap { store.image(store.sceneSketchKey(e, $0)) }
        TransitionMix(old: from.map { AnyView(BeatShot(e: e, b: e.beats[$0]).id("old\($0)")) },
                      new: AnyView(BeatShot(e: e, b: b).id(b.n)), kind: t, sketch: sketch, frame: store.shownFrame(e, b), p: p)
            .onAppear { shown = index }
            .onChange(of: index) { old, new in
                from = old; shown = new
                let k = store.motion(e, e.beats[min(new, e.beats.count - 1)]).transition
                p = 0
                if k == .cut { p = 1; from = nil; return }
                withAnimation(k == .smashBlack ? .linear(duration: k.seconds) : .easeInOut(duration: k.seconds)) { p = 1 } completion: { from = nil }
            }
    }
}

// MARK: - In the beat panel

/// Pick the beat's move and how it arrives. "Auto" follows the suggested pattern for the episode.
struct MotionBox: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var player: Player
    let e: Episode; let b: Beat
    var body: some View {
        let s = store.suggestedMotions(e)[b.n]
        let c = store.chosenMotion(e, b)
        Box(title: "In the video") {
            Picker("Move", selection: Binding(get: { c?.move }, set: { store.setMotion(e, b, move: .some($0)) })) {
                Text("Auto · \(s?.move?.label ?? "")").tag(Move?.none)
                Divider()
                ForEach(Move.allCases, id: \.self) { Text($0.label).tag(Move?.some($0)) }
            }
            Picker("Arrives by", selection: Binding(get: { c?.transition }, set: { store.setMotion(e, b, transition: .some($0)) })) {
                Text("Auto · \(s?.transition?.label ?? "")").tag(Transition?.none)
                Divider()
                ForEach(Transition.allCases, id: \.self) { Text($0.label).tag(Transition?.some($0)) }
            }
            HStack {
                Button {
                    nav.inspector = false; player.open(e, store: store, at: max(1, b.n - 1)); nav.path.append(.readThrough(e.n))
                } label: { Label("Preview from the beat before", systemImage: "play.rectangle") }
                .controlSize(.small).help("Open the read-through one beat early, so you see this beat arrive")
                Spacer()
                if c != nil { Button("Back to auto") { store.setMotion(e, b, move: .some(nil), transition: .some(nil)) }.controlSize(.small) }
            }
        }
    }
}
