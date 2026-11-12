//
//  WindowSnapper.swift
//  Satchel
//
//  Rectangle-style window tiling via global shortcuts. macOS tiles left/right natively,
//  but not top/bottom — these fill that gap:
//    ⌃⌥←  left half      ⌃⌥→  right half
//    ⌃⌥↑  top half       ⌃⌥↓  bottom half
//    ⌃⌥↩  fill screen
//  Hotkeys use Carbon's RegisterEventHotKey (no permission needed); moving another app's
//  window uses Accessibility, which Satchel already holds for face unlock.
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

@MainActor
final class WindowSnapper {
    static let shared = WindowSnapper()

    enum Action: UInt32, CaseIterable {
        case leftHalf = 1, rightHalf, topHalf, bottomHalf, fill

        var keyCode: Int {
            switch self {
            case .leftHalf: return kVK_LeftArrow
            case .rightHalf: return kVK_RightArrow
            case .topHalf: return kVK_UpArrow
            case .bottomHalf: return kVK_DownArrow
            case .fill: return kVK_Return
            }
        }

        var title: String {
            switch self {
            case .leftHalf: return "왼쪽 반"
            case .rightHalf: return "오른쪽 반"
            case .topHalf: return "위쪽 반"
            case .bottomHalf: return "아래쪽 반"
            case .fill: return "화면 채우기"
            }
        }

        var shortcutLabel: String {
            switch self {
            case .leftHalf: return "⌃⌥←"
            case .rightHalf: return "⌃⌥→"
            case .topHalf: return "⌃⌥↑"
            case .bottomHalf: return "⌃⌥↓"
            case .fill: return "⌃⌥↩"
            }
        }

        /// Target rect inside the screen's usable area (Cocoa coordinates, bottom-left origin).
        func frame(in visible: CGRect) -> CGRect {
            let halfW = (visible.width / 2).rounded(.down)
            let halfH = (visible.height / 2).rounded(.down)
            switch self {
            case .leftHalf:
                return CGRect(x: visible.minX, y: visible.minY, width: halfW, height: visible.height)
            case .rightHalf:
                return CGRect(x: visible.maxX - halfW, y: visible.minY, width: halfW, height: visible.height)
            case .topHalf:
                return CGRect(x: visible.minX, y: visible.maxY - halfH, width: visible.width, height: halfH)
            case .bottomHalf:
                return CGRect(x: visible.minX, y: visible.minY, width: visible.width, height: halfH)
            case .fill:
                return visible
            }
        }
    }

    private static let signature: OSType = 0x5354_4348 // 'STCH'
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?

    // MARK: - Registration

    /// Registers or unregisters the shortcuts according to settings. Safe to call repeatedly.
    func applySettings() {
        unregister()
        guard GlanceSettings.shared.windowSnapEnabled else { return }
        register()
    }

    private func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr, hotKeyID.signature == WindowSnapper.signature,
                  let action = WindowSnapper.Action(rawValue: hotKeyID.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { WindowSnapper.shared.perform(action) }
            return noErr
        }, 1, &eventType, nil, &handlerRef)

        let modifiers = UInt32(controlKey | optionKey)
        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            // Fails quietly if another app already owns the combination.
            if RegisterEventHotKey(UInt32(action.keyCode), modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                hotKeyRefs.append(ref)
            } else {
                NSLog("WindowSnapper: \(action.shortcutLabel) is already taken by another app")
            }
        }
    }

    private func unregister() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    // MARK: - Moving windows

    func perform(_ action: Action) {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
              let windowValue else { return }
        let window = windowValue as! AXUIElement

        guard let current = Self.frame(of: window),
              let screen = Self.screen(containingAXFrame: current) else { return }
        let target = Self.axRect(fromCocoa: action.frame(in: screen.visibleFrame))

        // Size → position → size: a window that can't grow past the screen edge at its old
        // position gets its final size only after it has moved (the same trick Rectangle uses).
        Self.set(size: target.size, on: window)
        Self.set(position: target.origin, on: window)
        Self.set(size: target.size, on: window)
    }

    // MARK: - Geometry

    /// AX uses a top-left origin anchored at the primary screen; Cocoa uses bottom-left.
    private static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    private static func axRect(fromCocoa rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func cocoaRect(fromAX rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The screen showing most of the window.
    private static func screen(containingAXFrame axFrame: CGRect) -> NSScreen? {
        let frame = cocoaRect(fromAX: axFrame)
        return NSScreen.screens.max { a, b in
            area(a.frame.intersection(frame)) < area(b.frame.intersection(frame))
        } ?? NSScreen.main
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private static func set(size: CGSize, on window: AXUIElement) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    private static func set(position: CGPoint, on window: AXUIElement) {
        var position = position
        if let value = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }
}
