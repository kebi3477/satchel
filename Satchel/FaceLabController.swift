//
//  FaceLabController.swift
//  glance
//
//  Orchestrates the Face Lab debug tab. Deliberately never touches LockMonitor, KeystrokeInjector, or
//  SecureCredentialManager for *unlocking* — that's handled separately by FaceUnlockCoordinator (off by default).
//

import Foundation
import CoreGraphics
import Observation

struct RecognitionResult: Identifiable {
    let id = UUID()
    let name: String
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest sample. A match must clear the threshold on *both* measures.
    let maxSampleSimilarity: Float
    let isStale: Bool
}

/// One manually-tagged data point for threshold calibration: "this
/// similarity score came from a genuine match" or "from an impostor."
struct CalibrationSample: Identifiable {
    let id = UUID()
    let centroidSimilarity: Float
    let isGenuine: Bool
}

@Observable
@MainActor
final class FaceLabController {
    let camera = CameraManager()
    let store = FaceEnrollmentStore.shared
    let pipeline = FaceRecognitionPipeline()

    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var currentResult: FaceRecognitionResult?

    /// Fed live, same as `FaceUnlockCoordinator`'s scan loop — this is exactly what the real unlock path would see.
    private let livenessAnalyzer = LivenessAnalyzer()
    private(set) var currentLiveness = LivenessSnapshot.empty
    /// Diagnostics behind the flat-vs-3D cue, explaining *why* it reads what it reads beyond the cue's own 0...1 level.
    private(set) var currentGeometry = GeometryLivenessResult.empty
    /// Lets the debug view show raw measurements live (not just derived cue levels), to tell a wrong threshold from
    /// a measurement that isn't moving at all.
    private(set) var lastLivenessFrame: LivenessFrame?

    /// Drives mode/tuning locally rather than reading `GlanceSettings`, so experimenting here can't change what
    /// actually unlocks the Mac. Heavy by default since the point of this tab is watching the confirm cues.
    var livenessMode: LivenessMode = .heavy
    var livenessTuning = LivenessTuning.default
    var enabledLivenessCues: Set<LivenessCue> = Set(LivenessCue.allCases)

    func isLivenessCueEnabled(_ cue: LivenessCue) -> Bool {
        enabledLivenessCues.contains(cue)
    }

    func setLivenessCue(_ cue: LivenessCue, enabled: Bool) {
        if enabled {
            enabledLivenessCues.insert(cue)
        } else {
            enabledLivenessCues.remove(cue)
        }
    }

    /// Cue firing latches for a whole scan by design, so re-testing a spoof after one's been caught needs an explicit clear.
    func resetLiveness() {
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        log("실물 확인 신호를 재설정했어요.")
    }

    var enrollName: String = ""
    /// Raw cosine similarity cutoff (-1...1); typical ArcFace verification cutoffs sit around 0.28-0.40.
    var threshold: Double = 0.6

    private(set) var recognitionResults: [RecognitionResult] = []
    private(set) var bestMatch: RecognitionResult?

    private(set) var logLines: [String] = []
    private(set) var sessionError: String?

    private var isProcessingFrame = false

    init() {
        observeFrames()
        livenessAnalyzer.modeProvider = { [weak self] in self?.livenessMode ?? .heavy }
        livenessAnalyzer.tuningProvider = { [weak self] in self?.livenessTuning ?? .default }
        livenessAnalyzer.enabledCuesProvider = { [weak self] in
            self?.enabledLivenessCues ?? Set(LivenessCue.allCases)
        }
        store.reloadIfUnlocked()
        if pipeline.usingFallbackEmbedder {
            log("ArcFace 사용 불가 (\(pipeline.fallbackReason ?? "알 수 없는 이유")) — 대신 Vision Feature Print를 사용해요.")
        } else {
            log("\(pipeline.embedder.name) 사용 중.")
        }
    }

    func start() async {
        await camera.start()
        if let error = camera.errorMessage {
            log(error)
        } else {
            log("카메라를 시작했어요.")
        }
    }

    func stop() {
        camera.stop()
        detectedFaces = []
        currentResult = nil
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        lastLivenessFrame = nil
        log("카메라를 중지했어요.")
    }

    /// Mirrors `POCController.unlockSession()` so Face Lab can unlock the session without leaving this page.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Face Lab을 사용하려면 인증하세요")
            }.value
            store.reloadIfUnlocked()
            log("세션 잠금을 해제했어요.")
        } catch {
            sessionError = error.localizedDescription
        }
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeFrames() {
        withObservationTracking {
            _ = camera.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFrames()
                await self?.processLatestFrame()
            }
        }
    }

    /// Skips frames that arrive mid-processing — an "always work on the latest frame" throttle instead of a timer.
    private func processLatestFrame() async {
        guard !isProcessingFrame, let cameraFrame = camera.currentFrame else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let pipeline = self.pipeline
        do {
            let (result, livenessFrame) = try await Task.detached(priority: .userInitiated) {
                let result = try pipeline.recognize(in: cameraFrame.image)
                let faceCrop = CameraManager.renderCrop(from: cameraFrame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: cameraFrame.image, faceCrop: faceCrop))
            }.value
            detectedFaces = [result.face]
            currentResult = result
            lastLivenessFrame = livenessFrame
            currentLiveness = livenessAnalyzer.observe(livenessFrame)
            currentGeometry = livenessAnalyzer.lastGeometry
        } catch FaceRecognitionPipelineError.noFaceDetected {
            detectedFaces = []
            currentResult = nil
        } catch {
            detectedFaces = []
            currentResult = nil
            log("감지 오류: \(error.localizedDescription)")
        }
    }

    // MARK: - Enrollment

    func captureSample() {
        guard let result = currentResult else {
            log("감지된 얼굴이 없어 샘플을 캡처할 수 없어요.")
            return
        }
        let trimmedName = enrollName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            log("샘플을 캡처하기 전에 이름을 입력하세요.")
            return
        }
        do {
            try store.addSample(
                name: trimmedName,
                embedding: result.embedding,
                embedder: pipeline.embedder,
                quality: result.quality
            )
            log("\"\(trimmedName)\" 샘플을 캡처했어요 (\(result.embedding.count)차원, \(result.alignmentTier.rawValue), 품질 \(Self.qualityLabel(result.quality))).")
        } catch {
            log("샘플을 저장할 수 없어요: \(error.localizedDescription)")
        }
    }

    func deleteIdentity(_ identity: FaceIdentity) {
        do {
            try store.delete(identity)
            log("\"\(identity.name)\"을(를) 삭제했어요.")
        } catch {
            log("삭제할 수 없어요: \(error.localizedDescription)")
        }
    }

    // MARK: - Multi-identity enrollment

    /// Counts only the red band of `FaceSample.qualityTier`, so this debug list and the Your Face tick strip always
    /// agree about what "low" means. Samples with no score count as unrated, never as low.
    func lowQualityCount(in identity: FaceIdentity) -> Int {
        identity.samples.filter { $0.qualityTier == .poor }.count
    }

    /// Face Lab and onboarding each own a separate `CameraManager` on the same device — stop ours first to avoid
    /// two live sessions with different configurations.
    func startFullOnboarding() {
        camera.stop()
        log("전체 온보딩을 시작해요.")
        OnboardingController.startFlow()
    }

    func startAddIdentity() {
        camera.stop()
        log("새 얼굴의 안내 등록을 시작해요.")
        OnboardingController.startAddIdentity()
    }

    func startRecapture(of identity: FaceIdentity) {
        camera.stop()
        log("\"\(identity.name)\"의 안내 재캡처를 시작해요.")
        OnboardingController.startRecapture(of: identity)
    }

    static func qualityLabel(_ quality: Float?) -> String {
        guard let quality else { return "—" }
        return String(format: "%.0f%%", quality * 100)
    }

    // MARK: - Recognition

    func recognize() {
        guard let result = currentResult else {
            log("감지된 얼굴이 없어 인식할 수 없어요.")
            recognitionResults = []
            bestMatch = nil
            return
        }
        guard !store.identities.isEmpty else {
            log("아직 등록된 얼굴이 없어요 — 먼저 샘플을 캡처하세요.")
            recognitionResults = []
            bestMatch = nil
            return
        }

        let embedder = pipeline.embedder
        let scored = pipeline.score(result.embedding, against: store.identities)
        recognitionResults = scored.map { s in
            RecognitionResult(
                name: s.identity.name,
                centroidSimilarity: s.centroidSimilarity,
                maxSampleSimilarity: s.maxSampleSimilarity,
                isStale: s.identity.isStale(comparedTo: embedder)
            )
        }

        let matched = pipeline.bestMatch(in: scored, threshold: Float(threshold))
        bestMatch = matched.map {
            RecognitionResult(name: $0.identity.name, centroidSimilarity: $0.centroidSimilarity, maxSampleSimilarity: $0.maxSampleSimilarity, isStale: false)
        }

        if let best = scored.first {
            let verdict = (bestMatch != nil) ? "일치" : "불일치"
            let staleNote = best.identity.isStale(comparedTo: embedder) ? " [오래됨 — 현재 모델로 다시 등록 필요]" : ""
            log("인식: 최고 = \(best.identity.name) centroid=\(String(format: "%.3f", best.centroidSimilarity)) max=\(String(format: "%.3f", best.maxSampleSimilarity)) -> \(verdict)\(staleNote)")
        }
    }

    // MARK: - Threshold calibration

    /// Tagged similarity scores collected this session — the actual data a threshold should be picked from, not guessed.
    private(set) var calibrationSamples: [CalibrationSample] = []

    /// Tags the most recent `recognize()` top score as genuine or impostor, using centroid similarity (what the
    /// threshold slider actually gates on).
    func recordCalibrationSample(isGenuine: Bool) {
        guard let top = recognitionResults.first else {
            log("기록할 결과가 없어요 — 먼저 식별을 실행하세요.")
            return
        }
        calibrationSamples.append(CalibrationSample(centroidSimilarity: top.centroidSimilarity, isGenuine: isGenuine))
        log("보정: \(isGenuine ? "본인" : "타인") 샘플을 \(String(format: "%.3f", top.centroidSimilarity))에 기록했어요.")
    }

    func clearCalibrationSamples() {
        calibrationSamples.removeAll()
    }

    /// Midpoint between the lowest genuine score and the highest impostor score. Nil until at least one of each is recorded.
    var suggestedThreshold: Float? {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return nil }
        return (minGenuine + maxImpostor) / 2
    }

    /// True if any impostor score is >= any genuine score — no single threshold perfectly separates the two groups yet.
    var calibrationDistributionsOverlap: Bool {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return false }
        return maxImpostor >= minGenuine
    }

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(timestamp)] \(message)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }
}
