//
//  RecognitionSettingsPage.swift
//  glance
//

import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — same reasoning as
    /// `PasswordSettingsPage`.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
        // Password/name/enrollment flows run in the notch, outside this
        // window, so nothing else prompts a re-check once one closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "세션 잠김",
            buttonTitle: isUnlocking ? "인증 중…" : "세션 열기",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsGroup {
                SettingsOptionSliderRowContent(
                    title: "일치 신뢰도",
                    stepLabels: MatchConfidenceLevel.allCases.map(\.title),
                    index: matchConfidenceIndex,
                    stopCount: MatchConfidenceLevel.allCases.count
                )

                SettingsGroupDivider()

                SettingsOptionSliderRowContent(
                    title: "인식 거리",
                    stepLabels: DetectionDistanceLevel.allCases.map(\.title),
                    index: detectionDistanceIndex,
                    stopCount: DetectionDistanceLevel.allCases.count
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "실물 확인")
                SettingsGroup {
                    SettingsRowContent(
                        title: "실물 확인 사용",
                        subtitle: "사진이 아닌 실제 사람인지 확인해요. 잠금 해제 시간이 늘어날 수 있어요.",
                        subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                    ) {
                        GlanceToggle(isOn: $settings.livenessChecksEnabled)
                    }
                    SettingsGroupDivider()
                    LivenessModePicker(
                        selection: $settings.livenessMode,
                        isEnabled: settings.livenessChecksEnabled
                    )
                }
            }
        }
    }

    // MARK: - Match confidence

    /// Nearest of the three snap points to whatever's stored, in case the
    /// value doesn't land exactly on one of the stops.
    private var matchConfidenceLevel: MatchConfidenceLevel {
        .nearest(to: coordinator.matchThreshold)
    }

    private var matchConfidenceIndex: Binding<Double> {
        Binding(
            get: { matchConfidenceLevel.sliderIndex },
            set: { coordinator.matchThreshold = MatchConfidenceLevel.from(sliderIndex: $0).threshold }
        )
    }

    // MARK: - Detection distance

    private var detectionDistanceLevel: DetectionDistanceLevel {
        .nearest(to: settings.minimumFaceWidth)
    }

    private var detectionDistanceIndex: Binding<Double> {
        Binding(
            get: { detectionDistanceLevel.sliderIndex },
            set: { settings.minimumFaceWidth = DetectionDistanceLevel.from(sliderIndex: $0).minimumFaceWidth }
        )
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}

/// The three selectable points on the "Match confidence" slider — named
/// rather than exposing the raw cosine-similarity threshold directly.
private enum MatchConfidenceLevel: Int, CaseIterable {
    case lessStrict, standard, moreStrict

    var title: String {
        switch self {
        case .lessStrict: return "느슨하게"
        case .standard: return "기본"
        case .moreStrict: return "엄격하게"
        }
    }

    var threshold: Float {
        switch self {
        case .lessStrict: return 0.58
        case .standard: return 0.63
        case .moreStrict: return 0.68
        }
    }

    /// Position in `allCases` — same role as `AutoLockInterval.sliderIndex`.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to threshold: Float) -> Self {
        allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .standard
    }
}

/// The three selectable points on the "Detection distance" slider.
private enum DetectionDistanceLevel: Int, CaseIterable {
    case close, standard, far

    var title: String {
        switch self {
        case .close: return "가까이"
        case .standard: return "기본"
        case .far: return "멀리"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.23
        case .standard: return 0.19
        case .far: return 0.15
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to width: Float) -> Self {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .standard
    }
}
