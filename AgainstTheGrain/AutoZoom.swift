import SwiftUI
import Vision
import FoundationModels

/// On-device auto-zoom: finds where each beat of a scene should zoom in a dropped picture, and says what is missing.
/// On macOS 27 the on-device model looks at the picture itself. On macOS 26, Apple's Vision finds and names the
/// regions in the picture and the on-device model matches each beat's "Zoom on" sentence to one of them.
/// Without Apple Intelligence it falls back to matching words, then to the plan's zoom.
struct AutoZoomResult: Codable, Equatable {
    var beat: Int
    var frame: BeatFrame?
    var found: Bool
    var note: String          // what was matched, or what is missing
}

enum AutoZoom {
    /// A named region of the picture, in fractions of the picture with the origin at the top left.
    struct Region { var rect: CGRect; var labels: [String] }

    static func run(image cg: CGImage, beats: [(n: Int, look: String, plan: BeatFrame?)]) async -> [AutoZoomResult] {
        if #available(macOS 27, *), SystemLanguageModel.default.availability == .available {
            if let r = try? await lookAtPicture(cg, beats: beats) { return r }
        }
        let regions = findRegions(cg)
        if #available(macOS 26, *), SystemLanguageModel.default.availability == .available {
            if let r = try? await matchRegions(regions, beats: beats) { return r }
        }
        return beats.map { b in matchWords(regions, b) }
    }

    // MARK: Vision: the regions in the picture and what each looks like

    static func findRegions(_ cg: CGImage) -> [Region] {
        let handler = VNImageRequestHandler(cgImage: cg)
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        let people = VNDetectHumanRectanglesRequest(); people.upperBodyOnly = false
        try? handler.perform([objects, people])
        var boxes = (objects.results?.first?.salientObjects ?? []).map(\.boundingBox)
        boxes += (people.results ?? []).map(\.boundingBox)
        // a 3 × 3 grid as well, so every part of the picture can be picked
        for r in 0..<3 { for c in 0..<3 { boxes.append(CGRect(x: Double(c) / 3, y: Double(r) / 3, width: 1 / 3, height: 1 / 3)) } }
        return boxes.map { vb in
            // Vision's origin is bottom left; ours is top left
            let rect = CGRect(x: vb.minX, y: 1 - vb.maxY, width: vb.width, height: vb.height)
            return Region(rect: rect, labels: classify(cg, rect))
        }
    }

    static func classify(_ cg: CGImage, _ rect: CGRect) -> [String] {
        let px = CGRect(x: rect.minX * Double(cg.width), y: rect.minY * Double(cg.height),
                        width: rect.width * Double(cg.width), height: rect.height * Double(cg.height)).integral
        guard px.width > 8, px.height > 8, let crop = cg.cropping(to: px) else { return [] }
        let req = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: crop).perform([req])
        return (req.results ?? []).filter { $0.confidence > 0.08 }.prefix(6).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }

    static func describe(_ r: Region) -> String {
        let cx = r.rect.midX, cy = r.rect.midY
        let across = cx < 0.34 ? "left" : cx > 0.66 ? "right" : "middle"
        let down = cy < 0.34 ? "top" : cy > 0.66 ? "bottom" : "centre"
        let size = max(r.rect.width, r.rect.height) > 0.5 ? "large" : max(r.rect.width, r.rect.height) > 0.25 ? "medium" : "small"
        return "\(down) \(across), \(size), looks like: \(r.labels.isEmpty ? "unclear" : r.labels.joined(separator: ", "))"
    }

    /// A zoom that fills about 80% of the frame with the region.
    static func frame(for rect: CGRect) -> BeatFrame {
        BeatFrame(scale: min(3.5, max(1, 0.8 / max(rect.width, rect.height, 0.01))), x: rect.midX, y: rect.midY).clamped()
    }

    // MARK: macOS 26: the on-device model matches each sentence to a region

    @available(macOS 26, *)
    @Generable struct RegionPick {
        @Guide(description: "The number of the region that best shows what the sentence describes, or -1 if no region shows it")
        var region: Int
        @Guide(description: "true only if the picture clearly contains what the sentence needs")
        var found: Bool
        @Guide(description: "If found is false, a few words on what is missing from the picture; otherwise what was matched")
        var note: String
    }

    @available(macOS 26, *)
    static func matchRegions(_ regions: [Region], beats: [(n: Int, look: String, plan: BeatFrame?)]) async throws -> [AutoZoomResult] {
        let list = regions.enumerated().map { "\($0.offset): \(describe($0.element))" }.joined(separator: "\n")
        var out: [AutoZoomResult] = []
        for b in beats {
            let session = LanguageModelSession(instructions: """
                You place the camera for one beat of an illustrated story. A drawing has been split into numbered regions; \
                each has a position, a size and what it looks like. Pick the region that best shows what the sentence describes. \
                If nothing in the list could show it, say so and name what is missing.
                """)
            let pick = try await session.respond(to: "Regions:\n\(list)\n\nThe beat should show: \(b.look)", generating: RegionPick.self).content
            if pick.found, regions.indices.contains(pick.region) {
                out.append(AutoZoomResult(beat: b.n, frame: frame(for: regions[pick.region].rect), found: true, note: pick.note))
            } else {
                out.append(AutoZoomResult(beat: b.n, frame: nil, found: false, note: pick.note.isEmpty ? "Not found in the picture" : pick.note))
            }
        }
        return out
    }

    // MARK: macOS 27: the on-device model looks at the picture

    @available(macOS 27, *)
    @Generable struct BoxPick {
        @Guide(description: "true only if the picture clearly shows what the sentence describes")
        var found: Bool
        @Guide(description: "Centre of the area to show, across the picture, from 0 (left edge) to 1 (right edge)")
        var x: Double
        @Guide(description: "Centre of the area to show, down the picture, from 0 (top edge) to 1 (bottom edge)")
        var y: Double
        @Guide(description: "Width of the area to show, as a fraction of the picture's width, from 0.1 to 1")
        var size: Double
        @Guide(description: "If found is false, what is missing from the picture; otherwise what is in the area")
        var note: String
    }

    @available(macOS 27, *)
    static func lookAtPicture(_ cg: CGImage, beats: [(n: Int, look: String, plan: BeatFrame?)]) async throws -> [AutoZoomResult] {
        var out: [AutoZoomResult] = []
        for b in beats {
            let session = LanguageModelSession(instructions: """
                You place the camera for one beat of an illustrated story. Look at the drawing and find the area that shows \
                what the sentence describes. If the drawing doesn't contain it, say what is missing.
                """)
            let pick = try await session.respond(generating: BoxPick.self) {
                Attachment(cg).label("the drawing")
                "The beat should show: \(b.look)"
            }.content
            if pick.found {
                let s = min(1, max(0.1, pick.size))
                out.append(AutoZoomResult(beat: b.n, frame: BeatFrame(scale: min(3.5, max(1, 1 / s)), x: pick.x, y: pick.y).clamped(), found: true, note: pick.note))
            } else {
                out.append(AutoZoomResult(beat: b.n, frame: nil, found: false, note: pick.note))
            }
        }
        return out
    }

    // MARK: no Apple Intelligence: match words, else keep the plan

    static func matchWords(_ regions: [Region], _ b: (n: Int, look: String, plan: BeatFrame?)) -> AutoZoomResult {
        let words = Set(b.look.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
        let scored = regions.map { r -> (Region, Int) in
            let hits = r.labels.filter { label in words.contains { w in label.lowercased().contains(w) } }.count
            return (r, hits)
        }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 {
            return AutoZoomResult(beat: b.n, frame: frame(for: best.0.rect), found: true, note: "Matched \(best.0.labels.prefix(2).joined(separator: ", "))")
        }
        return AutoZoomResult(beat: b.n, frame: b.plan, found: false, note: b.plan == nil ? "Couldn't find it in the picture" : "Couldn't find it; kept the planned zoom")
    }
}
