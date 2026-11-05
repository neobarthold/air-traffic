import AppKit

// Debug-Schalter: `--decide <url> [--source <bundleID>]` → Decision als JSON, kein Fenster.
if CommandLine.arguments.contains(DecideCommand.flag) {
    exit(DecideCommand.run(arguments: CommandLine.arguments))
}

// Debug-Schalter: `--suggest-regex "<Beschreibung>" --example <url> … [--mode rewrite|condition] [--provider openrouter|claude|codex]`
// → geprüfter Regex-Vorschlag als JSON, kein Fenster.
if CommandLine.arguments.contains(SuggestRegexCommand.flag) {
    Task { @MainActor in
        exit(await SuggestRegexCommand.run(arguments: CommandLine.arguments))
    }
    dispatchMain()
}

// Debug-Schalter: `--snapshot <dir>` → PNGs von Chooser und Einstellungen (hell/dunkel), kein sichtbares Fenster.
if CommandLine.arguments.contains(SnapshotCommand.flag) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    Task { @MainActor in
        exit(await SnapshotCommand.run(arguments: CommandLine.arguments))
    }
    app.run()
}

let app = NSApplication.shared
// `NSApplication.delegate` ist weak – die Instanz lebt als globale Konstante.
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()
