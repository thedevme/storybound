import SwiftUI

/// The whole season as audio: every episode broken into its sections. Click a section to start there;
/// it plays on into the next episode.
struct ListenView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var nav: Nav
    let season: Season

    var body: some View {
        let total = season.eps.reduce(0) { $0 + (store.audioURL($1) != nil ? listener.length($1) : 0) }
        ScrollViewReader { proxy in
            List {
                ForEach(season.eps) { e in
                    let has = store.audioURL(e) != nil
                    let current = listener.ep == e.n
                    let starts = listener.sectionStarts(e)
                    let now = current ? listener.sectionIndex(e, at: listener.time) : -1
                    SwiftUI.Section {
                        if has {
                            ForEach(Array(Listener.sections(e).enumerated()), id: \.offset) { i, sec in
                                Button { listener.play(e, at: starts.indices.contains(i) ? starts[i] : 0) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: i == now && listener.playing ? "speaker.wave.2.fill" : "play.fill")
                                            .font(.caption).foregroundStyle(i == now ? Color.gold : .secondary).frame(width: 18)
                                        Text(sec.title).fontWeight(i == now ? .semibold : .regular)
                                        Text("Beats \(sec.span)").font(.caption).foregroundStyle(.tertiary)
                                        Spacer()
                                        Text(clock(starts.indices.contains(i) ? starts[i] : 0)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                    }.contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(i == now ? Color.gold.opacity(0.14) : nil)
                            }
                        } else {
                            Text("No recording yet. Drop the MP3 on the episode page.").foregroundStyle(.secondary)
                        }
                    } header: {
                        HStack(spacing: 10) {
                            Text("\(e.label) · \(e.title)").font(.headline).foregroundStyle(current ? Color.gold : .primary)
                            if has { Text("\(Listener.sections(e).count) sections · \(clock(listener.length(e)))\(store.isOwnAudio(e) ? " · your recording" : "")").foregroundStyle(.secondary) }
                            Spacer()
                            Button("Open episode") { nav.open(ep: e.n) }.buttonStyle(.link)
                            if has {
                                Button { current ? listener.toggle() : listener.play(e) } label: {
                                    Label(current && listener.playing ? "Pause" : "Play from the top",
                                          systemImage: current && listener.playing ? "pause.fill" : "play.fill")
                                }.controlSize(.small)
                            }
                        }.padding(.vertical, 4)
                    }
                    .id(e.n)
                }
            }
            .onChange(of: listener.ep) { _, n in if let n { withAnimation { proxy.scrollTo(n, anchor: .top) } } }
        }
        .navigationTitle("Listen")
        .navigationSubtitle("\(season.eps.filter { store.audioURL($0) != nil }.count) of 10 recorded · \(clock(total)) · Space plays, ← → skip a section")
    }
}

/// The player bar across the top.
struct NowPlaying: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var listener: Listener
    @EnvironmentObject var nav: Nav
    @EnvironmentObject var trailerModel: TrailerModel
    let season: Season

    var body: some View {
        if nav.showsTrailer, let t = trailerModel.trailer {
            TrailerNowPlaying(audio: trailerModel.audio, clock: trailerModel.audio.clock, trailer: t)
        } else {
            episodeBar
        }
    }

    @ViewBuilder var episodeBar: some View {
        let e = listener.episode
        // everything on one center line: controls, then what's playing, then the progress bar
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ctrl("backward.end.fill", "Previous episode") { listener.prevEpisode() }
                ctrl("backward.fill", "Previous section (←)") { listener.prevSection() }
                Button { listener.toggle() } label: {
                    Image(systemName: listener.playing ? "pause.fill" : "play.fill").font(.system(size: 18))
                        .frame(width: 46, height: 46).background(Color.gold, in: Circle()).foregroundStyle(Color.dark).contentShape(Circle())
                }.buttonStyle(.plain).help("Play or pause (Space)")
                ctrl("forward.fill", "Next section (→)") { listener.nextSection() }
                ctrl("forward.end.fill", "Next episode") { listener.nextEpisode() }
            }
            if let e {
                let si = listener.sectionIndex(e, at: listener.time)
                let secs = Listener.sections(e)
                let bi = listener.beatIndex(e, at: listener.time)
                HStack(spacing: 6) {
                    Eyebrow("\(e.label) · \(e.title)")
                    Eyebrow("· \(secs[min(si, secs.count - 1)].title)", color: .soft)
                }
                Text(e.beats.isEmpty ? "" : e.beats[min(bi, e.beats.count - 1)].text).font(.body(16)).lineLimit(1).truncationMode(.tail)
                    .multilineTextAlignment(.center).frame(maxWidth: 900)
                HStack(spacing: 12) {
                    Text(clock(listener.time)).frame(width: 44, alignment: .trailing)
                    SectionBar(e: e)
                    Text(clock(listener.length(e))).frame(width: 44, alignment: .leading)
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.soft).frame(maxWidth: 900)
            } else {
                Eyebrow("Nothing playing")
                Text("Pick a section in Listen, or press play to start from Episode 1.").font(.body(16)).foregroundStyle(Color.soft)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 14).background(Color.panel)
    }

    func ctrl(_ icon: String, _ tip: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 32, height: 32)
                .overlay(Circle().stroke(Color.line)).contentShape(Circle())
        }.buttonStyle(.plain).foregroundStyle(Color.ink).help(tip).disabled(listener.episode == nil)
    }
}

/// The episode's progress, one block per section; click anywhere to jump there.
struct SectionBar: View {
    @EnvironmentObject var listener: Listener
    let e: Episode
    var body: some View {
        GeometryReader { g in
            let len = max(1, listener.length(e))
            let starts = listener.sectionStarts(e)
            let x = { (t: Double) in g.size.width * CGFloat(min(1, max(0, t / len))) }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x2a2520))
                RoundedRectangle(cornerRadius: 3).fill(Color.gold.opacity(0.85)).frame(width: x(listener.time))
                ForEach(Array(starts.enumerated()), id: \.offset) { i, s in
                    if i > 0 { Rectangle().fill(Color.bg).frame(width: 2).offset(x: x(s) - 1) }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                listener.play(e, at: Double(max(0, min(1, v.location.x / g.size.width))) * len)
            })
        }.frame(height: 10).help("Click to jump")
    }
}


/// The same player bar on the trailer page: it plays the trailer recording, and its back and forward buttons go shot by shot.
struct TrailerNowPlaying: View {
    @ObservedObject var audio: TrailerAudio
    let clock: TrailerClock
    let trailer: TrailerFile

    var body: some View {
        let shot = trailer.shots.first { $0.id == audio.current }
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ctrl("backward.fill", "Previous shot") { jump(-1) }
                Button { audio.toggle() } label: {
                    Image(systemName: audio.playing ? "pause.fill" : "play.fill").font(.system(size: 18))
                        .frame(width: 46, height: 46).background(Color.gold, in: Circle()).foregroundStyle(Color.dark).contentShape(Circle())
                }.buttonStyle(.plain).help("Play or pause (Space)")
                ctrl("forward.fill", "Next shot") { jump(1) }
            }
            HStack(spacing: 6) {
                Eyebrow(Tab.trailer.rawValue)
                if let shot { Eyebrow("· \(shot.id) · \(shot.name)", color: .soft) }
            }
            Text(shot?.line ?? " ").font(.body(16)).lineLimit(1).truncationMode(.tail).multilineTextAlignment(.center).frame(maxWidth: 900)
            TrailerProgress(audio: audio, clock: clock, length: trailer.audio_seconds).frame(maxWidth: 900)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 14).background(Color.panel)
    }

    /// Moves the playhead to the start of the next or previous shot; a couple of seconds into a shot, back goes to its own start.
    func jump(_ d: Int) {
        let starts = audio.timeline.values.map(\.0).sorted()
        let now = clock.time
        if d > 0 { if let n = starts.first(where: { $0 > now + 0.05 }) { audio.seek(n) } }
        else if let i = starts.lastIndex(where: { $0 <= now + 0.05 }) { audio.seek(now - starts[i] > 2 || i == 0 ? starts[i] : starts[i - 1]) }
    }

    func ctrl(_ icon: String, _ tip: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 32, height: 32)
                .overlay(Circle().stroke(Color.line)).contentShape(Circle())
        }.buttonStyle(.plain).foregroundStyle(Color.ink).help(tip)
    }
}

/// Its progress bar, kept apart so only this redraws while the trailer plays. Click anywhere to jump there.
struct TrailerProgress: View {
    @ObservedObject var audio: TrailerAudio
    @ObservedObject var clock: TrailerClock
    let length: Double
    var body: some View {
        HStack(spacing: 12) {
            Text(fmt(clock.time)).frame(width: 44, alignment: .trailing)
            GeometryReader { g in
                let len = max(1, length)
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x2a2520))
                    RoundedRectangle(cornerRadius: 3).fill(Color.gold.opacity(0.85)).frame(width: g.size.width * CGFloat(min(1, max(0, clock.time / len))))
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in audio.seek(Double(max(0, min(1, v.location.x / g.size.width))) * len) })
            }.frame(height: 10).help("Click to jump")
            Text(fmt(length)).frame(width: 44, alignment: .leading)
        }.font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.soft)
    }
    func fmt(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
}
