import AppKit
import SwiftUI
import Combine
import QuartzCore

@MainActor final class PanelController {
    let state = PanelState()
    private let panel: NSPanel
    private let store: UsageStore
    private let settings: Settings
    private var timer: Timer?
    private var mustExitActivation = false
    private var subscriptions = Set<AnyCancellable>()
    private var settingsWindow: NSWindow?
    private var analyticsWindow: NSWindow?

    init(store: UsageStore, settings: Settings) {
        self.store = store; self.settings = settings
        panel = NSPanel(contentRect: .zero,styleMask: [.borderless,.nonactivatingPanel],backing: .buffered,defer: false)
        panel.isFloatingPanel = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
        let view = PanelView(store: store,settings: settings,state: state,
            openSettings: { [weak self] in self?.showSettings() },
            openAnalytics: { [weak self] projects in self?.showAnalytics(projects: projects) },
            close: { [weak self] in self?.collapse() })
        panel.contentView = NSHostingView(rootView: view)
        state.$expanded.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.position(animated: true) } }.store(in: &subscriptions)
        state.$selected.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { self?.position(animated: true) } }.store(in: &subscriptions)
        settings.$values.dropFirst().sink { [weak self] values in
            let code = (values.language ?? .turkish).rawValue
            let languageChanged = L10n.override != code
            L10n.override = code
            DispatchQueue.main.async {
                self?.position(animated: false)
                self?.settingsWindow?.title = L("Kenar Ayarları")
                self?.analyticsWindow?.title = L("Kenar · Kullanım ve Projeler")
                if languageChanged { Notifier.shared.preferencesChanged(); self?.store.refreshAll() }
            }
        }.store(in: &subscriptions)
        store.$snapshots.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { guard let self else { return }; self.position(animated: !self.state.expanded) } }.store(in: &subscriptions)
        store.$connectionRevision.dropFirst().sink { [weak self] _ in DispatchQueue.main.async { guard let self else { return }; self.position(animated: !self.state.expanded) } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            DispatchQueue.main.async { self?.position(animated: false) }
        }.store(in: &subscriptions)
        timer = Timer.scheduledTimer(withTimeInterval: PanelInteraction.pollInterval,repeats: true) { [weak self] _ in Task { @MainActor in self?.trackMouse() } }
        if Preview.isEnabled { state.expanded = true; state.pinned = true }
        position(animated: false); panel.orderFrontRegardless()
    }
    private var screen: NSScreen? {
        let chosen = settings.values.displayID
        return NSScreen.screens.first { DisplayGeometry.screenID($0) == chosen } ?? NSScreen.screens.first
    }
    private var expandedSize: NSSize {
        let visible = store.snapshots.filter { !settings.values.hiddenProviders.contains($0.id) }
        let rowsHeight = Double(visible.count) * (settings.values.fontSize > 14 ? 62 : 56)
        let details = visible.first { $0.id == state.selected }.map { Double(max(1,$0.windows.count)) * 60 + Double($0.products.count) * 38 + 38 + ($0.isStale ? 28 : 0) + ($0.error != nil ? 36 : 0) } ?? 0
        return NSSize(width: settings.values.width,height: max(210,rowsHeight + 122 + details + (Preview.isEnabled ? 18 : 0)))
    }
    private var compactSize: NSSize {
        NSSize(width: 66,height: Double(max(1,store.compactProviders(hiddenProviders: settings.values.hiddenProviders).count)) * 42 + 48 + (Preview.isEnabled ? 12 : 0))
    }
    private func usableFrame(_ screen: NSScreen) -> NSRect {
        // Join the usable desktop boundary without obscuring a side-mounted Dock.
        screen.visibleFrame
    }
    private func position(animated: Bool) {
        guard let screen else { return }
        let frame = DisplayGeometry.frame(edge: settings.values.edge,visible: usableFrame(screen),size: expandedSize,expanded: state.expanded,compactSize: compactSize)
        panel.appearance = settings.values.theme == .system ? nil : NSAppearance(named: settings.values.theme == .dark ? .darkAqua : .aqua)
        if animated {
            NSAnimationContext.runAnimationGroup { context in context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : PanelInteraction.motionDuration; context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut); panel.animator().setFrame(frame,display: true) }
        } else { panel.setFrame(frame,display: true) }
    }
    private func trackMouse() {
        guard let screen else { return }
        let mouse = NSEvent.mouseLocation
        let tab = DisplayGeometry.frame(edge: settings.values.edge,visible: usableFrame(screen),size: expandedSize,expanded: false,compactSize: compactSize)
        let activation = tab.insetBy(dx: -PanelInteraction.hitSlop,dy: -PanelInteraction.hitSlop)
        if !activation.contains(mouse) { mustExitActivation = false }
        switch PanelInteraction.action(mouse:mouse,activation:activation,panel:panel.frame,expanded:state.expanded,pinned:state.pinned,suppressed:mustExitActivation) {
        case .expand: state.expanded = true
        case .collapse: collapse()
        case .none: break
        }
    }
    private func collapse() {
        mustExitActivation = true
        state.pinned = false; state.selected = nil; state.expanded = false
    }
    func showSettings() {
        if let settingsWindow { present(settingsWindow); return }
        let host = NSHostingController(rootView: SettingsView(settings: settings))
        let window = NSWindow(contentViewController: host)
        window.title = L("Kenar Ayarları"); window.styleMask = [.titled,.closable,.miniaturizable]
        window.isReleasedWhenClosed = false; window.center(); settingsWindow = window; present(window)
    }
    func showAnalytics(projects: Bool) {
        let host = NSHostingController(rootView: AnalyticsView(store: store.analytics,tab: projects ? 1 : 0,settings: settings))
        if let window = analyticsWindow { window.contentViewController = host; present(window); return }
        let window = NSWindow(contentViewController: host)
        window.title = L("Kenar · Kullanım ve Projeler"); window.setContentSize(NSSize(width: 780,height: 600))
        window.minSize = NSSize(width: 740,height: 590); window.isReleasedWhenClosed = false; window.center()
        analyticsWindow = window; present(window)
    }
    private func present(_ window: NSWindow) { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
}
