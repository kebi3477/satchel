//
//  FaceLabView.swift
//  glance
//
//  Debug console: camera preview, face detection + alignment, enrollment,
//  and recognition — all in one tab, independent of the credential/unlock
//  POC in the other tab.
//

import SwiftUI
import Charts

struct FaceLabView: View {
    /// Retained only while the hidden debug tab is visible.
    @Bindable var controller: FaceLabController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Face Lab — 온디바이스 얼굴 인식 (디버그)")
                        .font(.headline)
                    Spacer()
                    Button("미리보기 ✓") {
                        NotchOverlayController.shared.present()
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            NotchOverlayController.shared.finish(success: true)
                        }
                    }
                    Button("미리보기 ✗") {
                        NotchOverlayController.shared.present(onRetry: {
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                NotchOverlayController.shared.finish(success: false)
                            }
                        })
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            NotchOverlayController.shared.finish(success: false)
                        }
                    }
                    Button("온보딩 시작") {
                        controller.startFullOnboarding()
                    }
                    .disabled(enrollmentFlowIsRunning)
                }

                modelStatusSection
                sessionLockSection
                previewSection
                detectionSection
                livenessSection
                enrollSection
                identitiesSection
                recognizeSection
                calibrationSection
                logSection
            }
            .padding(20)
        }
        .onDisappear {
            controller.stop()
        }
        // Guided enrollment runs in the notch, outside this view hierarchy, so nothing else prompts a re-read once
        // it closes. Same trick YourFaceSettingsPage uses.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            controller.store.reloadIfUnlocked()
        }
    }

    /// True while the notch (a single shared panel) is already hosting an onboarding flow.
    private var enrollmentFlowIsRunning: Bool {
        NotchOverlayController.shared.phase == .onboarding
    }

    // MARK: - Which embedder is active

    private var modelStatusSection: some View {
        HStack {
            Circle()
                .fill(controller.pipeline.usingFallbackEmbedder ? .orange : .green)
                .frame(width: 8, height: 8)
            Text("임베더: \(controller.pipeline.embedder.name)")
                .font(.caption)
            if controller.pipeline.usingFallbackEmbedder {
                Text("(ArcFace 사용 불가 — 로그 참고)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    // MARK: - Session lock (face data is encrypted under the session key)

    private var sessionLockSection: some View {
        Group {
            if controller.store.isLocked {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("세션 잠김 — 등록된 얼굴이 암호화되어 있어 아직 읽거나 저장할 수 없어요.")
                        .font(.caption)
                    Spacer()
                    Button("잠금 해제") {
                        Task { await controller.unlockSession() }
                    }
                }
                if let error = controller.sessionError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        GroupBox("카메라 미리보기") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(controller.camera.isRunning ? .green : .gray)
                        .frame(width: 10, height: 10)
                    Text(controller.camera.isRunning ? "실행 중" : "중지됨")
                    Spacer()
                    Button(controller.camera.isRunning ? "중지" : "시작") {
                        if controller.camera.isRunning {
                            controller.stop()
                        } else {
                            Task { await controller.start() }
                        }
                    }
                }

                if let error = controller.camera.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                CameraPreviewView(session: controller.camera.session, faces: controller.detectedFaces)
                    .frame(height: 300)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Detection + alignment + embedding

    private var detectionSection: some View {
        GroupBox("감지") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("감지된 얼굴: \(controller.detectedFaces.count)")
                    if let quality = controller.currentResult?.quality {
                        Text("캡처 품질: \(String(format: "%.0f%%", quality * 100))")
                    } else {
                        Text("캡처 품질: —")
                            .foregroundStyle(.secondary)
                    }
                    if let result = controller.currentResult {
                        Text("정렬: \(result.alignmentTier.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("임베딩: 숫자 \(result.embedding.count)개")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Calibration aid for onboarding's pose gating (see OnboardingController's poseMatches).
                        Text("Yaw: \(yawPitchString(result.face.yaw))  Pitch: \(yawPitchString(result.face.pitch))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Text("정렬된 입력").font(.caption).foregroundStyle(.secondary)
                    if let aligned = controller.currentResult?.alignedImage {
                        Image(aligned, scale: 1, orientation: .up, label: Text("정렬된 얼굴"))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 96, height: 96)
                            .overlay(Text("얼굴 없음").font(.caption2).foregroundStyle(.secondary))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Liveness

    /// All five cues, split by role (deny vs. confirm) rather than which checker they live in.
    private var livenessSection: some View {
        GroupBox("실물 확인") {
            VStack(alignment: .leading, spacing: 12) {
                decisionStrip

                Picker("모드", selection: $controller.livenessMode) {
                    ForEach(LivenessMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Text(controller.livenessMode == .light
                     ? "Light: 거부 신호만 실행돼요. 명확히 거부되지 않으면 실물로 간주해요."
                     : "Heavy: 거부 신호가 하나라도 발생하면 스캔이 실패하고, 통과하려면 확인 신호가 최소 하나 발생해야 해요.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                cueGroup(
                    title: "거부 — 위조 증거",
                    caption: "둘 중 하나라도 발생하면 얼굴 잠금 해제가 즉시 실패하고, 확인 신호보다 우선해요.",
                    cues: LivenessCue.allCases.filter { $0.role == .deny }
                )

                cueGroup(
                    title: "확인 — 실제 얼굴 증거",
                    caption: "하나라도 발생하면 실물 확인을 통과해요. 아무것도 발생하지 않아도 실패는 아니며 스캔이 계속 확인해요.",
                    cues: LivenessCue.allCases.filter { $0.role == .confirm }
                )

                rawMeasurementsBlock
                geometryDiagnosticsBlock

                HStack {
                    Button("신호 재설정") { controller.resetLiveness() }
                    Text("신호 발생은 스캔이 끝날 때까지 유지돼요 — 다시 테스트하려면 재설정하세요.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var decisionStrip: some View {
        let decision = controller.currentLiveness.decision
        let (color, label): (Color, String) = {
            switch decision {
            case .pending:
                return (.secondary, "대기 중 — 아직 판정 전")
            case .confirmed(let cue):
                return (.green, cue.map { "실물 — \($0.title)(으)로 확인됨" } ?? "실물 — 자동 확인됨 (Light 모드)")
            case .denied(let cue):
                return (.red, "위조 — \(cue.title)(으)로 거부됨")
            }
        }()
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(.body, design: .monospaced))
            Spacer()
            Text("\(controller.currentLiveness.frameCount)프레임")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cueGroup(title: String, caption: String, cues: [LivenessCue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(cues) { cue in
                cueRow(cue)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Level bar plus fire counter — the level only matters insofar as it crosses the fire threshold enough frames.
    private func cueRow(_ cue: LivenessCue) -> some View {
        let state = controller.currentLiveness.state(for: cue)
        let isEnabled = controller.isLivenessCueEnabled(cue)
        let threshold = controller.livenessTuning.level(for: cue)
        let framesNeeded = controller.livenessTuning.frames(for: cue)
        let hasEvidence = state.reading.confidence > 0

        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { controller.isLivenessCueEnabled(cue) },
                set: { controller.setLivenessCue(cue, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(cue.explanation)

            Text(cue.title)
                .font(.caption)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(hasEvidence ? (cue.role == .deny ? Color.orange : Color.accentColor) : Color.gray.opacity(0.3))
                        .frame(width: geometry.size.width * CGFloat(state.reading.level))
                    // Where this cue starts counting frames.
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: geometry.size.width * CGFloat(threshold))
                }
            }
            .frame(height: 8)

            Text(hasEvidence ? String(format: "%.0f%%", state.reading.level * 100) : "—")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)

            Text("\(state.framesCounted)/\(framesNeeded)")
                .font(.caption2.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)

            Text(state.hasFired ? "발생" : "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(cue.role == .deny ? Color.red : Color.green)
                .frame(width: 44, alignment: .leading)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    /// The actual measurements each cue level is derived from.
    private var rawMeasurementsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let frame = controller.lastLivenessFrame {
                Text("Left EAR: \(ratioString(frame.leftEyeAspectRatio))  Right EAR: \(ratioString(frame.rightEyeAspectRatio))  코 오프셋: \(ratioString(frame.noseOffsetRatio))")
                Text("기기 겹침: \(percentString(frame.deviceOverlapFraction))")
                if let glare = frame.glare {
                    Text("Specular: \(String(format: "%.4f", glare.specularFraction))  Cluster: \(String(format: "%.2f", glare.specularClusterRatio))  Crop: \(Int(glare.cropPixelWidth))px")
                } else {
                    Text("Specular: — (이 프레임에 원본 해상도 크롭 없음)")
                }
            } else {
                Text("아직 실물 확인 프레임이 없어요.")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var geometryDiagnosticsBlock: some View {
        let geo = controller.currentGeometry
        return VStack(alignment: .leading, spacing: 6) {
            Text("평면 대 3D 진단")
                .font(.caption.weight(.semibold))
            Text("랜드마크: \(geo.validLandmarkCount)   쌍: \(geo.pairsAnalyzed)   제외: \(geo.rejectedPairCount)")
            Text("Fit residual: \(ratioString(geo.medianFitResidual))  Probe residual: \(ratioString(geo.medianProbeResidual))  Excess: \(ratioString(geo.excessRatio))")
            Text("Coherence: \(ratioString(geo.coherence))  Motion: \(ratioString(geo.motionMagnitude))")
            if !geo.diagnosticRatios.isEmpty {
                Text(geo.diagnosticRatios.keys.sorted().map { key in
                    "\(key) \(ratioString(geo.diagnosticRatios[key]))"
                }.joined(separator: "  "))
            }
            if geo.planarConfidence == 0 {
                Text("판정 보류 — 머리 회전이 부족해 평면과 정지한 3D 얼굴을 구분할 수 없어요.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func ratioString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.3f", value)
    }

    private func percentString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    // MARK: - Enrollment

    private var enrollSection: some View {
        GroupBox("등록") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("이름", text: $controller.enrollName)
                        .textFieldStyle(.roundedBorder)
                    Button("샘플 캡처") {
                        controller.captureSample()
                    }
                    .disabled(controller.currentResult == nil || controller.store.isLocked)
                }

                if controller.store.identities.isEmpty {
                    Text(controller.store.isLocked ? "등록된 얼굴을 보려면 세션 잠금을 해제하세요." : "아직 등록된 얼굴이 없어요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        HStack {
                            Text(identity.name)
                            Text("샘플 \(identity.samples.count)개")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if identity.isStale(comparedTo: controller.pipeline.embedder) {
                                Text("stale")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                controller.deleteIdentity(identity)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Multi-identity enrollment

    private var identitiesSection: some View {
        GroupBox("얼굴") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(controller.store.identities.count)개 등록됨")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("얼굴 추가") {
                        controller.startAddIdentity()
                    }
                    .disabled(controller.store.isLocked || enrollmentFlowIsRunning)
                }

                if controller.store.identities.isEmpty {
                    Text(controller.store.isLocked
                         ? "등록된 얼굴을 보려면 세션 잠금을 해제하세요."
                         : "아직 등록된 얼굴이 없어요 — 얼굴 추가로 9가지 포즈 안내 캡처를 실행하세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        IdentityRow(
                            identity: identity,
                            isStale: identity.isStale(comparedTo: controller.pipeline.embedder),
                            lowQualityCount: controller.lowQualityCount(in: identity),
                            canStartFlow: !enrollmentFlowIsRunning,
                            recapture: { controller.startRecapture(of: identity) },
                            delete: { controller.deleteIdentity(identity) }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Recognition

    private var recognizeSection: some View {
        GroupBox("인식") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("식별") {
                        controller.recognize()
                    }
                    .disabled(controller.currentResult == nil || controller.store.identities.isEmpty)

                    Spacer()

                    Text("기준값: \(String(format: "%.2f", controller.threshold))")
                        .font(.caption)
                    Slider(value: $controller.threshold, in: -1...1)
                        .frame(width: 160)
                }

                if let best = controller.bestMatch {
                    HStack {
                        Circle().fill(.green).frame(width: 10, height: 10)
                        Text("최고 일치: \(best.name) — 중심 \(String(format: "%.3f", best.centroidSimilarity)), 최대 \(String(format: "%.3f", best.maxSampleSimilarity))")
                        Text("일치").font(.caption.bold()).foregroundStyle(.green)
                    }
                } else if let first = controller.recognitionResults.first {
                    HStack {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("가장 가까움: \(first.name) — 중심 \(String(format: "%.3f", first.centroidSimilarity)), 최대 \(String(format: "%.3f", first.maxSampleSimilarity))")
                        Text("불일치").font(.caption.bold()).foregroundStyle(.red)
                    }
                }

                if !controller.recognitionResults.isEmpty {
                    Divider()
                    ForEach(controller.recognitionResults) { result in
                        HStack {
                            Text(result.name)
                            if result.isStale {
                                Text("stale").font(.caption2.bold()).foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("중심 \(String(format: "%.3f", result.centroidSimilarity))")
                                .foregroundStyle(.secondary)
                            Text("최대 \(String(format: "%.3f", result.maxSampleSimilarity))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Threshold calibration

    private var calibrationSection: some View {
        GroupBox("기준값 보정") {
            VStack(alignment: .leading, spacing: 8) {
                Text("식별을 실행한 뒤 실제로 본인이었는지 다른 사람이었는지 표시하세요. 조명·각도·표정을 바꿔 가며, 다른 사람으로도 반복하면 두 점수 분포가 실제로 어디에 있는지 볼 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("본인으로 표시") {
                        controller.recordCalibrationSample(isGenuine: true)
                    }
                    Button("타인으로 표시") {
                        controller.recordCalibrationSample(isGenuine: false)
                    }
                    .disabled(controller.recognitionResults.isEmpty)
                    Spacer()
                    Button("지우기", role: .destructive) {
                        controller.clearCalibrationSamples()
                    }
                    .disabled(controller.calibrationSamples.isEmpty)
                }
                .disabled(controller.recognitionResults.isEmpty && controller.calibrationSamples.isEmpty)

                if !controller.calibrationSamples.isEmpty {
                    Chart {
                        ForEach(controller.calibrationSamples) { sample in
                            PointMark(
                                x: .value("유사도", sample.centroidSimilarity),
                                y: .value("유형", sample.isGenuine ? "본인" : "타인")
                            )
                            .foregroundStyle(sample.isGenuine ? Color.green : Color.red)
                        }
                        RuleMark(x: .value("기준값", controller.threshold))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                    .chartXScale(domain: -1...1)
                    .frame(height: 100)

                    if let suggested = controller.suggestedThreshold {
                        HStack {
                            Text("추천 기준값: \(String(format: "%.3f", suggested))")
                                .font(.caption)
                            Button("적용") {
                                controller.threshold = Double(suggested)
                            }
                            if controller.calibrationDistributionsOverlap {
                                Text("분포가 겹쳐요 — 아직 하나의 기준값으로 이 샘플들을 완벽히 나눌 수 없어요.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("추천을 받으려면 본인 샘플과 타인 샘플을 각각 하나 이상 기록하세요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Debug log

    private var logSection: some View {
        GroupBox("로그") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }

    private func yawPitchString(_ value: Float?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f", value)
    }
}

/// One enrolled person: a summary line, actions, and a disclosure listing every stored sample's capture quality.
private struct IdentityRow: View {
    let identity: FaceIdentity
    let isStale: Bool
    let lowQualityCount: Int
    let canStartFlow: Bool
    let recapture: () -> Void
    let delete: () -> Void

    private var posesCaptured: Int {
        Set(identity.samples.compactMap(\.pose)).count
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(identity.samples.enumerated()), id: \.offset) { index, sample in
                    HStack(spacing: 8) {
                        Text(String(format: "%2d", index + 1))
                            .foregroundStyle(.tertiary)
                        Text(sample.pose ?? "태그 없음")
                            .frame(width: 90, alignment: .leading)
                        Text(FaceLabController.qualityLabel(sample.quality))
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(isLow(sample) ? .orange : .primary)
                        Text(sample.capturedAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.caption.monospaced())
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity.name).bold()
                    if isStale {
                        Text("stale")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("다시 캡처", action: recapture)
                        .disabled(!canStartFlow)
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }

                Text("포즈 \(posesCaptured)/9 · 샘플 \(identity.samples.count)개 · 등록일 \(identity.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if lowQualityCount > 0 {
                    Text("샘플 \(identity.samples.count)개 중 \(lowQualityCount)개의 품질이 낮아요")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func isLow(_ sample: FaceSample) -> Bool {
        sample.qualityTier == .poor
    }
}

#Preview {
    FaceLabView(controller: FaceLabController())
}
