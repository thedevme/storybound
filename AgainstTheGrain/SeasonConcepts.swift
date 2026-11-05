import SwiftUI
import AppKit

// MARK: - Three ideas for the Season page, each showing beats a different way. Only the off-screen check draws these.

extension Color {
    static let cBG = Color(hex: 0x071126), cPanel = Color(hex: 0x0c1a38), cCard = Color(hex: 0x102247), cLine = Color(hex: 0x24406f)
    static let cBlue = Color(hex: 0x1e9bff), cGreen = Color(hex: 0x27d980), cAmber = Color(hex: 0xf0a63a), cGray = Color(hex: 0x4a5a78)
    static let cInk = Color(hex: 0xf2f6ff), cSoft = Color(hex: 0xa6b5d2)
}

func beatColor(_ s: ArtStatus) -> Color {
    switch s { case .approved: return .cGreen; case .review: return .cBlue; case .needsPainting: return .cAmber; case .needsArtwork: return .cGray }
}
enum ConceptEpState: String { case complete = "Complete", progress = "In Progress", planned = "Planned"
    var color: Color { switch self { case .complete: return .cGreen; case .progress: return .cBlue; case .planned: return .cGray } }
}

struct EpFacts {
    let e: Episode; let statuses: [ArtStatus]
    var approved: Int { statuses.filter { $0 == .approved }.count }
    var review: Int { statuses.filter { $0 == .review }.count }
    var painting: Int { statuses.filter { $0 == .needsPainting }.count }
    var artwork: Int { statuses.filter { $0 == .needsArtwork }.count }
    var withArt: Int { approved + review }
    var state: ConceptEpState { !statuses.isEmpty && approved == statuses.count ? .complete : withArt > 0 ? .progress : .planned }
    var share: Double { statuses.isEmpty ? 0 : Double(approved) / Double(statuses.count) }
}

struct SeasonConceptPage: View {
    @EnvironmentObject var store: Store
    let season: Season; let variant: Int
    private var facts: [EpFacts] { season.eps.map { e in EpFacts(e: e, statuses: e.beats.map { store.artStatus(e, $0) }) } }
    private var titles: [String] { ["", "A · Beat filmstrips", "B · Season beat map", "C · Beat rings"] }
    var body: some View {
        let f = facts
        HStack(spacing: 0) {
            BenchSidebar().frame(width: 230).frame(maxHeight: .infinity, alignment: .top).background(Color.cPanel)
            VStack(alignment: .leading, spacing: 14) {
                hero
                stats(f)
                progress(f)
                HStack {
                    Image(systemName: "square.grid.2x2.fill").foregroundStyle(Color.cBlue)
                    Text("Episodes").font(.system(size: 18, weight: .semibold)); Text("(\(f.count))").font(.system(size: 18)).foregroundStyle(Color.cSoft)
                    Spacer(); legend
                }
                switch variant {
                case 1: LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) { ForEach(f, id: \.e.n) { filmCard($0) } }
                case 2: beatMap(f)
                case 3: LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12) { ForEach(f, id: \.e.n) { ringCard($0) } }
                case 4: VStack(spacing: 8) { ForEach(f, id: \.e.n) { timelineRow($0) } }
                case 5: VStack(spacing: 10) { ForEach(f, id: \.e.n) { sceneRow($0) } }
                default: LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) { ForEach(f, id: \.e.n) { posterCard($0) } }
                }
                continueBar(f)
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color.cBG).foregroundStyle(Color.cInk)
    }

    // MARK: shared parts from the mockup
    func file(_ path: String) -> Image? {
        NSImage(contentsOf: URL(fileURLWithPath: NSHomeDirectory() + "/Kitchen/" + path)).map { Image(nsImage: $0) }
    }
    var heroImage: Image? { file("trailer/t15-color.png") }
    var hero: some View {
        ZStack(alignment: .leading) {
            Color.cPanel
            Color.clear.overlay(alignment: .trailing) {
                heroImage?.resizable().scaledToFill().frame(width: 760, height: 210, alignment: .top).clipped()
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing))
            }.clipped()
                        VStack(alignment: .leading, spacing: 8) {
                Text("ORIGINAL SERIES").font(.system(size: 11, weight: .semibold)).kerning(1.5).foregroundStyle(Color.cSoft)
                Text("Season 1").font(.system(size: 36, weight: .bold))
                Text("Against the Grain").font(.system(size: 18, weight: .medium)).italic()
                Text("From the walkout to a card face down on the counter").font(.system(size: 13)).foregroundStyle(Color.cSoft)
                HStack(spacing: 10) {
                    Label("Resume Season", systemImage: "play.fill").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).frame(height: 34).background(Color.cBlue, in: Capsule())
                    Label("Listen", systemImage: "headphones").font(.system(size: 13, weight: .medium)).padding(.horizontal, 16).frame(height: 34).overlay(Capsule().stroke(Color.cLine))
                }.padding(.top, 4)
            }.padding(22)
        }
        .overlay(alignment: .trailing) {
            file("ART/Logos/Against the Grain - Season 1 Logo.png")?.resizable().scaledToFit().frame(width: 110).padding(16)
        }
        .frame(height: 210).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    func stats(_ f: [EpFacts]) -> some View {
        let words = season.eps.reduce(0) { $0 + $1.words }, beats = season.eps.reduce(0) { $0 + $1.beats.count }
        let items: [(String, String, String)] = [
            ("play.rectangle.fill", "\(season.eps.count)", "Episodes"), ("square.stack.3d.up.fill", "\(beats)", "Beats"), ("doc.text.fill", words.formatted(), "Words"),
            ("clock.fill", "\(words / 150) min", "Voice"), ("photo.fill", "\(season.eps.filter { !$0.made }.reduce(0) { $0 + $1.gptCount })", "Images to make"),
            ("person.2.fill", "\(season.cast.filter { $0.status == "Make" }.count)", "Characters"), ("photo.badge.plus.fill", "\(store.state.images.count)", "Images added")]
        return HStack(spacing: 8) {
            ForEach(items, id: \.2) { i in
                HStack(spacing: 9) {
                    Image(systemName: i.0).font(.system(size: 17)).foregroundStyle(Color.cBlue)
                    VStack(alignment: .leading, spacing: 1) { Text(i.1).font(.system(size: 15, weight: .semibold)); Text(i.2).font(.system(size: 10)).foregroundStyle(Color.cSoft).lineLimit(1) }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 10).frame(height: 56).frame(maxWidth: .infinity).background(Color.cCard, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }
    func progress(_ f: [EpFacts]) -> some View {
        let total = f.reduce(0) { $0 + $1.statuses.count }, approved = f.reduce(0) { $0 + $1.approved }, review = f.reduce(0) { $0 + $1.review }
        let share = total == 0 ? 0 : Double(approved) / Double(total), reviewShare = total == 0 ? 0 : Double(review) / Double(total)
        let c = f.filter { $0.state == .complete }.count, p = f.filter { $0.state == .progress }.count, n = f.filter { $0.state == .planned }.count
        return HStack(spacing: 26) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Season Progress", systemImage: "chart.bar.fill").font(.system(size: 15, weight: .semibold))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.cLine.opacity(0.6))
                        Capsule().fill(Color.cBlue).frame(width: max(6, g.size.width * (share + reviewShare)))
                        Capsule().fill(Color.cGreen).frame(width: max(6, g.size.width * share))
                    }
                }.frame(height: 14)
                HStack(spacing: 16) { dot(.cGreen, "\(approved) approved"); dot(.cBlue, "\(review) to review"); dot(.cGray, "\(total - approved - review) without art") }
            }
            VStack(spacing: 2) { Text("\(Int((share * 100).rounded()))%").font(.system(size: 28, weight: .semibold)); Text("\(approved) of \(total) beats").font(.system(size: 11)).foregroundStyle(Color.cSoft) }
            Rectangle().fill(Color.cLine).frame(width: 1, height: 70)
            VStack(alignment: .leading, spacing: 6) { countRow(.cGreen, "Complete", c); countRow(.cBlue, "In Progress", p); countRow(.cGray, "Planned", n) }.frame(width: 150)
        }.padding(16).background(Color.cCard, in: RoundedRectangle(cornerRadius: 12))
    }
    func dot(_ c: Color, _ t: String) -> some View { HStack(spacing: 6) { Circle().fill(c).frame(width: 9, height: 9); Text(t).font(.system(size: 11)).foregroundStyle(Color.cSoft) } }
    func countRow(_ c: Color, _ t: String, _ n: Int) -> some View { HStack { Circle().fill(c).frame(width: 10, height: 10); Text(t).font(.system(size: 12)); Spacer(); Text("\(n)").font(.system(size: 13, weight: .semibold)) } }
    var legend: some View { HStack(spacing: 12) { dot(.cGreen, "Approved"); dot(.cBlue, "Needs review"); dot(.cAmber, "Needs painting"); dot(.cGray, "Needs artwork") } }
    func continueBar(_ f: [EpFacts]) -> some View {
        let c = f.filter { $0.state == .complete }.count
        return HStack(spacing: 14) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 26)).foregroundStyle(Color.cBlue)
            VStack(alignment: .leading, spacing: 2) { Text("Continue building").font(.system(size: 14, weight: .semibold)); Text("You've completed \(c) of \(f.count) episodes in Season 1.").font(.system(size: 12)).foregroundStyle(Color.cSoft) }
            Spacer()
            Label("New episode", systemImage: "plus").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).frame(height: 36).background(Color.cBlue, in: Capsule())
        }.padding(14).background(Color.cCard, in: RoundedRectangle(cornerRadius: 12))
    }
    func badge(_ s: ConceptEpState) -> some View { Text(s.rawValue).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 9).frame(height: 20).background(s.color, in: Capsule()).foregroundStyle(s == .complete ? Color.black : .white) }
    func meta(_ e: Episode) -> some View {
        HStack(spacing: 10) { Label("\(e.minutes) min", systemImage: "clock"); Label("\(e.words.formatted()) words", systemImage: "doc.text"); Label("\(e.beats.count) beats", systemImage: "square.stack.3d.up") }
            .font(.system(size: 10)).foregroundStyle(Color.cSoft).labelStyle(.titleAndIcon)
    }
    /// The first beat in the episode with a picture.
    func cover(_ e: Episode) -> Image? {
        // from a little way into the episode, so a cover is a scene rather than an opening title
        for b in e.beats.dropFirst(e.beats.count / 5) where b.kind == "gpt" || b.kind == "done" { if store.stillOf(e, b) == nil, let i = store.picture(e, b) { return i } }
        for b in e.beats { if let i = store.picture(e, b) { return i } }
        return nil
    }

    // MARK: A: every card is the episode's beats as a filmstrip of its real pictures
    func filmCard(_ f: EpFacts) -> some View {
        let e = f.e, count = 14
        let picks = (0..<count).compactMap { i -> Beat? in e.beats.isEmpty ? nil : e.beats[min(e.beats.count - 1, i * e.beats.count / count)] }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(String(format: "%02d", e.number)).font(.system(size: 24, weight: .bold))
                VStack(alignment: .leading, spacing: 2) { Text(e.title).font(.system(size: 15, weight: .semibold)); Text(e.logline).font(.system(size: 11)).foregroundStyle(Color.cSoft).lineLimit(2, reservesSpace: true) }
                Spacer(); badge(f.state)
            }
            HStack(spacing: 2) {
                ForEach(picks, id: \.n) { b in
                    ZStack(alignment: .bottom) {
                        Color.cPanel.overlay {
                            if let img = store.picture(e, b) { img.resizable().scaledToFill().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped() }
                            else { Text("\(b.n)").font(.system(size: 9)).foregroundStyle(Color.cSoft) }
                        }.clipped()
                        Rectangle().fill(beatColor(store.artStatus(e, b))).frame(height: 3)
                    }.frame(minWidth: 0, maxWidth: .infinity).frame(height: 44).clipped()
                }
            }.clipShape(RoundedRectangle(cornerRadius: 5))
            HStack(spacing: 1) { ForEach(Array(f.statuses.enumerated()), id: \.offset) { _, s in Rectangle().fill(beatColor(s)).frame(maxWidth: .infinity).frame(height: 5) } }.clipShape(Capsule())
            HStack { meta(e); Spacer(); Text("\(f.approved)/\(f.statuses.count) approved").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.cSoft) }
        }.padding(11).background(Color.cCard, in: RoundedRectangle(cornerRadius: 11))
    }

    // MARK: B: the whole season on one map: a row per episode, a square per beat
    func beatMap(_ f: [EpFacts]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(f, id: \.e.n) { x in
                let e = x.e, secs = e.sections.isEmpty ? [Section(span: "1-\(e.beats.count)", title: "", opts: [])] : e.sections
                HStack(spacing: 10) {
                    ZStack { Color.cPanel; cover(e)?.resizable().scaledToFill() }.frame(width: 74, height: 42).clipShape(RoundedRectangle(cornerRadius: 5))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(format: "%02d  ", e.number) + e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text("\(e.minutes) min · \(e.beats.count) beats").font(.system(size: 10)).foregroundStyle(Color.cSoft)
                    }.frame(width: 138, alignment: .leading)
                    // beats in order, with a gap between the episode's scenes
                    HStack(spacing: 4) {
                        ForEach(Array(secs.enumerated()), id: \.offset) { _, s in
                            HStack(spacing: 1) {
                                ForEach(e.beats.filter { s.range.contains($0.n) }) { b in
                                    RoundedRectangle(cornerRadius: 1.5).fill(beatColor(store.artStatus(e, b))).frame(width: 7, height: 30).help(b.text)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    Text("\(Int((x.share * 100).rounded()))%").font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 40, alignment: .trailing)
                    badge(x.state).frame(width: 78)
                }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.cCard, in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    // MARK: C: each episode's beats go around a ring, one tick per beat, clockwise from the top
    func ringCard(_ f: EpFacts) -> some View {
        let e = f.e
        return HStack(spacing: 14) {
            ZStack {
                ForEach(Array(f.statuses.enumerated()), id: \.offset) { i, s in
                    Capsule().fill(beatColor(s)).frame(width: 3, height: 12).offset(y: -47).rotationEffect(.degrees(Double(i) / Double(max(1, f.statuses.count)) * 360))
                }
                VStack(spacing: 0) { Text(String(format: "%02d", e.number)).font(.system(size: 22, weight: .bold)); Text("\(Int((f.share * 100).rounded()))%").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.cSoft) }
            }.frame(width: 108, height: 108)
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(e.title).font(.system(size: 15, weight: .semibold)); Spacer(); badge(f.state) }
                Text(e.logline).font(.system(size: 11)).foregroundStyle(Color.cSoft).lineLimit(3, reservesSpace: true)
                HStack(spacing: 10) { dot(.cGreen, "\(f.approved)"); dot(.cBlue, "\(f.review)"); dot(.cAmber, "\(f.painting)"); dot(.cGray, "\(f.artwork)") }
                meta(e)
            }
            ZStack { Color.cPanel; cover(e)?.resizable().scaledToFill() }.frame(width: 120, height: 108).clipShape(RoundedRectangle(cornerRadius: 8))
        }.padding(11).background(Color.cCard, in: RoundedRectangle(cornerRadius: 11))
    }

    func sections(_ e: Episode) -> [Section] { e.sections.isEmpty ? [Section(span: "1-\(e.beats.count)", title: "", opts: [])] : e.sections }

    // MARK: D: the episode as it plays: each block's width is how long that beat is on screen, with the scene names above
    func timelineRow(_ f: EpFacts) -> some View {
        let e = f.e, times = store.beatTimes(e, duration: store.estimatedLength(e)), total = max(1, times.last?.1 ?? 1), secs = sections(e)
        let at = Dictionary(uniqueKeysWithValues: zip(e.beats.map(\.n), times))
        // every row is drawn to the longest episode's scale, so a longer episode is a longer bar
        let longest = season.eps.map { Double($0.words) }.max() ?? 1, scale = Double(e.words) / longest
        return HStack(alignment: .center, spacing: 10) {
            ZStack { Color.cPanel; cover(e)?.resizable().scaledToFill() }.frame(width: 74, height: 48).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%02d  ", e.number) + e.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text("\(e.minutes) min · \(e.beats.count) beats").font(.system(size: 10)).foregroundStyle(Color.cSoft)
            }.frame(width: 130, alignment: .leading)
            GeometryReader { g in
                let w = g.size.width * scale
                VStack(alignment: .leading, spacing: 3) {
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(secs.enumerated()), id: \.offset) { _, sec in
                            if let first = e.beats.first(where: { sec.range.contains($0.n) }), let t = at[first.n] {
                                Text(sec.title).font(.system(size: 9)).foregroundStyle(Color.cSoft).lineLimit(1)
                                    .frame(width: max(0, sceneWidth(e, sec, at) / total * w - 3), alignment: .leading).offset(x: t.0 / total * w)
                            }
                        }
                    }.frame(height: 12)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(e.beats.enumerated()), id: \.element.id) { i, b in
                            let t = times[i]
                            Rectangle().fill(beatColor(f.statuses[i])).frame(width: max(1, (t.1 - t.0) / total * w - 1), height: 26).offset(x: t.0 / total * w)
                        }
                    }.frame(width: w, height: 26, alignment: .topLeading).clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }.frame(height: 42)
            Text("\(Int((f.share * 100).rounded()))%").font(.system(size: 13, weight: .semibold).monospacedDigit()).frame(width: 38, alignment: .trailing)
            badge(f.state).frame(width: 78)
        }.padding(.horizontal, 10).padding(.vertical, 6).background(Color.cCard, in: RoundedRectangle(cornerRadius: 9))
    }
    func sceneWidth(_ e: Episode, _ sec: Section, _ at: [Int: (Double, Double)]) -> Double {
        let rows = e.beats.filter { sec.range.contains($0.n) }.compactMap { at[$0.n] }
        return (rows.last?.1 ?? 0) - (rows.first?.0 ?? 0)
    }

    // MARK: E: beats grouped into the episode's scenes: a tile per scene with its picture and its beats
    func sceneRow(_ f: EpFacts) -> some View {
        let e = f.e
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(String(format: "%02d", e.number)).font(.system(size: 20, weight: .bold))
                Text(e.title).font(.system(size: 14, weight: .semibold))
                meta(e)
                Spacer(); Text("\(sections(e).count) scenes").font(.system(size: 10)).foregroundStyle(Color.cSoft); badge(f.state)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), alignment: .leading, spacing: 6) {
                ForEach(Array(sections(e).enumerated()), id: \.offset) { _, sec in
                    let beats = e.beats.filter { sec.range.contains($0.n) }
                    VStack(alignment: .leading, spacing: 4) {
                        Color.cPanel.overlay {
                            if let img = beats.lazy.compactMap({ store.picture(e, $0) }).first { img.resizable().scaledToFill().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped() }
                        }.frame(height: 56).clipShape(RoundedRectangle(cornerRadius: 5))
                        Text(sec.title.isEmpty ? "Scene" : sec.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        HStack(spacing: 1) { ForEach(beats) { b in Rectangle().fill(beatColor(store.artStatus(e, b))).frame(minWidth: 0, maxWidth: .infinity).frame(height: 7) } }.clipShape(RoundedRectangle(cornerRadius: 2))
                        Text("\(beats.count) beats").font(.system(size: 9)).foregroundStyle(Color.cSoft)
                    }.padding(5).background(Color.cPanel.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
                }
            }
        }.padding(11).background(Color.cCard, in: RoundedRectangle(cornerRadius: 11))
    }

    // MARK: F: picture cards like the mockup, with a block of dots on the art: one dot per beat, reading left to right
    func posterCard(_ f: EpFacts) -> some View {
        let e = f.e, columns = Array(repeating: GridItem(.fixed(7), spacing: 3), count: 14)
        return ZStack(alignment: .topLeading) {
            Color.cPanel.overlay { cover(e)?.resizable().scaledToFill().frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity).clipped() }.clipped()
            LinearGradient(colors: [Color.cBG.opacity(0.96), Color.cBG.opacity(0.7), Color.cBG.opacity(0.1)], startPoint: .leading, endPoint: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%02d", e.number)).font(.system(size: 24, weight: .bold))
                Text(e.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(e.logline).font(.system(size: 10)).foregroundStyle(Color.cSoft).lineLimit(2, reservesSpace: true).frame(maxWidth: 190, alignment: .leading)
                Spacer(minLength: 2)
                HStack(spacing: 10) { Label("\(e.minutes) min", systemImage: "clock"); Label("\(e.beats.count) beats", systemImage: "square.stack.3d.up") }
                    .font(.system(size: 10)).foregroundStyle(Color.cSoft)
            }.padding(11)
            VStack(alignment: .trailing, spacing: 6) {
                badge(f.state)
                Spacer(minLength: 0)
                LazyVGrid(columns: columns, spacing: 3) {
                    ForEach(Array(f.statuses.enumerated()), id: \.offset) { _, s in Circle().fill(beatColor(s)).frame(width: 7, height: 7) }
                }.frame(width: 137).padding(6).background(Color.cBG.opacity(0.72), in: RoundedRectangle(cornerRadius: 7))
            }.padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }.frame(height: 186).clipShape(RoundedRectangle(cornerRadius: 11))
    }
}
