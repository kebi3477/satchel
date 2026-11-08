//
//  GeneralSettingsPage.swift
//  glance
//

import OSLog
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    /// Refreshed on `didChangeScreenParametersNotification` so the picker
    /// reflects displays connecting/disconnecting while Settings is open.
    @State private var screens: [NSScreen] = NSScreen.screens
    /// Refreshed when the app regains focus, so granting the permission in
    /// System Settings clears the prompt below without a relaunch.
    @State private var inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController`, not a local copy — the session can be
    /// auto-locked while this page is visible.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    private var needsInputMonitoring: Bool {
        settings.unlockTriggers.contains(.onSpace) && inputMonitoring != .granted
    }

    /// Dev-only: under Xcode the reading above is Xcode's permission, not
    /// glance's, so it's meaningless. See `SpaceKeyMonitor.isLaunchedByXcode`.
    private var hasInheritedXcodePermission: Bool {
        settings.unlockTriggers.contains(.onSpace) && SpaceKeyMonitor.isLaunchedByXcode
    }

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
        // The password prompt runs in the notch, outside this view's hierarchy,
        // so refresh the session state when that flow finishes.
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
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(title: "로그인 시 실행") {
                    GlanceToggle(isOn: Binding(
                        get: { launchAtLoginEnabled },
                        set: { newValue in
                            launchAtLoginEnabled = newValue
                            do {
                                try LaunchAtLogin.setEnabled(newValue)
                                launchAtLoginError = nil
                            } catch {
                                launchAtLoginEnabled = !newValue
                                launchAtLoginError = error.localizedDescription
                            }
                        }
                    ))
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "메뉴 막대에 표시") {
                    GlanceToggle(isOn: $settings.showsInMenuBar)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "얼굴 잠금 해제 사용") {
                    GlanceToggle(isOn: $coordinator.isEnabled)
                }
                SettingsGroupDivider()
                UnlockTriggerPicker(selection: $settings.unlockTriggers, isEnabled: coordinator.isEnabled)
                SettingsGroupDivider()
                displayPicker()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                screens = NSScreen.screens
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
            }
            .onChange(of: settings.unlockTriggers) { oldValue, newValue in
                // Only prompt on the transition into selecting "On space".
                SpaceKeyMonitor.log.info("unlockTriggers changed: old=\(String(describing: oldValue), privacy: .public) new=\(String(describing: newValue), privacy: .public) state=\(String(describing: inputMonitoring), privacy: .public)")
                if newValue.contains(.onSpace), !oldValue.contains(.onSpace), inputMonitoring != .granted {
                    SpaceKeyMonitor.requestInputMonitoringAccess()
                    // tccd flips notDetermined -> denied just after the call
                    // returns, so re-read on the next beat rather than inline.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                    }
                }
            }
            if let launchAtLoginError {
                SettingsCaption(text: launchAtLoginError)
            }
            if hasInheritedXcodePermission {
                SettingsCaption(text: "Xcode에서 실행 중이에요. 권한 확인이 glance가 아닌 Xcode의 권한 기준으로 이루어지므로 이 상태는 정확하지 않아요. 실제 상태를 보려면 glance.app을 직접 실행해 주세요.")
            } else if needsInputMonitoring {
                inputMonitoringNotice()
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "동작")
                SettingsGroup {
                    SettingsRowContent(title: "노치에 포인터를 올리면 재시도") {
                        GlanceToggle(isOn: $settings.retryOnHover)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "실패 시 한 번 자동 재시도") {
                        GlanceToggle(isOn: $settings.autoRetryOnce)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "햅틱 피드백") {
                        GlanceToggle(isOn: $settings.hapticFeedbackEnabled)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(title: "인식 소리") {
                        GlanceToggle(isOn: $settings.soundEnabled)
                    }
                    if settings.soundEnabled {
                        SettingsGroupDivider()
                        SettingsSteppedSliderRowContent(
                            title: "소리 크기",
                            valueLabel: "\(settings.soundVolume)",
                            index: Binding(
                                get: { Double(settings.soundVolume) },
                                set: { newValue in
                                    let level = Int(newValue.rounded())
                                    guard level != settings.soundVolume else { return }
                                    settings.soundVolume = level
                                    // Preview so the level can be judged by ear.
                                    ScanSoundPlayer.shared.tick(progress: 0.8)
                                }
                            ),
                            stopCount: GlanceSettings.soundVolumeRange.count
                        )
                    }
                    SettingsGroupDivider()
                    SettingsSteppedSliderRowContent(
                        title: "얼굴 인식 시간",
                        valueLabel: "\(settings.faceDetectionSeconds)초",
                        index: Binding(
                            get: { Double(settings.faceDetectionSeconds - GlanceSettings.faceDetectionRange.lowerBound) },
                            set: { settings.faceDetectionSeconds = GlanceSettings.faceDetectionRange.lowerBound + Int($0.rounded()) }
                        ),
                        stopCount: GlanceSettings.faceDetectionRange.count
                    )
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "메뉴 막대 접기")
                SettingsGroup {
                    SettingsRowContent(title: "메뉴 막대 접기") {
                        GlanceToggle(isOn: $settings.menuBarCollapseEnabled)
                    }
                    if settings.menuBarCollapseEnabled {
                        SettingsGroupDivider()
                        SettingsRowContent(title: "10초 뒤 자동으로 다시 접기") {
                            GlanceToggle(isOn: Binding(
                                get: { settings.menuBarAutoCollapseSeconds > 0 },
                                set: { settings.menuBarAutoCollapseSeconds = $0 ? 10 : 0 }
                            ))
                        }
                    }
                }
                Text(MenuBarCollapser.shared.isAvailable
                     ? "메뉴 막대의 화살표 왼쪽에 있는 앱 아이콘이 접혀요. ⌘ 키를 누른 채 아이콘이나 화살표를 끌어서 접을 아이콘을 정할 수 있어요."
                     : "이 macOS 버전에서는 메뉴 막대 접기를 사용할 수 없어요.")
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textSecondary)
                    .padding(.horizontal, 4)
            }
            .onChange(of: settings.menuBarCollapseEnabled) { _, _ in
                MenuBarCollapser.shared.applySettings()
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "애니메이션")
                SettingsGroup {
                    SettingsRowContent(title: "애니메이션 표시") {
                        GlanceToggle(isOn: $settings.showUnlockAnimation)
                    }
                    SettingsGroupDivider()
                    UnlockAnimationPicker(
                        selection: $settings.unlockAnimationStyle,
                        isEnabled: settings.showUnlockAnimation
                    )
                }
            }
        }
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }

    /// Shown while "On space" is selected but Input Monitoring isn't granted.
    private func inputMonitoringNotice() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(text: "‘스페이스 키’ 조건은 잠금 화면에서 스페이스 키 입력을 감지하기 위해 키보드를 직접 읽으므로 손쉬운 사용 권한이 필요해요. glance가 암호를 입력할 때 쓰는 것과 같은 권한이에요. 개인정보 보호 및 보안 → 손쉬운 사용에서 glance를 켠 다음, glance를 종료하고 다시 열어 주세요.")
            Button("손쉬운 사용 설정 열기") {
                // Covers the rare install with no Accessibility grant at all.
                SpaceKeyMonitor.requestInputMonitoringAccess()
                openSystemSettings(pane: "Privacy_Accessibility")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(GlanceTheme.accent)
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func displayPicker() -> some View {
        SettingsRowContent(title: "표시할 디스플레이") {
            SettingsMenuPickerPill(label: displayLabel) {
                Button("주 디스플레이") {
                    settings.preferredDisplayID = nil
                    settings.preferredDisplayName = nil
                }
                ForEach(screens.compactMap(NamedScreen.init), id: \.id) { screen in
                    Button(screen.name) {
                        settings.preferredDisplayID = screen.id
                        settings.preferredDisplayName = screen.name
                    }
                }
            }
        }
    }

    /// A connected screen with its stable ID already unwrapped, so the
    /// picker's `ForEach` doesn't need to filter/force-unwrap inline.
    private struct NamedScreen {
        let id: String
        let name: String

        init?(_ screen: NSScreen) {
            guard let id = screen.stableDisplayID else { return nil }
            self.id = id
            self.name = screen.localizedName
        }
    }

    private var displayLabel: String {
        guard let targetID = settings.preferredDisplayID else { return "주 디스플레이" }
        if let connected = screens.first(where: { $0.stableDisplayID == targetID }) {
            return connected.localizedName
        }
        // Picked, but not currently connected — say so rather than showing
        // a bare ID or falling back to another display's name.
        guard let name = settings.preferredDisplayName else { return "선택한 디스플레이(연결 끊김)" }
        return "\(name)(연결 끊김)"
    }
}
