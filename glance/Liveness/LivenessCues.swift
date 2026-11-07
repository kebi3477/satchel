//
//  LivenessCues.swift
//  glance
//
//  Liveness decision model: five independent cues, no combined score. DENY
//  cues override CONFIRM cues unconditionally; a confirm cue's absence is never a failure.
//

import CoreGraphics

/// One cue's latest reading. `confidence` 0 is always an abstention, never a reading of
/// zero — a cue that can't see anything must not be able to convict or acquit.
struct CueReading: Equatable {
    /// 0...1 strength of this cue's own evidence, in the direction that
    /// cue argues for (spoof-ness for deny cues, liveness for confirm cues).
    let level: Float
    let confidence: Float

    nonisolated static let none = CueReading(level: 0, confidence: 0)
}

enum LivenessCueRole: Equatable {
    /// Evidence of a spoof. Firing fails the scan and overrides confirmation.
    case deny
    /// Evidence of a real face. Firing passes the liveness half of the scan.
    case confirm
}

enum LivenessCue: String, CaseIterable, Hashable, Identifiable {
    case glossGlare
    case deviceDetected
    case flatVs3D
    case depthPose
    case blink

    var id: String { rawValue }

    nonisolated var title: String {
        switch self {
        case .glossGlare: return "반사광"
        case .deviceDetected: return "기기 감지"
        case .flatVs3D: return "평면 vs 입체"
        case .depthPose: return "깊이/자세"
        case .blink: return "눈 깜빡임"
        }
    }

    nonisolated var role: LivenessCueRole {
        switch self {
        case .glossGlare, .deviceDetected: return .deny
        case .flatVs3D, .depthPose, .blink: return .confirm
        }
    }

    /// One-line explanation of what firing actually means, for Face Lab.
    nonisolated var explanation: String {
        switch self {
        case .glossGlare: return "넓고 평평한 반사광이에요. 피부의 작고 흩어진 광택이 아니라 유리나 화면의 반사예요."
        case .deviceDetected: return "기기 모양의 사각형이 얼굴과 겹쳐요. 휴대폰이나 태블릿을 들고 있는 상태예요."
        case .flatVs3D: return "코 지점이 평면에서 벗어나요. 얼굴에 실제 깊이가 있어요."
        case .depthPose: return "고개를 돌리는 방향에 따라 코 위치가 달라져요. 코가 눈 평면 밖에 있으므로 평면이 아니에요."
        case .blink: return "눈 종횡비가 줄었다가 돌아왔어요. 사진은 눈을 깜빡일 수 없어요."
        }
    }
}

/// How much liveness checking runs. Both modes always run the deny cues —
/// the difference is only whether a *positive* proof of life is also
/// required before unlocking.
enum LivenessMode: String, CaseIterable, Identifiable, Sendable {
    /// Deny-only: "confirmed unless proven wrong." Never blocks a user who sits still — the default.
    case light
    /// Deny cues plus at least one confirm cue must fire. Can block a user who holds
    /// perfectly still and never blinks for the whole scan.
    case heavy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "기본"
        case .heavy: return "강력"
        }
    }

    var summary: String {
        switch self {
        case .light: return "명백한 위장만 차단해요."
        case .heavy: return "실제 얼굴이라는 증거도 요구해요."
        }
    }
}

/// Fire thresholds per cue: a cue counts a frame when its reading is confident and
/// at/above `level`, and fires once it has counted `frames` of them within the scan.
/// Seeded from real-device observation; retune from Face Lab.
struct LivenessTuning: Equatable {
    var glossLevel: Float = 0.04
    var glossFrames: Int = 3

    /// Deliberately lower than `glossLevel` — the device rectangle detector was already
    /// the one signal proven reliable in real-device testing.
    var deviceLevel: Float = 0.15
    var deviceFrames: Int = 3

    /// Not the 0.5 you might expect: real-world Vision jitter alone measures ~0.21-0.46
    /// in the self-test, so 0.5 would mean this cue essentially never fires.
    var flatVs3DLevel: Float = 0.25
    var flatVs3DFrames: Int = 2

    /// Deliberately high: this level is a remapped correlation `(r + 1) / 2`, so 0.5 is
    /// zero correlation (evidence of nothing) — 0.8 requires r >= 0.6.
    var depthPoseLevel: Float = 0.8
    var depthPoseFrames: Int = 2

    /// A blink is already a discrete dip-and-recover event (see `LivenessScoring.blinkDynamics`),
    /// not a ramping level, so one firing frame is the event itself.
    var blinkFrames: Int = 1

    /// Frames Light mode waits before auto-confirming, so deny cues get a fair chance to
    /// fire first — otherwise a first-frame match could unlock before glare/device ever ran.
    var lightModeMinimumFrames: Int = 3

    nonisolated static let `default` = LivenessTuning()

    nonisolated func level(for cue: LivenessCue) -> Float {
        switch cue {
        case .glossGlare: return glossLevel
        case .deviceDetected: return deviceLevel
        case .flatVs3D: return flatVs3DLevel
        case .depthPose: return depthPoseLevel
        // Any confident blink reading is the event; see `blinkFrames`.
        case .blink: return 0.5
        }
    }

    nonisolated func frames(for cue: LivenessCue) -> Int {
        switch cue {
        case .glossGlare: return glossFrames
        case .deviceDetected: return deviceFrames
        case .flatVs3D: return flatVs3DFrames
        case .depthPose: return depthPoseFrames
        case .blink: return blinkFrames
        }
    }
}

enum LivenessDecision: Equatable {
    /// Nothing decided yet. Not a failure — the scan should keep going.
    case pending
    /// Cue is `nil` when Light mode auto-confirmed rather than any cue firing.
    case confirmed(by: LivenessCue?)
    case denied(by: LivenessCue)

    var isConfirmed: Bool { if case .confirmed = self { return true }; return false }
    var isDenied: Bool { if case .denied = self { return true }; return false }

    /// User-facing explanation for a denial, matching the tone of the
    /// coordinator's other outcome strings.
    var denialReason: String? {
        guard case .denied(let cue) = self else { return nil }
        switch cue {
        case .glossGlare: return "화면 반사광이 감지됐어요. 디스플레이에 띄운 사진으로 보여요."
        case .deviceDetected: return "얼굴 주변에서 기기 모양의 사각형이 감지됐어요. 사진이나 화면으로 보여요."
        default: return "실물 확인에 실패했어요."
        }
    }
}

/// Running state for one cue across a scan.
struct LivenessCueState: Equatable {
    var reading: CueReading = .none
    /// Cumulative, not consecutive — forgiving of one-frame dropouts Vision produces mid-scan.
    var framesCounted: Int = 0
    var hasFired: Bool = false

    /// 0...1 progress toward firing, for Face Lab's progress bars.
    func progress(threshold: Int) -> Float {
        guard threshold > 0 else { return hasFired ? 1 : 0 }
        return min(1, Float(framesCounted) / Float(threshold))
    }
}

struct LivenessSnapshot: Equatable {
    let decision: LivenessDecision
    let mode: LivenessMode
    let cueStates: [LivenessCue: LivenessCueState]
    let frameCount: Int

    nonisolated static let empty = LivenessSnapshot(
        decision: .pending, mode: .light, cueStates: [:], frameCount: 0
    )

    func state(for cue: LivenessCue) -> LivenessCueState {
        cueStates[cue] ?? LivenessCueState()
    }
}

/// The stateful decision core, kept as a plain `struct` rather than folded
/// into `LivenessAnalyzer` so `tools/liveness_selftest.swift` can drive the
/// real firing/latching logic frame by frame with no actor or camera.
struct LivenessEvaluator {
    var mode: LivenessMode
    var tuning: LivenessTuning
    /// Face Lab can switch individual cues off to isolate one; the unlock
    /// path leaves this at "all enabled."
    var enabledCues: Set<LivenessCue>

    private(set) var states: [LivenessCue: LivenessCueState] = [:]
    private(set) var framesObserved: Int = 0

    init(
        mode: LivenessMode = .light,
        tuning: LivenessTuning = .default,
        enabledCues: Set<LivenessCue> = Set(LivenessCue.allCases)
    ) {
        self.mode = mode
        self.tuning = tuning
        self.enabledCues = enabledCues
    }

    mutating func reset() {
        states = [:]
        framesObserved = 0
    }

    /// Firing is latched: a cue that has fired stays fired for the rest of the scan.
    mutating func observe(_ readings: [LivenessCue: CueReading]) -> LivenessSnapshot {
        framesObserved += 1

        for cue in LivenessCue.allCases {
            var state = states[cue] ?? LivenessCueState()
            let reading = readings[cue] ?? .none
            state.reading = reading
            if reading.confidence > 0, reading.level >= tuning.level(for: cue) {
                state.framesCounted += 1
                if state.framesCounted >= tuning.frames(for: cue) {
                    state.hasFired = true
                }
            }
            states[cue] = state
        }

        return LivenessSnapshot(
            decision: currentDecision(), mode: mode, cueStates: states, frameCount: framesObserved
        )
    }

    /// Deny is evaluated first and is unconditional — it overrides any confirmation already reached.
    private func currentDecision() -> LivenessDecision {
        for cue in LivenessCue.allCases
        where cue.role == .deny && enabledCues.contains(cue) && (states[cue]?.hasFired ?? false) {
            return .denied(by: cue)
        }

        if mode == .light {
            return framesObserved >= tuning.lightModeMinimumFrames ? .confirmed(by: nil) : .pending
        }

        for cue in LivenessCue.allCases
        where cue.role == .confirm && enabledCues.contains(cue) && (states[cue]?.hasFired ?? false) {
            return .confirmed(by: cue)
        }

        return .pending
    }
}

/// Turns a rolling window into this frame's reading for every cue. Deny cues read only
/// the latest frame (per-frame appearance); confirm cues read the whole window (cross-frame motion).
nonisolated enum LivenessCues {
    nonisolated static func readings(
        window: [LivenessFrame], geometry: GeometryLivenessResult
    ) -> [LivenessCue: CueReading] {
        [
            .glossGlare: glossGlare(window.last),
            .deviceDetected: deviceDetected(window.last),
            .flatVs3D: geometry.planarReading,
            .depthPose: LivenessScoring.poseDepthConsistency(window),
            .blink: LivenessScoring.blinkDynamics(window),
        ]
    }

    /// Skin gives many small scattered specular points; glass gives one big
    /// flat blob. `specularFraction` alone would fire on a bright forehead,
    /// so it's gated by how concentrated that glare is.
    nonisolated static func glossGlare(_ frame: LivenessFrame?) -> CueReading {
        guard let glare = frame?.glare else { return .none }
        let fractionScore = ramp(glare.specularFraction, floor: 0.01, ceiling: 0.08)
        let clusterFactor = ramp(glare.specularClusterRatio, floor: 0.3, ceiling: 1.0)
        let level = fractionScore * (0.3 + 0.7 * clusterFactor)
        // Below ~50 native px of face there isn't enough detail to tell a
        // glare blob from a bright patch; ramps to full trust by ~130px.
        let confidence = ramp(Float(glare.cropPixelWidth), floor: 50, ceiling: 130)
        return CueReading(level: level, confidence: confidence)
    }

    /// Raw overlap fraction from `DeviceBezelDetector`, used directly rather than re-scaled.
    nonisolated static func deviceDetected(_ frame: LivenessFrame?) -> CueReading {
        guard let overlap = frame?.deviceOverlapFraction else { return .none }
        return CueReading(level: Float(min(max(overlap, 0), 1)), confidence: 1)
    }

    nonisolated static func ramp(_ value: Float, floor: Float, ceiling: Float) -> Float {
        min(max((value - floor) / max(ceiling - floor, 0.0001), 0), 1)
    }
}
