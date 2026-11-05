import SwiftUI

/// The read-through, pushed onto the episode's NavigationStack: picture, the line, controls,
/// clickable progress, and the beat list in the inspector. Back (or Esc) returns to the episode.
struct PlayerView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    let episode: Episode
    var e: Episode { episode }

    var body: some View {
        let _ = store.imageVersion
        let b = e.beats[min(player.index, e.beats.count - 1)]
        // the beat list is a plain column on the right: a nested .inspector here made the page wider than the space
        // beside the sidebar, so the picture slid under it
        HStack(spacing: 0) {
        VStack(spacing: 0) {
            // side by side when there's room, picture above the line when the window is narrow,
            // and never wider than the space left by the sidebars (it used to slide under them)
            GeometryReader { g in
                let wide = g.size.width > 1000
                let layout = wide ? AnyLayout(HStackLayout(alignment: .center, spacing: 40)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                layout {
                    // each beat arrives by its transition, then plays its move (set in the beat panel's "In the video")
                    Group {
                        if player.watching { Color.black } else { PlayerStage(e: e, index: min(player.index, e.beats.count - 1)) }
                    }
                        .aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.line))
                        .frame(maxWidth: wide ? g.size.width * 0.6 : .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 0) {
                            Eyebrow("Beat \(b.n) of \(e.beats.count) · ")
                            Eyebrow(b.img, color: .kind(b.kind))
                        }
                        let m = store.motion(e, b)
                        Text("\(m.transition.label) · \(m.move.label)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.soft)
                        Text(b.text).font(.body(wide ? 34 : 24)).lineSpacing(wide ? 8 : 4).fixedSize(horizontal: false, vertical: true)
                        Text(b.what).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, wide ? 48 : 24).padding(.vertical, wide ? 36 : 20)
                .frame(width: g.size.width, height: g.size.height)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped()
            Divider()
            controls
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        if player.sidebar {
            Divider()
            BeatList(e: e).frame(width: 340).scrollIndicators(.never)
        }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0x0d0c0a))
        .foregroundStyle(Color.ink)
        .navigationTitle("Read-through")
        .navigationSubtitle("\(e.label) · \(e.title)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Voice", selection: Binding(get: { player.mode }, set: { player.setMode($0) })) {
                    ForEach(modes, id: \.0) { m, label in Text(label).tag(m) }
                }.pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { player.watching = true } label: { Label("Watch", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Watch: just the picture, filling the window (F). Esc comes back. ⌃⌘F makes the window fill the screen.")
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $player.sidebar) { Label("Beats", systemImage: "list.bullet") }
                    .toggleStyle(.button).help("Show or hide the beat list (B)")
            }
        }
        .onDisappear { player.close() }
    }

    var controls: some View {
        HStack(spacing: 14) {
            Button { player.step(-1) } label: { Label("Previous beat", systemImage: "backward.fill").labelStyle(.iconOnly) }
                .buttonStyle(.bordered).help("Previous beat (←)")
            Button { player.toggle() } label: {
                Label(player.running ? "Pause" : "Play", systemImage: player.running ? "pause.fill" : "play.fill").labelStyle(.iconOnly).frame(width: 30)
            }
            .buttonStyle(.borderedProminent).tint(.gold).help("Play or pause (Space)")
            Button { player.step(1) } label: { Label("Next beat", systemImage: "forward.fill").labelStyle(.iconOnly) }
                .buttonStyle(.bordered).help("Next beat (→)")
            progress
            Text("\(clock(player.secondsLeft)) left").monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 80, alignment: .trailing)
        }
        .controlSize(.large)
        .padding(.horizontal, 40).padding(.vertical, 18)
    }

    var modes: [(Player.Mode, String)] {
        var m: [(Player.Mode, String)] = []
        if store.audioURL(e) != nil { m.append((.audio, store.isOwnAudio(e) ? "Your recording" : "Voiceover")) }
        m.append((.voice, "Computer voice")); m.append((.silent, "Silent"))
        return m
    }

    var progress: some View {
        GeometryReader { g in
            let total = CGFloat(e.beats.reduce(0) { $0 + max(1, $1.wordCount) })
            let avail = g.size.width - CGFloat(e.beats.count - 1)
            HStack(spacing: 1) {
                ForEach(Array(e.beats.enumerated()), id: \.offset) { i, x in
                    ProgressSeg(color: i <= player.index ? .kind(x.kind) : Color(hex: 0x4a4239), current: i == player.index)
                        .frame(width: max(1, avail * CGFloat(max(1, x.wordCount)) / total))
                        .help("Beat \(x.n): " + (x.text.count > 90 ? String(x.text.prefix(88)) + "…" : x.text))
                        .onTapGesture { player.jump(i) }
                }
            }
        }
        .frame(height: 16).background(Color(hex: 0x2a2520)).clipShape(RoundedRectangle(cornerRadius: 4))
        .help("Click any beat to jump to it")
    }
}

struct ProgressSeg: View {
    let color: Color; let current: Bool
    @State var hover = false
    var body: some View {
        Rectangle().fill(color).brightness(hover ? 0.25 : 0).scaleEffect(y: hover ? 1.25 : 1)
            .overlay { if current { Rectangle().strokeBorder(.white, lineWidth: 2) } }
            .contentShape(Rectangle()).onHover { hover = $0 }
    }
}

struct BeatList: View {
    @EnvironmentObject var player: Player
    let e: Episode
    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { Optional(player.index) }, set: { if let i = $0 { player.jump(i) } })) {
                SwiftUI.Section("\(e.label) · \(e.beats.count) beats") {
                    ForEach(Array(e.beats.enumerated()), id: \.offset) { i, x in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(x.n)").monospacedDigit().foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            Text(x.text).lineLimit(2)
                            Spacer(minLength: 4)
                            if let t = player.startTime(of: i) { Text(clock(t)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary) }
                        }
                        .tag(i).id(i)
                    }
                }
            }
            .onChange(of: player.index) { _, i in withAnimation { proxy.scrollTo(i, anchor: .center) } }
            .onAppear { proxy.scrollTo(player.index, anchor: .center) }
        }
    }
}

/// Watch mode: the moving picture alone on black, as big as the window allows. Space pauses, arrows change beat,
/// Esc or a click on "Done" comes back. The controls fade in when the pointer moves.
struct WatchView: View {
    @EnvironmentObject var player: Player
    let e: Episode
    @State var showControls = true
    @State var hideTask: Task<Void, Never>? = nil
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerStage(e: e, index: min(player.index, e.beats.count - 1))
                .aspectRatio(16 / 9, contentMode: .fit)
            if showControls {
                VStack {
                    HStack {
                        Spacer()
                        Button("Done") { player.watching = false }.buttonStyle(.borderedProminent).tint(.gold)
                    }
                    Spacer()
                    HStack(spacing: 14) {
                        Button { player.step(-1) } label: { Image(systemName: "backward.fill") }
                        Button { player.toggle() } label: { Image(systemName: player.running ? "pause.fill" : "play.fill").frame(width: 24) }
                        Button { player.step(1) } label: { Image(systemName: "forward.fill") }
                        Text("Beat \(min(player.index, e.beats.count - 1) + 1) of \(e.beats.count) · Space pauses · Esc comes back · ⌃⌘F fills the screen")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    }
                    .controlSize(.large).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(.black.opacity(0.55), in: Capsule())
                }
                .padding(24).transition(.opacity)
            }
        }
        .onContinuousHover { _ in poke() }
        .onAppear { poke() }
    }
    /// Shows the controls, then hides them after two seconds of no movement.
    func poke() {
        withAnimation(.easeOut(duration: 0.2)) { showControls = true }
        hideTask?.cancel()
        hideTask = Task { try? await Task.sleep(nanoseconds: 2_000_000_000); if !Task.isCancelled { withAnimation(.easeIn(duration: 0.4)) { showControls = false } } }
    }
}
