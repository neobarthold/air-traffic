import AirTrafficCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let chooser: ChooserController
    let opener: Opener
    let intake: LinkIntake
    let updates: UpdateController
    private var settingsController: SettingsWindowController?

    var settings: SettingsWindowController {
        if let settingsController { return settingsController }
        let controller = SettingsWindowController(model: model)
        controller.onClose = { [weak self] in self?.updates.windowsDidClose() }
        settingsController = controller
        return controller
    }

    /// Kam seit dem Start ein Link? Dann beim Kaltstart kein Einstellungsfenster.
    private var receivedLink = false

    override init() {
        model = AppModel(store: .makeDefault())
        chooser = ChooserController(model: model)
        opener = Opener(model: model, chooser: chooser)
        intake = LinkIntake(model: model, opener: opener)
        updates = UpdateController(startingUpdater: true)
        super.init()
        chooser.opener = opener
        model.updates = updates
        chooser.onClose = { [weak self] in self?.updates.windowsDidClose() }
        updates.isBusy = { [weak self] in
            guard let self else { return false }
            return self.chooser.isShowing || self.settingsController?.window?.isVisible == true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("Gestartet, Konfiguration: \(self.model.store.fileURL.path, privacy: .public)")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !self.receivedLink else { return }
            self.showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedLink = true
        intake.receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.flushPendingSave()
    }

    func showSettings() {
        settings.show()
    }
}
