//
//  MenuBarCollapser.swift
//  glance
//
//  Collapses other apps' menu-bar icons behind an arrow item, Hidden Bar–style.
//  Mechanism adapted from Hidden Bar's NativeVisibilityEngine / AccessibilityMenuBarInventory
//  (MIT, © 2026 Dwarves Foundation, https://github.com/dwarvesf/hidden — see
//  THIRD_PARTY_NOTICES.md), trimmed to a single hidden section.
//
//  macOS 27 ejects an over-wide status item from the bar, so the classic "inflate a
//  separator" trick no longer works. Instead:
//    1. While nothing is hidden, read every app's status-item frames via Accessibility.
//    2. Apps whose icons sit LEFT of the arrow form the hidden section.
//    3. Ask macOS (private MenuBarClientCore assessment-mode restriction) to keep only the
//       remaining apps + all system items visible. macOS hides the rest and reflows.
//  Hiding is per app, and macOS drops the restriction by itself if Glance quits.
//

import AppKit
import ApplicationServices

@MainActor
final class MenuBarCollapser: NSObject {
    static let shared = MenuBarCollapser()

    /// System items (clock, Wi-Fi, Control Center…) to always keep visible. Unknown ids
    /// are ignored, so the range covers items a given Mac doesn't have.
    private static let systemItemsToKeep = Array(0..<64)
    /// Bundles that own macOS's own controls; they can't be hidden per bundle.
    private static let systemItemOwners: Set<String> = [
        "com.apple.MenuBarAgent", "com.apple.controlcenter", "com.apple.systemuiserver",
    ]

    private var arrowItem: NSStatusItem?
    private var assertion: AnyObject?
    /// Bumped whenever an in-flight activation must no longer win.
    private var generation = 0
    private(set) var isCollapsed = false
    private var isBusy = false
    private var autoCollapseTimer: Timer?

    var isAvailable: Bool { GLMenuBarVisibilityIsAvailable() }

    // MARK: - Lifecycle

    /// Installs or removes the arrow according to settings. Safe to call repeatedly.
    func applySettings() {
        if GlanceSettings.shared.menuBarCollapseEnabled && isAvailable {
            installArrowIfNeeded()
        } else {
            uninstall()
        }
    }

    private func installArrowIfNeeded() {
        guard arrowItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Persists the user's ⌘-drag position across launches.
        item.autosaveName = "glance_menubar_collapse_arrow"
        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(arrowClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "메뉴 막대 접기 · ⌘ 키를 누른 채 끌어서 위치를 바꿀 수 있어요. 화살표 왼쪽 아이콘이 접혀요."
        }
        arrowItem = item
        updateArrowImage()
        // Give other apps' items a moment to settle before the first collapse.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.collapse()
        }
    }

    private func uninstall() {
        autoCollapseTimer?.invalidate()
        releaseAssertion()
        isCollapsed = false
        if let arrowItem {
            NSStatusBar.system.removeStatusItem(arrowItem)
        }
        arrowItem = nil
    }

    // MARK: - Actions

    @objc private func arrowClicked() {
        guard !isBusy else { return }
        if isCollapsed {
            expand()
        } else {
            collapse()
        }
    }

    func collapse() {
        guard let arrowItem, !isCollapsed, !isBusy else { return }
        guard AXIsProcessTrusted() else {
            // Without Accessibility the sections can't be read; guessing would hide icons
            // the user kept visible. Glance already asks for this permission in onboarding.
            return
        }
        guard let boundary = arrowItem.button?.window?.frame else { return }
        isBusy = true
        autoCollapseTimer?.invalidate()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID && $0.bundleURL?.pathExtension == "app" }
            .map { (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier) }

        generation += 1
        let generation = self.generation
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Self.statusItems(of: apps)
            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.generation else { return }
                let visibleBundles = Self.visibleBundles(items: items, boundaryMidX: boundary.midX)
                self.activate(allowing: visibleBundles, generation: generation)
            }
        }
    }

    func expand() {
        generation += 1
        releaseAssertion()
        isCollapsed = false
        isBusy = false
        updateArrowImage()
        scheduleAutoCollapse()
    }

    // MARK: - Native restriction

    private func activate(allowing bundles: [String], generation: Int) {
        let allowed = [Bundle.main.bundleIdentifier].compactMap { $0 } + bundles
        GLMenuBarVisibilityActivate(Self.systemItemsToKeep.map { NSNumber(value: $0) }, allowed) { [weak self] newAssertion, error in
            guard let self, generation == self.generation else {
                if let newAssertion { GLMenuBarVisibilityInvalidate(newAssertion) }
                return
            }
            self.isBusy = false
            if let newAssertion {
                // Activate the new restriction before dropping the old one — no flash.
                let old = self.assertion
                self.assertion = newAssertion as AnyObject
                if let old { GLMenuBarVisibilityInvalidate(old) }
                self.isCollapsed = true
            } else {
                // Fail open: never leave icons hidden after an error.
                NSLog("MenuBarCollapser: activation failed: \(error?.localizedDescription ?? "unknown")")
                self.releaseAssertion()
                self.isCollapsed = false
            }
            self.updateArrowImage()
        }
    }

    private func releaseAssertion() {
        if let assertion { GLMenuBarVisibilityInvalidate(assertion) }
        assertion = nil
    }

    private func scheduleAutoCollapse() {
        autoCollapseTimer?.invalidate()
        let seconds = GlanceSettings.shared.menuBarAutoCollapseSeconds
        guard seconds > 0 else { return }
        autoCollapseTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(seconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Don't snap shut while the pointer is in the menu bar (mid-click/drag).
                if Self.isMouseInMenuBar {
                    self.scheduleAutoCollapse()
                } else {
                    self.collapse()
                }
            }
        }
    }

    private static var isMouseInMenuBar: Bool {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.contains { screen in
            mouse.x >= screen.frame.minX && mouse.x <= screen.frame.maxX
                && mouse.y >= screen.visibleFrame.maxY && mouse.y <= screen.frame.maxY
        }
    }

    private func updateArrowImage() {
        // Collapsed shows "‹" (click to reveal what's to the left); expanded shows "›".
        let name = isCollapsed ? "chevron.left" : "chevron.right"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: isCollapsed ? "메뉴 막대 펼치기" : "메뉴 막대 접기")
        image?.isTemplate = true
        arrowItem?.button?.image = image
    }

    // MARK: - Sections

    /// Apps with at least one icon right of the arrow stay visible (hiding is per app,
    /// and the most visible icon wins so nothing the user kept visible disappears).
    private nonisolated static func visibleBundles(items: [(bundleID: String?, frame: CGRect)], boundaryMidX: CGFloat) -> [String] {
        var visible: Set<String> = []
        for item in items {
            guard let bundle = item.bundleID, !systemItemOwners.contains(bundle) else { continue }
            if item.frame.midX > boundaryMidX {
                visible.insert(bundle)
            }
        }
        return visible.sorted()
    }

    /// Every running app's AXExtrasMenuBar children. Off the main thread: Accessibility
    /// round-trips to every app take about a second in total.
    private nonisolated static func statusItems(of apps: [(pid: pid_t, bundleID: String?)]) -> [(bundleID: String?, frame: CGRect)] {
        var items: [(bundleID: String?, frame: CGRect)] = []
        for app in apps {
            let element = AXUIElementCreateApplication(app.pid)
            // One busy app must not stall the collapse for seconds.
            AXUIElementSetMessagingTimeout(element, 0.1)
            var barValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &barValue) == .success,
                  let bar = barValue else { continue }
            var childrenValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &childrenValue) == .success,
                  let children = childrenValue as? [AXUIElement] else { continue }
            for child in children {
                var positionValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &positionValue) == .success,
                      AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeValue) == .success else { continue }
                var position = CGPoint.zero
                var size = CGSize.zero
                AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                // Only x matters, and it's the same in AX (top-left) and AppKit coordinates.
                items.append((app.bundleID, CGRect(origin: position, size: size)))
            }
        }
        return items
    }
}
