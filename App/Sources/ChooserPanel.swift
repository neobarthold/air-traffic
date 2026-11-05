import AirTrafficCore
import AppKit
import SwiftUI

struct ChooserRequest {
    var url: URL
    var sourceBundleIdentifier: String?
    var scope: PromptScope
    var hint: String?

    func with(hint: String) -> ChooserRequest {
        var copy = self
        copy.hint = hint
        return copy
    }
}

/// Zustand des Chooser-Inhalts.
@MainActor
@Observable
final class ChooserState {
    var urlText: String
    var browsers: [AppRef]
    var selection = 0
    var hint: String?
    /// URL-Feld fokussiert → vollständiges Textfeld statt strukturierter Anzeige.
    var isEditingURL = false
    let sourceName: String?
    let sourceIcon: NSImage?
    /// Je Browser: läuft / nicht gefunden (beim Öffnen des Panels ermittelt).
    let running: [Bool]
    let missing: [Bool]

    init(request: ChooserRequest, browsers: [AppRef]) {
        urlText = request.url.absoluteString
        self.browsers = browsers
        running = browsers.map(Apps.isRunning)
        missing = browsers.map { Apps.url(for: $0) == nil }
        hint = request.hint
        if let id = request.sourceBundleIdentifier {
            sourceName = Apps.displayName(forBundleIdentifier: id) ?? id
            sourceIcon = Apps.icon(forBundleIdentifier: id)
        } else {
            sourceName = nil
            sourceIcon = nil
        }
    }

    /// Bearbeitete URL; `nil`, wenn ungültig.
    var editedURL: URL? {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), url.scheme != nil else { return nil }
        return url
    }
}

/// Titelloses, schwebendes Panel, das Tastatureingaben bekommt.
final class ChooserPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Zeigt Chooser-Anfragen nacheinander.
@MainActor
final class ChooserController: NSObject, NSWindowDelegate {
    weak var opener: Opener?
    private let model: AppModel
    private var queue: [ChooserRequest] = []
    private var panel: ChooserPanel?
    private var state: ChooserState?
    private var monitor: Any?
    private weak var urlField: NSTextField?
    /// Nach dem Schließen des Panels (z. B. wartendes Update installieren, §17).
    var onClose: (() -> Void)?

    /// Panel offen oder weitere Anfragen in der Warteschlange.
    var isShowing: Bool { panel != nil || !queue.isEmpty }

    init(model: AppModel) {
        self.model = model
    }

    func present(_ request: ChooserRequest) {
        queue.append(request)
        if panel == nil { showNext() }
    }

    private func showNext() {
        guard !queue.isEmpty else { return }
        let request = queue.removeFirst()

        var browsers = model.effectiveBrowsers
        if request.scope == .running {
            let running = browsers.filter(Apps.isRunning)
            if !running.isEmpty { browsers = running }
        }
        let state = ChooserState(request: request, browsers: browsers)
        if browsers.isEmpty, state.hint == nil {
            state.hint = "Keine Browser gefunden – in den Einstellungen hinzufügen."
        }
        self.state = state

        let maxWidth = (Self.screenUnderMouse()?.visibleFrame.width).map { $0 - 80 } ?? 900
        let view = ChooserView(
            state: state,
            maxWidth: maxWidth,
            onOpen: { [weak self] index in self?.open(index: index) },
            onFieldSubmit: { [weak self] in self?.open(index: nil) },
            onFieldEscape: { [weak self] in self?.leaveURLField() },
            onFocusField: { [weak self] in self?.focusURLField() },
            registerField: { [weak self] field in self?.urlField = field }
        )
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]

        let panel = ChooserPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Transparentes Panel; Form, Glas/Material und Radius kommen aus dem SwiftUI-Inhalt.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = hosting
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        panel.delegate = self
        panel.setContentSize(hosting.view.fittingSize)
        center(panel)
        panel.invalidateShadow()
        self.panel = panel

        installKeyMonitor()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        // URL-Feld zunächst nicht fokussiert, damit 1–9 und Pfeile direkt wirken.
        panel.makeFirstResponder(nil)
        state.isEditingURL = false
        Log.chooser.info("Chooser gezeigt (\(browsers.count) Browser)")
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func center(_ panel: NSPanel) {
        guard let visible = Self.screenUnderMouse()?.visibleFrame else { panel.center(); return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2))
    }

    // MARK: Aktionen

    private func open(index: Int?) {
        guard let state, let panel else { return }
        let target = index ?? state.selection
        guard state.browsers.indices.contains(target) else { NSSound.beep(); return }
        guard let url = state.editedURL else {
            state.hint = "Ungültige URL."
            NSSound.beep()
            return
        }
        // ⌥ gedrückt → App nicht aktivieren.
        let activates = !NSEvent.modifierFlags.contains(.option)
        let app = state.browsers[target]
        if opener?.open(url, with: app, activates: activates) == true {
            close(panel)
        } else {
            state.hint = "„\(app.displayName)“ wurde nicht gefunden."
            NSSound.beep()
        }
    }

    private func copyURL() {
        guard let state else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.urlText, forType: .string)
    }

    private func leaveURLField() {
        panel?.makeFirstResponder(nil)
        state?.isEditingURL = false
    }

    private func focusURLField() {
        guard let panel, let urlField else { return }
        state?.isEditingURL = true
        panel.makeFirstResponder(urlField)
    }

    private var isEditingURL: Bool {
        guard let editor = panel?.firstResponder as? NSTextView, let urlField else { return false }
        return editor.delegate === urlField
    }

    private func close(_ panel: NSPanel) {
        removeKeyMonitor()
        panel.delegate = nil
        panel.orderOut(nil)
        self.panel = nil
        state = nil
        urlField = nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.showNext()
                self?.onClose?()
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        // Fokusverlust schließt das Panel.
        guard let panel, (notification.object as? NSPanel) === panel else { return }
        close(panel)
    }

    // MARK: Tastatur

    private func installKeyMonitor() {
        removeKeyMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Lokale Monitore laufen auf dem Main Thread.
            let consumed = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return consumed ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private enum Key {
        static let tab: UInt16 = 48
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let escape: UInt16 = 53
        static let left: UInt16 = 123
        static let right: UInt16 = 124
    }

    /// `true` = Ereignis verbraucht.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, let state else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""

        if isEditingURL {
            // Ohne Hauptmenü gibt es keine Standard-Tastenkürzel → selbst weiterreichen.
            if flags.contains(.command) {
                let actions: [String: Selector] = [
                    "c": #selector(NSText.copy(_:)), "v": #selector(NSText.paste(_:)),
                    "x": #selector(NSText.cut(_:)), "a": #selector(NSText.selectAll(_:)),
                    "z": flags.contains(.shift) ? Selector(("redo:")) : Selector(("undo:")),
                ]
                if let action = actions[chars.lowercased()] {
                    NSApp.sendAction(action, to: nil, from: self)
                    return true
                }
            }
            return false  // Enter/Esc behandelt das Feld selbst.
        }

        if flags.contains(.command) {
            if chars.lowercased() == "c" { copyURL(); return true }
            return false
        }
        switch event.keyCode {
        case Key.escape: close(panel); return true
        case Key.returnKey, Key.enter: open(index: nil); return true
        case Key.tab: focusURLField(); return true
        case Key.left:
            if !state.browsers.isEmpty { state.selection = max(0, state.selection - 1) }
            return true
        case Key.right:
            if !state.browsers.isEmpty { state.selection = min(state.browsers.count - 1, state.selection + 1) }
            return true
        default: break
        }
        if let digit = Int(chars), (1...9).contains(digit) {
            open(index: digit - 1)
            return true
        }
        return false
    }
}

// MARK: - SwiftUI

struct ChooserView: View {
    @Bindable var state: ChooserState
    /// Sichtbare Bildschirmbreite − 80.
    var maxWidth: CGFloat = 900
    /// Erscheinen animieren (120 ms); `false` für Snapshots.
    var animatesIn = true
    let onOpen: (Int) -> Void
    let onFieldSubmit: () -> Void
    let onFieldEscape: () -> Void
    let onFocusField: () -> Void
    let registerField: (NSTextField) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var appeared = false

    static let tileWidth: CGFloat = 96
    static let tileSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            urlRow
            tiles
                .padding(.top, 14)
                .padding(.bottom, 12)
            footer
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .frame(width: chooserWidth)
        .background { panelBackground }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(reduceTransparency ? 0 : 0.18), lineWidth: 0.5)
        )
        .opacity(appeared ? 1 : 0)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.985)
        .onAppear {
            guard animatesIn else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.12)) { appeared = true }
        }
    }

    @ViewBuilder private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(nsColor: .windowBackgroundColor))
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22))
        } else {
            shape.fill(.regularMaterial)
        }
    }

    // MARK: Kopf

    @ViewBuilder private var header: some View {
        if state.sourceName != nil || state.hint != nil {
            HStack(spacing: 6) {
                if let name = state.sourceName {
                    if let icon = state.sourceIcon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text("von \(name)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let hint = state.hint {
                    Label(hint, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.orange)
                        .lineLimit(2)
                }
            }
            .padding(.bottom, 10)
        }
    }

    // MARK: URL

    private var urlRow: some View {
        ZStack(alignment: .leading) {
            URLTextField(
                text: $state.urlText,
                onSubmit: onFieldSubmit,
                onEscape: onFieldEscape,
                onEditingChanged: { state.isEditingURL = $0 },
                register: registerField
            )
            .opacity(state.isEditingURL ? 1 : 0)
            .accessibilityHidden(!state.isEditingURL)

            if !state.isEditingURL {
                StructuredURL(text: state.urlText)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onFocusField)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("URL \(state.urlText)")
                    .accessibilityHint("Tab oder Klick zum Bearbeiten")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(.default, onFocusField)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.055)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(state.isEditingURL ? Color.accentColor : DS.separator,
                              lineWidth: state.isEditingURL ? 1 : 0.5)
        )
    }

    // MARK: Kacheln

    private var tiles: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Self.tileSpacing) {
                    ForEach(Array(state.browsers.enumerated()), id: \.offset) { index, app in
                        BrowserTile(
                            app: app,
                            number: index < 9 ? index + 1 : nil,
                            selected: index == state.selection,
                            running: state.running[index],
                            missing: state.missing[index]
                        )
                        .id(index)
                        .onTapGesture { onOpen(index) }
                        .onHover { inside in if inside { state.selection = index } }
                        .accessibilityAction { onOpen(index) }
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.09), value: state.selection)
            }
            .scrollDisabled(!overflows)
            .onChange(of: state.selection) { _, index in
                guard overflows else { return }
                withAnimation(.easeOut(duration: 0.09)) { proxy.scrollTo(index) }
            }
        }
        .frame(height: 100)
    }

    // MARK: Fußzeile

    private var footer: some View {
        HStack(spacing: 14) {
            hint("⏎", "Öffnen")
            hint("⌥⏎", "im Hintergrund")
            hint("⇥", "URL bearbeiten")
            hint("⌘C", "kopieren")
            Spacer(minLength: 0)
            hint("esc", "Abbrechen")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.top, 10)
        .overlay(alignment: .top) { Divider() }
    }

    private func hint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Keycap(key)
            Text(text)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(text): \(key)")
    }

    // MARK: Breite

    private var contentWidth: CGFloat {
        CGFloat(state.browsers.count) * (Self.tileWidth + Self.tileSpacing) - Self.tileSpacing
    }

    private var overflows: Bool { contentWidth > chooserWidth - 40 }

    /// `min(max(n × 104 + 40, 520), 900)`, höchstens sichtbare Bildschirmbreite − 80.
    var chooserWidth: CGFloat {
        let n = CGFloat(state.browsers.count)
        return min(min(max(n * 104 + 40, 520), 900), maxWidth)
    }
}

/// Unfokussierte URL: Schloss bei https, Host halbfett, Rest sekundär; gekürzt wird im Pfad.
private struct StructuredURL: View {
    let text: String

    private var parts: (secure: Bool, host: String, rest: String)? {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              let hostRange = text.range(of: host, options: .caseInsensitive)
        else { return nil }
        var hostText = String(text[hostRange])
        var rest = String(text[hostRange.upperBound...])
        if let port = components.port, rest.hasPrefix(":\(port)") {
            hostText += ":\(port)"
            rest.removeFirst(":\(port)".count)
        }
        return (scheme == "https", hostText, rest)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let parts {
                Image(systemName: parts.secure ? "lock" : "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    Text(parts.host).fontWeight(.semibold).lineLimit(1).fixedSize()
                    Text(parts.rest).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            } else {
                Text(text).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// NSTextField, damit Fokus und Enter/Esc genau steuerbar sind.
struct URLTextField: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onEscape: () -> Void
    var onEditingChanged: (Bool) -> Void = { _ in }
    let register: (NSTextField) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusReportingTextField(string: text)
        field.delegate = context.coordinator
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.placeholderString = "URL"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.onBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.parent.onEditingChanged(true)
        }
        field.setAccessibilityLabel("URL")
        register(field)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: URLTextField

        init(parent: URLTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onEditingChanged(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

/// Meldet, wenn das Feld Fokus bekommt (Klick oder Tab) – dann wechselt die Anzeige zum Textfeld.
final class FocusReportingTextField: NSTextField {
    var onBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }
}
