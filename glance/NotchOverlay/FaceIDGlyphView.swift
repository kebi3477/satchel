//
//  FaceIDGlyphView.swift
//  glance
//
//  Vector Face ID–style glyph that replaces the bundled scan videos. Drawn with SwiftUI
//  shapes so it stays crisp at any size (the minimal notch layout renders it ~40pt, the
//  full panel ~140pt) and animates per `ScanMedia`:
//    - idle/scanning: corner brackets hold still while the face sways as if looking around
//    - success: the face dissolves, a ring draws itself, then a checkmark strokes in
//    - failure: the mouth flattens and the whole glyph shakes side to side
//

import SwiftUI

struct FaceIDGlyphView: View {
    let media: ScanMedia
    var color: Color = .white
    /// Off for static previews (e.g. the Settings thumbnail) so nothing animates.
    var animatesIdle: Bool = true

    // Success choreography
    @State private var faceVisibility: Double = 1
    @State private var ringTrim: CGFloat = 0
    @State private var checkTrim: CGFloat = 0
    // Failure choreography
    @State private var shakeOffset: CGFloat = 0
    @State private var isFrowning = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let lineWidth = max(1.5, side * 0.055)
            let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            TimelineView(.animation(paused: !(animatesIdle && media == .idle))) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                // Slow look-left / look-right, like the iPhone glyph while it searches.
                let sway = animatesIdle && media == .idle ? sin(t * 2.4) : 0

                ZStack {
                    FaceIDBrackets()
                        .stroke(color, style: stroke)
                        .opacity(faceVisibility)
                        .scaleEffect(0.85 + 0.15 * faceVisibility)

                    FaceIDFeatures(isFrowning: isFrowning)
                        .stroke(color, style: stroke)
                        .offset(x: sway * side * 0.035)
                        .rotation3DEffect(.degrees(sway * 14), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                        .opacity(faceVisibility)
                        .scaleEffect(0.7 + 0.3 * faceVisibility)
                        .animation(.smooth(duration: 0.25), value: isFrowning)

                    Circle()
                        .inset(by: side * 0.08)
                        .trim(from: 0, to: ringTrim)
                        .stroke(color, style: stroke)
                        .rotationEffect(.degrees(-90))

                    FaceIDCheckmark()
                        .trim(from: 0, to: checkTrim)
                        .stroke(color, style: stroke)
                }
                .frame(width: side, height: side)
                .offset(x: shakeOffset)
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: media) { await play(media) }
    }

    @MainActor
    private func play(_ media: ScanMedia) async {
        switch media {
        case .idle:
            withAnimation(.smooth(duration: 0.2)) {
                faceVisibility = 1
                ringTrim = 0
                checkTrim = 0
                shakeOffset = 0
                isFrowning = false
            }

        case .success:
            isFrowning = false
            withAnimation(.easeIn(duration: 0.22)) { faceVisibility = 0 }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.easeInOut(duration: 0.42)) { ringTrim = 1 }
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(.easeOut(duration: 0.3)) { checkTrim = 1 }

        case .failure:
            ringTrim = 0
            checkTrim = 0
            faceVisibility = 1
            isFrowning = true
            // Decaying side-to-side shake, the same "nope" gesture iOS uses.
            let side: CGFloat = 9
            for amplitude in [side, -side, side * 0.75, -side * 0.75, side * 0.4, -side * 0.4, 0] {
                withAnimation(.easeInOut(duration: 0.06)) { shakeOffset = amplitude }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }
}

// MARK: - Shapes (all laid out in a unit square, scaled to `rect`)

/// Four rounded "viewfinder" corners.
private struct FaceIDBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let o = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }

        let arm: CGFloat = 0.3    // how far each bracket reaches along an edge
        let radius: CGFloat = 0.16
        let inset: CGFloat = 0.04

        var path = Path()
        // (corner x, corner y, x direction toward centre, y direction toward centre)
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (inset, inset, 1, 1),
            (1 - inset, inset, -1, 1),
            (1 - inset, 1 - inset, -1, -1),
            (inset, 1 - inset, 1, -1),
        ]
        for (cx, cy, dx, dy) in corners {
            path.move(to: p(cx, cy + dy * arm))
            path.addLine(to: p(cx, cy + dy * radius))
            path.addQuadCurve(to: p(cx + dx * radius, cy), control: p(cx, cy))
            path.addLine(to: p(cx + dx * arm, cy))
        }
        return path
    }
}

/// Eyes, nose and mouth. `isFrowning` flattens the smile for the failure state.
private struct FaceIDFeatures: Shape {
    /// 0 = smile, 1 = flat; animatable so the mouth morphs instead of snapping.
    var flatness: CGFloat
    init(isFrowning: Bool) {
        self.flatness = isFrowning ? 1 : 0
    }

    var animatableData: CGFloat {
        get { flatness }
        set { flatness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let o = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }

        var path = Path()
        // Eyes
        path.move(to: p(0.34, 0.34)); path.addLine(to: p(0.34, 0.43))
        path.move(to: p(0.66, 0.34)); path.addLine(to: p(0.66, 0.43))
        // Nose: down, then a short hook left
        path.move(to: p(0.5, 0.34))
        path.addLine(to: p(0.5, 0.55))
        path.addLine(to: p(0.45, 0.55))
        // Mouth
        let mouthY: CGFloat = 0.67
        let dip = 0.09 * (1 - flatness)
        path.move(to: p(0.35, mouthY))
        path.addQuadCurve(to: p(0.65, mouthY), control: p(0.5, mouthY + dip * 2))
        return path
    }
}

private struct FaceIDCheckmark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let o = CGPoint(x: rect.midX - s / 2, y: rect.midY - s / 2)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }

        var path = Path()
        path.move(to: p(0.33, 0.52))
        path.addLine(to: p(0.45, 0.64))
        path.addLine(to: p(0.68, 0.38))
        return path
    }
}

#Preview {
    HStack(spacing: 24) {
        FaceIDGlyphView(media: .idle)
        FaceIDGlyphView(media: .success)
        FaceIDGlyphView(media: .failure)
    }
    .frame(width: 420, height: 140)
    .padding()
    .background(.black)
}
