import AppKit
import SwiftUI

/// Einstellungsfenster mit Toolbar-Tabs (SPEC §15.2). Solange offen: Dock-Icon + Hauptmenü
/// (`.regular`), danach `.accessory`.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// Kleinste Inhaltsgröße (ohne Toolbar), bei der Regel-Liste und Editor nicht abgeschnitten werden.
    static let minSize = NSSize(width: 820, height: 560)

    private let model: AppModel
    let tabs: SettingsTabViewController
    /// Nach dem Schließen (z. B. wartendes Update installieren, §17).
    var onClose: (() -> Void)?

    /// `autosavesFrame: false` für Snapshots – der gespeicherte Fensterrahmen bleibt unberührt.
    init(model: AppModel, autosavesFrame: Bool = true) {
        self.model = model
        tabs = SettingsTabViewController(model: model)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.minSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.contentViewController = tabs
        window.contentMinSize = Self.minSize
        window.setContentSize(Self.minSize)
        if autosavesFrame { window.setFrameAutosaveName("AirTrafficSettings") }
        super.init(window: window)
        window.delegate = self
        tabs.syncFromModel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.make(updates: model.updates)
        if let window, window.isVisible != true {
            ensureMinimumSize()
            window.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Ein gespeicherter Rahmen von vor §13 kann kleiner als die Mindestgröße sein.
    func ensureMinimumSize() {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        if content.width < Self.minSize.width || content.height < Self.minSize.height {
            window.setContentSize(NSSize(
                width: max(content.width, Self.minSize.width),
                height: max(content.height, Self.minSize.height)
            ))
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }
}

/// `NSTabViewController` im Toolbar-Stil; `model.settingsTab` bleibt die Quelle.
@MainActor
final class SettingsTabViewController: NSTabViewController {
    private let model: AppModel
    private static let order: [SettingsTab] = [.general, .browsers, .rules]

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        // Kein Größen-Animieren je Tab: alle Tabs teilen sich die Fenstergröße.
        transitionOptions = []
        canPropagateSelectedChildViewControllerTitle = false

        add(GeneralSettingsView(model: model), label: "Allgemein", symbol: "gearshape")
        add(BrowsersSettingsView(model: model), label: "Browser", symbol: "globe")
        add(RulesSettingsView(model: model), label: "Regeln",
            symbol: "point.topleft.down.to.point.bottomright.curvepath")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func add(_ view: some View, label: String, symbol: String) {
        let root = view.frame(
            minWidth: SettingsWindowController.minSize.width,
            maxWidth: .infinity,
            minHeight: SettingsWindowController.minSize.height,
            maxHeight: .infinity
        )
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = []
        let item = NSTabViewItem(viewController: hosting)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        addTabViewItem(item)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        let tab = Self.order[selectedTabViewItemIndex]
        if model.settingsTab != tab { model.settingsTab = tab }
        updateTitle()
    }

    /// Beobachtet `model.settingsTab` (z. B. Alert „Zu ‚Allgemein‘“) und wählt den Tab.
    func syncFromModel() {
        let tab = withObservationTracking {
            model.settingsTab
        } onChange: { [weak self] in
            Task { @MainActor in self?.syncFromModel() }
        }
        let index = Self.order.firstIndex(of: tab) ?? 0
        if selectedTabViewItemIndex != index { selectedTabViewItemIndex = index }
        updateTitle()
    }

    func updateTitle() {
        guard tabViewItems.indices.contains(selectedTabViewItemIndex) else { return }
        view.window?.title = tabViewItems[selectedTabViewItemIndex].label
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateTitle()
    }
}
