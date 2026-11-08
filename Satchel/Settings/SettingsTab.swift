//
//  SettingsTab.swift
//  glance
//
//  The tab bar's tab list. Debug-only Face Lab — the remaining live test
//  harness, kept for ongoing tuning — is appended only once revealed.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case yourFace
    case password
    case camera
    case recognition
    case about
    case debugFaceLab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "일반"
        case .yourFace: return "얼굴"
        case .password: return "암호"
        case .camera: return "카메라"
        case .recognition: return "인식"
        case .about: return "정보"
        case .debugFaceLab: return "Face Lab"
        }
    }

    /// `.yourFace` uses a custom mark — SF Symbols has no equivalent.
    /// Every other tab is a built-in symbol; see `SettingsTabIcon`.
    var icon: SettingsTabIcon {
        switch self {
        case .general: return .system("gearshape.fill")
        case .yourFace: return .asset("YourFaceIcon")
        case .password: return .system("lock.fill")
        case .camera: return .system("video.fill")
        case .recognition: return .system("sparkle")
        case .about: return .system("info.circle.fill")
        case .debugFaceLab: return .system("flask")
        }
    }

    /// Tabs in tab bar order, minus `.debugFaceLab` unless it's been
    /// unlocked this launch — see `AppEnvironment.isDebugSectionRevealed`.
    static func visibleTabs(includingDebug: Bool) -> [SettingsTab] {
        includingDebug ? allCases : allCases.filter { $0 != .debugFaceLab }
    }
}
