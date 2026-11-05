# Air Traffic — Spec v1

Air Traffic ersetzt Choosy: eine native macOS-App, die als Standardbrowser registriert wird, jeden Link entgegennimmt, ihn gegen Regeln prüft, **optional umschreibt** und an einen Browser oder eine App weitergibt.

## 1. Ziele (v1)

1. Als Standardbrowser registrierbar (http, https, lokale HTML-Dateien).
2. Regeln mit Bedingungen → optionale URL-Umschreibung → Aktion.
3. Auswahlfenster („Chooser“) mit **editierbarer URL**.
4. Einstellungsfenster: Browserliste, Regeln mit Test je Regel (§14).
5. Import der bestehenden Choosy-Konfiguration.

## 2. Nicht-Ziele (v1)

Menüleisten-Icon, Shortcuts/App Intents, Share-Extension, Browser-Erweiterungen, eigenes URL-Schema, Auto-Update (Sparkle), Lizenzierung, Browser-Profile, Verlauf. Kein App-Sandbox.

## 3. Technik

| Punkt | Festlegung |
|---|---|
| Sprache/UI | Swift 6 (strict concurrency), SwiftUI-Views in AppKit-Fenstern (`NSHostingController`) |
| App-Lebenszyklus | AppKit: `main.swift` + `NSApplicationDelegate`. Kein SwiftUI-`App`/`Settings`-Scene. |
| Mindest-OS | macOS 15.0 |
| Projekt | XcodeGen (`project.yml`, `/opt/homebrew/bin/xcodegen`); `.xcodeproj` wird generiert |
| Bundle-ID | `de.neoskop.AirTraffic`, Produktname „Air Traffic“ |
| Signierung | Entwicklung ad hoc (`CODE_SIGN_IDENTITY = "-"`); Releases ab 1.5 mit Developer ID (Neoskop GmbH, PVW9KTQ7MR), Hardened Runtime, notarisiert (§19); kein Sandbox |
| Aktivierung | `LSUIElement = YES` (kein Dock-Icon). Solange das Einstellungsfenster offen ist: `NSApp.setActivationPolicy(.regular)` + minimales Hauptmenü (App, Bearbeiten mit Cut/Copy/Paste/Select All/Undo, Fenster), danach zurück auf `.accessory`. Grund: ohne Hauptmenü funktionieren ⌘C/⌘V in Textfeldern nicht. |
| Logging | `os.Logger(subsystem: "de.neoskop.AirTraffic", category: …)` |

### Projektstruktur

```
Air-traffic/
  project.yml
  App/
    Sources/            main.swift, AppDelegate, LinkIntake, Opener, ChooserPanel, Settings/…
    Resources/Assets.xcassets   (AppIcon-Platzhalter, AccentColor)
    Info.plist
  Packages/AirTrafficCore/      Swift Package, nur Foundation, keine AppKit-Abhängigkeit
    Sources/AirTrafficCore/     Model, RuleEngine, Rewriter, ChoosyImporter, ConfigStore
    Tests/AirTrafficCoreTests/  inkl. Fixtures/
  docs/SPEC.md
```

### Info.plist

- `CFBundleURLTypes`: `http`, `https`.
- `CFBundleDocumentTypes`: `public.html`, `public.xhtml` (`LSItemContentTypes`), Rolle `Viewer`. Beides ist nötig, damit macOS die App als Browser anbietet.
- `LSUIElement = YES`, `NSPrincipalClass = NSApplication`.

## 4. Datenmodell (AirTrafficCore, alles `Codable`, `Sendable`)

Konfiguration als JSON: `~/Library/Application Support/Air Traffic/config.json`, menschenlesbar (`prettyPrinted`, `sortedKeys`), Feld `schemaVersion: 1`. Atomar schreiben.

```swift
struct AppRef { var bundleIdentifier: String?; var path: String; var displayName: String }
// Auflösung: erst bundleIdentifier via NSWorkspace (in der App-Schicht), sonst path.

struct Config {
  var schemaVersion: Int            // 1
  var browsers: [AppRef]            // geordnet, oben = Favorit; Liste im Chooser
  var rules: [Rule]                 // geordnet, erste passende gewinnt
  var defaultAction: Action         // wenn keine Regel passt (Standard: .prompt(.all))
}

struct Rule {
  var id: UUID; var name: String; var enabled: Bool
  var match: MatchMode              // .all | .any | .none
  var conditions: [Condition]       // leer = passt immer
  var rewrites: [Rewrite]           // nacheinander angewendet, darf leer sein
  var action: Action
}

enum Condition {
  case url(TextMatch)               // gesamte URL als String
  case host(TextMatch)              // URL.host
  case path(TextMatch)              // URL.path
  case sourceApp(bundleIdentifier: String, negated: Bool)
  case modifiers(ModifierSet, negated: Bool)   // exakter Vergleich der Menge
  case linkType(LinkType)           // .web | .file
}

struct TextMatch { var op: TextOp; var value: String; var caseSensitive: Bool = false }
enum TextOp { case equals, notEquals, contains, notContains, beginsWith, endsWith, wildcard, regex }
// wildcard: * und ? wie NSPredicate LIKE. regex: NSRegularExpression, Treffer irgendwo im String (firstMatch).

struct ModifierSet: OptionSet { command, option, control, shift }

struct Rewrite { var pattern: String; var template: String; var caseSensitive: Bool = false }
// NSRegularExpression.stringByReplacingMatches(…, withTemplate:) → $1, $2 … ; nur ersetzen, wenn pattern trifft.

enum Action {
  case open(AppRef)                 // genau diese App
  case openFirstRunning(fallback: AppRef?) // höchster laufender Eintrag aus browsers, sonst fallback, sonst browsers[0]
  case prompt(PromptScope)          // .all | .running
}
```

Codable für Enums mit assoziierten Werten: stabile, lesbare JSON-Form mit Diskriminator `type` (z. B. `{"type":"host","op":"equals","value":"github.com"}`), keine Swift-Standardsynthese.

## 5. Ablauf eines Links

1. **Annahme** (`AppDelegate.application(_:open:)`): URLs sammeln. Kontext erfassen:
   - Quell-App: `NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: keySenderPIDAttr)` → PID → `NSRunningApplication(processIdentifier:)?.bundleIdentifier`. Darf `nil` sein.
   - Modifier: `NSEvent.modifierFlags` im Moment der Annahme.
   - Linktyp: `url.isFileURL`.
   - Laufende Apps: Bundle-IDs aus `NSWorkspace.shared.runningApplications`.
2. **Entscheidung** (`RuleEngine.decide(url:context:config:) -> Decision`, rein, testbar): erste aktivierte Regel, deren Bedingungen passen. Dann Rewrites der Regel auf den URL-String anwenden. Ergebnis-URL muss per `URL(string:)` gültig sein, sonst Original-URL verwenden und Warnung in `Decision.warnings`. Keine passende Regel → `defaultAction`, ohne Rewrite.
   `Decision { originalURL, finalURL, matchedRuleID: UUID?, action: Action, warnings: [String] }`
3. **Ausführung** (App-Schicht, `Opener`): `NSWorkspace.shared.open([finalURL], withApplicationAt:configuration:)` mit `activates = true`. Schleifenschutz: Ziel ist Air Traffic selbst → stattdessen `browsers[0]`. App nicht auffindbar → Chooser mit Hinweis.
4. Mehrere URLs in einem Event: jede einzeln entscheiden.

### Rewrite-Beispiel (Pflicht-Testfall)

Regel „GitHub PR → Linear Review“:
- Bedingungen (`.all`): `host equals github.com`, `path regex ^/[^/]+/[^/]+/pull/\d+`
- Rewrite: pattern `^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)(.*)$` → template `https://linear.review/$1/$2/pull/$3$4`
- Aktion: `.open(AppRef(bundleIdentifier: "com.linear", path: "/Applications/Linear.app", displayName: "Linear"))`

Erwartung: `https://github.com/acme/webshop/pull/3776` → `https://linear.review/acme/webshop/pull/3776`; `…/pull/3776/files?w=1` → `…/pull/3776/files?w=1`; `https://github.com/acme/webshop/issues/12` → keine Regel greift.

## 6. Start- und Fensterverhalten

- Kaltstart durch einen Link: kein Einstellungsfenster. Kaltstart ohne Link (Finder/Spotlight): nach `applicationDidFinishLaunching` 0,5 s warten; kam kein Link, Einstellungen öffnen.
- `applicationShouldHandleReopen` → Einstellungen öffnen.
- Die App läuft danach im Hintergrund weiter. Die Einstellungen haben einen Button „Air Traffic beenden“.
- Erster Start ohne `config.json`: Browser automatisch erkennen (`NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!)`, Air Traffic selbst ausfiltern), `defaultAction = .prompt(.all)`, keine Regeln.

### Debug-Schalter (für Tests)

Startargument `--decide <url>` (optional zusätzlich `--source <bundleID>`): lädt die echte Konfiguration, druckt die `Decision` als JSON auf stdout, öffnet nichts und beendet sich mit Exit-Code 0. Kein Fenster.

## 7. Chooser-Fenster

- `NSPanel` (Stil: titellos, `.nonactivatingPanel` NICHT setzen, damit es Tastatureingaben bekommt), schwebend (`.floating`), erscheint zentriert auf dem Bildschirm mit dem Mauszeiger. App vorher aktivieren.
- Inhalt (SwiftUI):
  1. Kopf: Quell-App (Icon + Name), falls bekannt.
  2. **Editierbares URL-Feld**, vorbelegt mit der finalen URL (nach evtl. Rewrite). Änderungen gelten für das Öffnen.
  3. Browserliste als horizontale Reihe aus Icon + Name, Nummern 1–9. Bei `.prompt(.running)` nur laufende (falls keine läuft: alle).
  4. Fußzeile: „⌘C URL kopieren“, „Esc Abbrechen“.
- Tastatur, solange das URL-Feld **nicht** fokussiert ist: `1`–`9` öffnen direkt, ←/→ wählen, Enter öffnet die Auswahl, Esc schließt, ⌘C kopiert die URL, Tab fokussiert das URL-Feld. Im fokussierten URL-Feld: Enter öffnet mit der Auswahl, Esc verlässt das Feld.
- Klick auf ein Browser-Icon öffnet. Panel schließt nach dem Öffnen oder bei Fokusverlust.
- Modifier beim Öffnen: ⌥ gedrückt → App nicht aktivieren (`activates = false`).

## 8. Einstellungsfenster

`NSWindow` mit SwiftUI-`TabView` oder Sidebar, Größe ca. 820×560, Titel „Air Traffic“.

1. **Allgemein**
   - Status „Air Traffic ist Standardbrowser“ ja/nein (Vergleich `NSWorkspace.shared.urlForApplication(toOpen: https-URL)` mit `Bundle.main.bundleURL`).
   - Button „Als Standardbrowser festlegen“: `NSWorkspace.shared.setDefaultApplication(at:toOpenURLsWithScheme:)` für `http` und `https`, danach Status aktualisieren. macOS fragt selbst nach. **Niemals automatisch aufrufen.**
   - Standardaktion (wenn keine Regel passt).
   - Button „Aus Choosy importieren …“ (nur sichtbar, wenn Choosy-Dateien existieren) → Vorschau-Sheet: Anzahl Regeln/Browser, Liste der Regeln mit Markierung „prüfen“; „Ersetzen“ oder „Anhängen“.
   - Button „Konfigurationsordner im Finder zeigen“, Button „Air Traffic beenden“.
2. **Browser**: geordnete Liste (Icon, Name, Pfad), per Drag umsortieren, „+“ (NSOpenPanel, Ordner /Applications, nur `.app`), „−“, „Installierte Browser erkennen“.
3. **Regeln**: Liste links (Toggle aktiv, Name, Kurzbeschreibung), Drag zum Umsortieren, +/−/Duplizieren. Editor rechts:
   - Name, Match-Modus (alle/irgendeine/keine).
   - Bedingungsliste: Zeile = Feld-Picker, Operator-Picker, Wertfeld; Quell-App per Picker aus laufenden/installierten Apps; Modifier als Toggle-Gruppe.
   - **Umschreiben**: Liste aus (Muster, Vorlage), unter jeder Zeile Live-Vorschau für eine Beispiel-URL; ungültige Regex rot markiert mit Fehlermeldung.
   - Aktion: Picker (Bestimmte App / Erster laufender Browser / Auswahl zeigen: alle | laufende) + App-Picker (Browserliste + „Andere App …“ per NSOpenPanel).
4. ~~**Tester**~~ (ersetzt durch §14): Textfeld URL, optional Quell-App und Modifier; zeigt live: passende Regel (Name oder „keine – Standardaktion“), finale URL, Aktion, Warnungen. Nutzt dieselbe `RuleEngine`.

Änderungen werden sofort (debounced, 300 ms) gespeichert.

## 9. Choosy-Import (`ChoosyImporter`, AirTrafficCore)

Quellen (Pfade als Parameter, damit testbar):
- Regeln: `~/Library/Application Support/Choosy/behaviours.plist` — Array von Dicts: `title`, `enabled`, `predicate` (NSPredicate-Formatstring), `behaviour` (Int), `behaviourArgument` (Dict mit `path`, `type` oder fehlt).
- Browser: Preferences-Plist `~/Library/Preferences/com.choosyosx.Choosy.plist`, Schlüssel `browsers` → Array von Dicts mit `path`.

Abbildung:
- Prädikat per `NSPredicate(format:)` parsen und den Baum ablaufen (`NSCompoundPredicate`: and → `.all`, or → `.any`, not → `.none`; `NSComparisonPredicate` mit linkem KeyPath `URL`): `CONTAINS`→contains, `BEGINSWITH`→beginsWith, `ENDSWITH`→endsWith, `==`→equals, `!=`→notEquals, `LIKE`→wildcard, `MATCHES`→regex; Option `[c]` → caseSensitive false, sonst Choosy-Standard übernehmen (Choosy vergleicht ohne `[c]` — als `caseSensitive: false` importieren, Web-Adressen sind praktisch nie groß/klein-relevant).
- `TRUEPREDICATE` als letzte Regel → `defaultAction`, keine Regel.
- Verschachtelte Mischformen (AND in OR): auf eine Ebene abbilden, wenn möglich; sonst Regel deaktiviert importieren, Name mit Suffix „ (prüfen)“, Hinweis im Import-Bericht.
- Unbekannte Felder (sourceApp, modifierKeys, runningBrowsers, …) und Parse-Fehler: genauso deaktiviert + „(prüfen)“.
- `behaviour == 6` mit `behaviourArgument.path` → `.open(AppRef)` (Bundle-ID über `Bundle(path:)?.bundleIdentifier`, wenn möglich; Name aus Dateiname). Andere Codes → `.prompt(.all)` + Hinweis „Verhalten <n> nicht bekannt, als Auswahl importiert“.
- Ergebnis: `ImportResult { config, report: [ImportNote] }`.

Test-Fixture: **synthetische** `behaviours.plist` (keine echten Kundendomains) mit: CONTAINS, BEGINSWITH, ENDSWITH, OR aus zwei CONTAINS, AND aus zwei CONTAINS, deaktivierte Regel, eine Regel mit unbekanntem Feld, TRUEPREDICATE als letzte. Dazu eine synthetische Browser-Plist.

## 10. Abnahme

1. `swift test --package-path Packages/AirTrafficCore` grün. Mindestens: alle TextOps inkl. caseSensitive, MatchMode all/any/none, leere Bedingungen, Regelreihenfolge, deaktivierte Regel übersprungen, Standardaktion, Rewrite-Pflichtfall (§5), mehrere Rewrites hintereinander, ungültige Regex → Warnung + Original-URL, Rewrite ergibt ungültige URL → Warnung + Original, JSON-Roundtrip der Config inkl. aller Enum-Fälle, Choosy-Import der Fixture.
2. `xcodegen generate && xcodebuild -project AirTraffic.xcodeproj -scheme AirTraffic -configuration Debug -derivedDataPath build build` ohne Fehler und ohne Swift-6-Concurrency-Warnungen.
3. `"build/Build/Products/Debug/Air Traffic.app/Contents/MacOS/Air Traffic" --decide https://example.com` gibt gültiges JSON aus, Exit 0.
4. Manuell (Hauptsession mit Nutzer): Standardbrowser setzen, Choosy-Import, GitHub-PR-Link öffnet Linear mit linear.review-URL, Chooser mit URL-Bearbeitung.

## 11. Offene Punkte

- Ob die Linear-Desktop-App `https://linear.review/…`-URLs annimmt, wird manuell geprüft (Abnahme 4). Falls nicht: Ziel auf Browser umstellen oder ein Linear-Schema verwenden.
- App-Icon: 5 Varianten kommen separat; bis dahin Platzhalter im Asset-Catalog.

## 12. KI-Assistent für reguläre Ausdrücke (v1.1)

Ziel: Umschreibungen und Regex-Bedingungen in natürlicher Sprache beschreiben, die App erzeugt Muster und Vorlage über OpenRouter und prüft sie lokal, bevor sie übernommen werden.

### 12.1 Einstellungen → Allgemein, Abschnitt „KI-Assistent (OpenRouter)“
- `SecureField` API-Key. Speicherung **nur im Schlüsselbund** (Generic Password, Service `de.neoskop.AirTraffic`, Account `openrouter-api-key`), nie in `config.json`, nie im Log. Buttons „Sichern“, „Entfernen“.
- Modell: Textfeld, Standard `anthropic/claude-haiku-5.5`, gespeichert in `config.json` als `assistant.model` (optionales Feld, fehlt = Standard; ältere Configs bleiben ladbar).
- „Verbindung testen“: `GET https://openrouter.ai/api/v1/key` mit dem Key → Erfolg/Fehler anzeigen.
- Hinweis: „Beispiel-URLs und Beschreibung werden an OpenRouter gesendet.“

### 12.2 Einstiegspunkte
1. Regel-Editor, Abschnitt Umschreiben: Button „Mit KI beschreiben …“ neben „Umschreibung hinzufügen“ (neue Umschreibung) und ein ✨-Button je Umschreibungszeile (diese ersetzen/verfeinern).
2. Bedingungszeile mit Operator `regex`: ✨-Button am Wertfeld (Modus „Bedingung“: nur Muster).
Ohne gespeicherten Key: Buttons sichtbar, Klick zeigt Hinweis mit Sprung zu „Allgemein“.

### 12.3 Sheet „Regex mit KI erstellen“
- Felder: Beispiel-URLs (mehrzeilig, eine pro Zeile; vorbelegt mit der Beispiel-URL der Regel), Beschreibung (mehrzeilig), z. B. „Ersetze github.com durch linear.review, Rest bleibt gleich“.
- „Erstellen“ (⌘↩) → Anfrage. Während der Anfrage: Fortschritt, „Abbrechen“.
- Ergebnis: Muster, Vorlage (nur Modus Umschreiben), Erklärung des Modells (1–3 Sätze), Tabelle „Vorher → Nachher“ je Beispiel-URL (Modus Bedingung: „trifft / trifft nicht“). Muster und Vorlage sind editierbar; die Tabelle aktualisiert sich live.
- „Verfeinern“: Folgeanweisung eingeben, Verlauf bleibt erhalten (Multi-Turn).
- „Übernehmen“ setzt Muster/Vorlage in die Regel; nur aktiv, wenn das Muster kompiliert.

### 12.4 Ablauf und Prüfung (AirTrafficCore, testbar)
- `RegexAssistant` baut Nachrichten, ruft einen `LLMClient` (Protokoll; Implementierung `OpenRouterClient`), parst und validiert. Tests mit Fake-Client.
- Systemprompt (englisch) legt fest: Regex-Dialekt ICU/`NSRegularExpression`, Muster wird auf die **gesamte URL** angewendet, standardmäßig case-insensitive, Vorlage nutzt `$1`…`$n`, literales `$` als `\$`; Query und Fragment erhalten, wenn nicht anders verlangt; nur die beschriebenen URLs treffen; Antwort ausschließlich als JSON `{ "pattern": string, "template": string|null, "explanation": string }`.
- Anfrage: `POST https://openrouter.ai/api/v1/chat/completions`, Header `Authorization: Bearer <key>`, `X-Title: Air Traffic`, `temperature: 0`, `response_format` mit `json_schema` (strict). Antwort robust parsen: auch JSON in ```-Codeblöcken akzeptieren. Timeout 30 s.
- Lokale Prüfung nach jeder Antwort: Muster kompiliert; im Modus Umschreiben ergibt jede Beispiel-URL über `Rewriter` eine gültige URL. Schlägt das fehl → **eine** automatische Reparaturrunde mit der konkreten Fehlermeldung an das Modell; danach Ergebnis mit Warnung anzeigen.
- Fehler deutsch abbilden: 401 „API-Key ungültig“, 402 „Kein Guthaben bei OpenRouter“, 429 „Zu viele Anfragen, bitte kurz warten“, 5xx/Netzwerk/Timeout, unparsbare Antwort.
- Kein Logging von Key, Prompt-Inhalt oder URLs (`privacy: .private` bzw. gar nicht).

### 12.5 Debug-Schalter
`--suggest-regex "<Beschreibung>" --example <url> [--example <url>…] [--mode rewrite|condition]`: Key aus Umgebungsvariable `OPENROUTER_API_KEY`, sonst Schlüsselbund; druckt das validierte Ergebnis inkl. Vorher/Nachher als JSON; Exit 0 bei Erfolg, 1 bei Fehler (Meldung auf stderr).

### 12.6 Abnahme
1. Core-Tests grün, neu mindestens: Prompt-Aufbau (Beispiele + Beschreibung enthalten, Modus), JSON-Parsing inkl. Codeblock und kaputter Antwort, Validierung + Reparaturrunde (Fake liefert erst ungültiges, dann gültiges Muster), Fehlerabbildung der HTTP-Status, Request-Aufbau des `OpenRouterClient` (URLProtocol-Stub: Methode, URL, Header, Body-Felder), Config-Roundtrip mit/ohne `assistant`.
2. Build ohne Fehler/Warnungen.
3. Manuell mit Nutzer: Key eintragen, Verbindung testen, GitHub-PR→linear.review per Beschreibung erzeugen.

## 13. Feinschliff Einstellungen (v1.1)

1. **Mindestgröße Einstellungsfenster:** 820×560 pt Inhalt (`window.contentMinSize` plus `.frame(minWidth:minHeight:)` an der Root-View), damit Liste und Editor nie abgeschnitten werden. Regel-Liste fest 280 pt, Editor flexibel.
2. **Suche in Regeln:** Suchfeld über der Regel-Liste (`⌘F` fokussiert, `Esc` leert). Filtert case-insensitive über Name, Bedingungswerte, Umschreibungs-Muster und -Vorlage sowie Ziel-App-Name. Anzeige „x von y Regeln“; leeres Ergebnis: „Keine Regel passt zu „…““. Während ein Filter aktiv ist, ist Umsortieren per Drag deaktiviert; Toggle, Auswahl, Duplizieren und Löschen funktionieren weiter. Neu angelegte Regeln leeren die Suche, damit sie sichtbar sind.

## 14. Test je Regel statt Tester-Tab (v1.2)

Der Tab „Tester“ entfällt (`TesterView.swift`, `SettingsTab.tester` entfernen). Das Testen wandert in den Regel-Editor.

### 14.1 Datenmodell
- `Rule.testURL: String?` (optional, abwärtskompatibel: fehlt = nil, wird bei nil nicht geschrieben). Ersetzt das flüchtige `AppModel.sampleURLs`; Duplizieren übernimmt die Test-URL. Der KI-Assistent nutzt `testURL` als Vorbelegung seiner Beispiel-URLs (bisher `sampleURLs`).
- Choosy-Import setzt keine Test-URL.

### 14.2 Abschnitt „Test“ im Regel-Editor
Ganz oben im Editor (unter Name/Match-Modus), ersetzt das bisherige Feld „Beispiel-URL“ im Abschnitt Umschreiben:
- Textfeld „Test-URL“ (Platzhalter `https://…`), optional Quell-App-Picker und Modifier-Toggles (eingeklappt in „Weitere Bedingungen simulieren“, Standard: keine Quell-App, keine Modifier).
- Ergebnis live, mit derselben `RuleEngine`:
  1. **Treffer-Status:** „✓ Regel trifft“ / „✗ Regel trifft nicht“ (auch für deaktivierte Regeln auswerten, mit Zusatz „– Regel ist deaktiviert“).
  2. **Je Bedingungszeile** ein kleines ✓/✗-Symbol am Zeilenende (`RuleEngine.evaluate`), damit sichtbar ist, welche Bedingung scheitert. Nur wenn eine Test-URL gesetzt und gültig ist.
  3. **Je Umschreibungszeile** das Zwischenergebnis (wie bisher die Live-Vorschau), am Ende „Ergebnis-URL“ (fett, selektierbar) und die Aktion in Worten („Öffnen mit Linear“).
  4. **Vorrang-Hinweis:** Greift für diese Test-URL eine **frühere aktivierte** Regel zuerst (`RuleEngine.decide` mit voller Config), Hinweis in Orange: „Achtung: Die Regel „X“ weiter oben greift zuerst – diese Regel wird für diese URL nie erreicht.“ mit Button „Zeigen“ (wählt Regel X in der Liste aus).
  5. Warnungen der Engine (ungültige Regex, ungültige Ergebnis-URL) in Rot.
- Ungültige Test-URL: dezenter Hinweis „Keine gültige URL“, keine ✓/✗-Symbole.

### 14.3 Core
- Neue reine Funktion `RuleEngine.test(rule:url:context:config:) -> RuleTestResult` mit: `matches: Bool`, `conditionResults: [Bool]`, `rewriteSteps: [String]` (Zwischenergebnisse), `finalURL: URL`, `warnings: [String]`, `shadowedBy: UUID?` (erste frühere aktivierte Regel, die trifft; nil, wenn keine oder die Regel selbst nicht in der Config ist). Wertet `rule` unabhängig von `enabled` aus.
- Tests: trifft/trifft nicht, Bedingungsergebnisse je Zeile, Zwischenschritte bei 2 Umschreibungen, Vorrang durch frühere Regel, frühere **deaktivierte** Regel zählt nicht, deaktivierte Regel selbst wird trotzdem ausgewertet, Config-Roundtrip mit/ohne `testURL`.

## 15. Redesign (v1.3)

Ziel: Optik deutlich hochwertiger, weiterhin nativ. **Funktionsumfang bleibt exakt gleich** – jede bestehende Bedienmöglichkeit muss erhalten bleiben (Tastatur, Menüs, Sheets, Alerts, Fehlermeldungen). Referenz-Mockups: `Design/Redesign/redesign-light.png` und `redesign-dark.png` (6 Ansichten). Begründungen: `Design/Redesign/*.md`. Die Mockups sind HTML-Annäherungen; wo Systemkomponenten dasselbe leisten, gehen Systemkomponenten vor.

### 15.1 Gestaltungssystem (`App/Sources/Settings/DesignSystem.swift`, neu)
- **Farben (Asset-Katalog):**
  - `AccentColor` (Flächen: Auswahl, Primärknöpfe, Schalter): hell #24685C, dunkel #237A68 (weißer Text ≥ 4,5:1). Greift bei Systemakzent „Mehrfarbig“, sonst gilt der Systemakzent.
  - `Brand` (Text und Symbole in Markenfarbe: Stufensymbole, Abschnittskacheln, KI-Funken, Textknöpfe): hell #24685C, dunkel #83DAC4.
  - `StatusGreen` hell #1A7431 / dunkel #30D158; `StatusOrange` hell #A84300 / dunkel #FFB340; `StatusRed` hell #C00013 / dunkel #FF7B73. Getönte Flächen dazu mit 15 % Deckkraft.
  - Sonst nur semantische Systemfarben (`.primary`, `.secondary`, `.separator`, `controlBackgroundColor`, `windowBackgroundColor`). Kein Text unter 4,5:1, auch nicht in Auswahlzeilen (dort Weiß, Chips mit abdunkelnder Überlagerung).
- **Typo:** Systemschrift; Titel 20 semibold, Kartentitel 13 semibold, Inhalt 13, Hilfstexte 11–12 `.secondary`; Monospace (12) nur für URLs und Regex.
- **Abstände:** 4/8/12/20; Kartenradius 12, Felder 6, Pills 11.
- **Komponenten (wiederverwendbar):** `StatusPill(kind: .ok/.neutral/.warning/.error, text, symbol)`, `Keycap(text)`, `Chip(text)`, `StageCard(symbol, title, subtitle, trailing, content)`, `PipelineNode(state: .passed/.failed/.idle/.neutral(n))`, `SectionHeader(symbol, title, subtitle)` mit 20-pt-Kachel in `Brand` 15 %, `AaToggle` (eingeschaltet sichtbar: getönter Hintergrund + Akzent, `accessibilityValue` an/aus).
- **Barrierefreiheit:** Jede Ikonen-Schaltfläche hat `help` + `accessibilityLabel`. Status nie nur über Farbe (immer Symbol + Text). `accessibilityReduceMotion` → nur Opazität; `accessibilityReduceTransparency` → deckende Flächen statt Glas/Material.

### 15.2 Einstellungsfenster
- **Toolbar-Tabs:** `NSTabViewController` mit `tabStyle = .toolbar`, drei Einträge mit SF Symbols: Allgemein `gearshape`, Browser `globe`, Regeln `point.topleft.down.to.point.bottomright.curvepath`. Fenstertitel = Tab-Name. `model.settingsTab` bleibt die Quelle (z. B. Alert „Zu ‚Allgemein‘“ wechselt den Tab), Frame-Autosave bleibt. Mindestgröße Inhalt 820×560 (ohne Toolbar) bleibt.
- Allgemein und Browser: Inhalt zentriert, max. 600 pt breit, scrollt. Regeln: volle Breite.

### 15.3 Regel-Liste
- Seitenleisten-Optik (`.sidebar`-Liste oder gleichwertig), Breite 272. Suchfeld oben im Stil eines Suchfelds (Lupe, Platzhalter „Regeln durchsuchen“, Keycap `⌘F`; mit Text: Keycap `esc`). Verhalten wie §13.2.
- **Zeile:** Checkbox (aktiv) · Ziel-Icon 20 (Aktion „App öffnen“: App-Icon; „Erster laufender“: Ersatz-App-Icon oder Symbol `safari`; „Auswahl“: Symbol `square.grid.2x2`) · Name 13 semibold · rechts Positionsnummer (1-basiert in der Gesamtliste, auch beim Filtern) · darunter einzeilig Chips: bis zu 2 Bedingungen („Host *ist* github.com“), „↻ umschreiben“ wenn Umschreibungen existieren, „Aus“ (umrandet) wenn deaktiviert, „+n“ bei mehr. Deaktiviert: Name `.secondary`, **keine** Abblendung der Zeile.
- Fußleiste: + / − / Duplizieren (wie bisher) und rechts „24 Regeln · oben gewinnt“ bzw. beim Filtern „Sortieren nur ohne Filter“; „x von y Regeln“ unter dem Suchfeld beim Filtern.

### 15.4 Regel-Editor
Scrollender Inhalt + fest unten angedockte Testleiste (`safeAreaInset(edge: .bottom)`).
- **Kopf:** Ziel-Icon 40 · Name als Inline-`TextField` (Titel 20 semibold, feiner Rahmen/Hintergrund bei Hover und Fokus) · darunter „Regel n von N“ (+ „ · wird als erste geprüft“ bei n = 1) · rechts „Aktiv“ als Switch.
- **Pipeline:** drei `StageCard`s untereinander, links eine 2-pt-Schiene mit `PipelineNode` je Stufe. Mit gültiger Test-URL: Wenn ✓ (grün) bei Treffer, sonst ✗ (grau); Umschreiben ✓ bei Treffer und ≥ 1 Schritt, sonst idle (–); Öffnen ✓ bei Treffer. Ohne Test-URL: neutrale Knoten 1/2/3. Schiene grün bis zur letzten erreichten Stufe, danach Separator-Farbe.
  1. **Wenn** (`line.3.horizontal.decrease`): Kopf „Wenn · diese Bedingungen zutreffen:“, rechts segmentierter Picker alle / eine / keine (= MatchMode). Bedingungen **zweizeilig**: Zeile 1 Feld-Picker + Operator-Picker + rechts ✓/✗-Status; Zeile 2 Wert in voller Breite (Textfeld mono bzw. Quell-App-Feld mit Icon + Name + Bundle-ID / Modifier-Toggles / Linktyp-Picker), rechts `AaToggle` (bei allen Text-Bedingungen inkl. Regex), ✦ KI (nur Regex), − Entfernen. „+ Bedingung“ als Textknopf in `Brand`. Leer: „Ohne Bedingungen passt die Regel immer.“
  2. **Umschreiben** (`wand.and.rays`): Untertitel „1 Schritt“ / „n Schritte, nacheinander“ / „keine – URL bleibt unverändert“; rechts Knopf „Neue mit KI …“ (`sparkles`). Je Schritt (ab 2 Schritten mit Kopf „① Schritt n“): Zeile „Muster“ (Label 52 pt, Feld mono, `AaToggle`, ✦ „Diesen Schritt mit KI verfeinern“, −), Zeile „Vorlage“. Darunter, wenn die Test-URL trifft: **Gruppen-Legende** „Gruppen: $1 = … $2 = …“ (Token farbig: blau, lila, pink, teal, zyklisch) und **Ergebnisblock** (getönte Fläche, mono, umbrechend, auswählbar): Eingabe sekundär, „→ Ausgabe“ primär, geänderter Mittelteil (gemeinsames Präfix/Suffix abgezogen) grün hinterlegt – Ein- und Ausgabe immer **vollständig**. „+ Umschreibung“ als Textknopf. Bisheriger Hilfetext zu $1, $2 als Fußnote der Karte.
  3. **Öffnen** (`arrow.up.forward.app`): rechts im Kartenkopf der Aktions-Editor kompakt (Aktions-Picker + App-Menü mit Icon; „Erster laufender“ mit Ersatz-App; „Auswahl“ alle/laufende).
- **Testleiste** (Hintergrund Fensterfarbe, Trennlinie oben):
  - Zeile 1 (fix): „Test“ (`flask`) · Test-URL-Feld mono · Knopf „Simulieren …“ → Popover mit Quell-App und Modifiern (Knopf zeigt einen Punkt, wenn eine Simulation aktiv ist).
  - Darunter ein Ergebnisbereich, der höchstens 40 % der Editorhöhe einnimmt und darüber hinaus **scrollt** (Zeile 1 und alle Knöpfe bleiben erreichbar):
    - Treffer: Pill ✓ „Trifft“ (bzw. „Diese Regel trifft“, wenn eine Vorrang-Warnung folgt) + „öffnet ‹volle Ergebnis-URL, mono, umbrechend, auswählbar› in ‹App›“ (bzw. Aktion in Worten).
    - Kein Treffer: Pill ✗ „Trifft nicht · Bedingung n (Feld) nicht erfüllt“ (neutral grau; bei MatchMode ≠ alle nur „Trifft nicht“).
    - Deaktiviert: zusätzliche Pill „Regel ist aus – Test läuft trotzdem“. Leer: „Test-URL eingeben, um die Regel zu prüfen“. Ungültig: „Keine gültige URL“.
    - Vorrang: orange getönte Zeile mit Warnsymbol, vollständiger Text „Bei einem echten Klick greift zuerst „X“ (Regel n) und ‹Aktion›. Diese Regel wird für diese URL nie erreicht.“ + Knopf „Regel n zeigen“ (Verhalten wie §14.2).
    - Engine-Warnungen: rot getönte Zeilen mit vollem Text.
- Alert „Kein API-Key …“ und Sheet-Einstieg bleiben unverändert.

### 15.5 Auswahlfenster (Chooser)
- **Material:** Panel transparent (`isOpaque = false`, `backgroundColor = .clear`, Schatten an); Inhalt mit Radius 22: ab macOS 26 `glassEffect(.regular, in: .rect(cornerRadius: 22))`, darunter `.regularMaterial`; bei „Transparenz reduzieren“ deckend `windowBackgroundColor`. Innenabstand 16/20/14.
- **Kopf:** Quell-App-Icon 16 + „von ‹App›“ (12, sekundär); Hinweis (hint) wie bisher orange.
- **URL-Zeile** (36 hoch, Radius 10, leicht getönt): unfokussiert strukturiert – Schloss-Symbol bei https, **Host halbfett**, Rest sekundär; gekürzt wird im Pfad, der Host bleibt sichtbar. Tab oder Klick → dasselbe vollständige NSTextField (mono) an gleicher Stelle, fokussiert. Enter/Esc/⌘C/Tab exakt wie bisher.
- **Kacheln** 96 × 100, Radius 12, Abstand 8: Icon 44, Name 12 (max. 2 Zeilen), `Keycap` 1–9 oben rechts, Punkt unten (App läuft, `Apps.isRunning`). Fehlende App (`Apps.url(for:) == nil`): Icon grau + 55 %, ⚠ oben links. Auswahl: 12 % Akzentfläche + 2-pt-Akzentkontur innen, **kein** Skalieren; Wechsel 90 ms. Hover wählt wie bisher. VoiceOver: „‹Name›, Taste n[, läuft][, nicht gefunden]“, ausgewählt-Trait.
- **Fußzeile** (Trennlinie oben, 11 sekundär) mit Keycaps: `⏎` Öffnen · `⌥⏎` im Hintergrund · `⇥` URL bearbeiten · `⌘C` kopieren · rechts `esc` Abbrechen.
- **Breite:** `min(max(n × 104 + 40, 520), 900)`, zusätzlich ≤ sichtbare Bildschirmbreite − 80; Überlauf scrollt horizontal, Tastaturauswahl wird sichtbar gehalten.
- **Erscheinen:** 120 ms Opazität + Skalierung 0,985 → 1 (ohne Überschwingen); Bewegung reduziert → nur Opazität.

### 15.6 Allgemein
- Optional oben: `model.problem` als orange Hinweiszeile.
- **Status-Karte:** App-Icon 52 · „Air Traffic ist dein Standardbrowser“ + „Jeder Link läuft durch N Regeln. Ohne Treffer: ‹Standardaktion in Worten›.“ · rechts Pill ✓ „Standardbrowser“ + Textknopf „Status prüfen“. Sonst: „Air Traffic ist nicht Standardbrowser“ + „Links öffnen direkt im bisherigen Browser – Regeln greifen nicht.“ + Primärknopf „Als Standardbrowser festlegen“. Fehlertext darunter rot.
- Abschnitte mit `SectionHeader`, Inhalt in gruppierten Karten:
  - „Wenn keine Regel passt“ (`arrow.right`): Aktions-Editor.
  - „KI-Assistent · über OpenRouter“ (`sparkles`): API-Key (SecureField + „Sichern“ (ohne Eingabe deaktiviert) + „Entfernen“), Status-Pill „Key im Schlüsselbund“ / „Kein Key gespeichert“; Modell (Feld mono) + „Verbindung testen“ + Fortschritt + Ergebnis-Pill; Fußnote „Beispiel-URLs und Beschreibung werden an OpenRouter gesendet. Der Key liegt nur im Schlüsselbund.“
  - „Import & Konfiguration“ (`square.and.arrow.down`): Choosy-Import (nur wenn verfügbar, Import-Vorschau-Sheet unverändert), Datei-Pfad (mono, Mitte gekürzt) + „Im Finder zeigen“, „Air Traffic beenden“.

### 15.7 Browser
- Oben Vorschau-Box „Vorschau Auswahlfenster · Taste = Nummer“: dieselbe Kachel-Komponente wie der Chooser (verkleinert 72 × 72, Icon 32), aus **derselben** Liste, ohne Auswahl, fehlende Apps markiert.
- Liste (Karte): Keycap-Nummer · Icon 32 · Name + Pfad (sekundär, Mitte gekürzt) · Pill „nicht gefunden“ (orange) · Ziehen zum Sortieren · native Zeilenauswahl. Kopf „Reihenfolge“ + Textknopf „Installierte Browser erkennen“. Darunter + / − (− nur mit Auswahl) und Hinweis „Ziehen zum Sortieren · oben = Taste 1“.

### 15.8 KI-Sheet
- 640 breit, max. 620 hoch; **Kopf und Fußleiste fest, Inhalt scrollt.**
- Kopf: 34-pt-Kachel in `Brand` mit `sparkles` · „Regex mit KI erstellen“ · darunter Kontext · Modell.
- Inhalt: „Beispiel-URLs · eine pro Zeile“ (TextEditor mono, Radius 8), „Beschreibung“ (TextEditor), rechts Keycap `⌘⏎` + „Erstellen“/„Neu erstellen“; beim Laden Fortschritt + „Frage das Modell …“ + „Abbrechen“; Fehler als rote Zeile. „Ergebnis“-Karte: Muster/Vorlage editierbar (Label 52 pt, mono), Erklärung, Pill „einmal automatisch nachgebessert“ (`wrench.adjustable`), Reparatur-Warnung, Probleme/Hinweise, je Beispiel ✓/✗ mit vollständigem Vorher → Nachher bzw. „trifft nicht – bleibt unverändert“. „Verfeinern“: Feld + Knopf.
- Fußleiste: links Datenschutzhinweis (11, sekundär), rechts „Abbrechen“ (esc) und „Übernehmen“ (Standard, ⏎).

### 15.9 Debug-Schalter `--snapshot <dir>`
Rendert ohne Nutzerinteraktion PNGs nach `<dir>` und beendet sich: Chooser (Beispiel-Request mit Quell-App, ≥ 4 Browser), Einstellungen Allgemein, Browser, Regeln (erste Regel mit Test-URL ausgewählt; außerdem eine Regel mit Vorrang-Warnung, falls vorhanden) – je hell und dunkel (`NSAppearance` setzen), Regeln zusätzlich bei 820 × 560. Rendern über `cacheDisplay(in:to:)` offscreen; kein Screen-Recording nötig. Nutzt die normale Config bzw. `AIRTRAFFIC_CONFIG_PATH`. Schreibt nichts in die Config.

### 15.10 Abnahme
- Build ohne Warnungen, alle Tests grün; Core unverändert (oder nur ergänzt, dann mit Tests).
- Alle bisherigen Bedienwege funktionieren (Checkliste: §7, §8, §12, §13, §14).
- `--snapshot` erzeugt alle Bilder; Optik entspricht den Mockups in hell und dunkel.

## 16. KI-Anbieter: OpenRouter, Claude-Abo, ChatGPT-Abo (v1.4)

Neben OpenRouter kann der KI-Assistent (§12) ein bestehendes Abo über die **lokal installierte CLI** nutzen. Ablauf, Prüfung und Reparaturrunde (§12.4) bleiben gleich; nur der Transport wechselt.

### 16.1 Datenmodell (Core)
- `AssistantSettings.provider: AssistantProvider?` mit `openRouter | claudeCLI | codexCLI`; fehlt = `openRouter` (abwärtskompatibel, nil wird nicht geschrieben).
- Modell je Anbieter getrennt speichern (`model` bleibt OpenRouter; neu `claudeModel: String?`, Standard `haiku`; `codexModel: String?`, leer = Standard der CLI). Optional `claudePath`/`codexPath` (leer = automatisch suchen).

### 16.2 CLI-Clients (Core, `LLMClient`-konform, testbar über einen `ProcessRunner`-Protokoll-Fake)
- **Claude Code:** `claude -p --output-format json --json-schema '<Schema>' --model <claudeModel> --system-prompt '<System>' --tools "" --no-session-persistence --strict-mcp-config` (kein `--bare`, sonst greift das Abo-Login nicht), Prompt über stdin, Arbeitsverzeichnis = leeres Temp-Verzeichnis. Antwort aus dem JSON-Ergebnis (strukturiertes Feld bzw. `result`) lesen.
- **Codex:** `codex exec --ephemeral --skip-git-repo-check -s read-only -C <TempDir> --output-schema <Datei> -o <Datei> -c model_reasoning_effort="low" [-m <codexModel>] -` mit Prompt (System + Nutzer) über stdin; Antwort = Inhalt von `-o`.
- Exakte Flags gegen die installierten Versionen prüfen (`claude --help`, `codex exec --help`) und dokumentieren.
- **Binärsuche:** konfigurierter Pfad → `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/.claude/local`, `~/.npm-global/bin`, `~/.bun/bin` → Login-Shell (`$SHELL -lc 'command -v …'`, Timeout 3 s). Prozess-`PATH` = PATH der Login-Shell (CLIs brauchen u. a. `node`).
- Timeout 90 s, abbrechbar (Prozess beenden), keine Ausgabe in Logs außer Fehlerklasse. Exit-Code ≠ 0 oder unlesbare Antwort → verständlicher Fehler (z. B. „Claude Code ist nicht angemeldet – im Terminal `claude` starten und anmelden.“).
- Tests: Argumente je Anbieter, Parsen beider Antwortformate, Fehler-/Timeout-Pfade, Binärsuche mit Fake-Dateisystem.

### 16.3 Einstellungen → Allgemein → „KI-Assistent“
- **Hinweis oben im Abschnitt (immer sichtbar):** „Wofür? Der KI-Assistent schlägt reguläre Ausdrücke für Bedingungen und Umschreibungen vor – nur, wenn du im Regel-Editor auf ✦ klickst. Gesendet werden dann nur deine Beschreibung und die Beispiel-URLs, nie automatisch.“
- Picker „Anbieter“: „OpenRouter (API-Key)“ · „Claude-Abo (Claude Code)“ · „ChatGPT-Abo (Codex)“.
- OpenRouter: wie bisher (Key, Modell, Verbindung testen).
- Claude/Codex: Status-Pill „Gefunden · ‹Pfad› · ‹Version›“ bzw. „Nicht gefunden“ + Hinweis zur Installation; Feld Modell (Platzhalter = Standard); optional „Pfad …“ (Datei wählen); „Verbindung testen“ = Mini-Anfrage (kurzes JSON-Echo) mit Ergebnis-Pill. Fußnote: „Nutzt dein bestehendes Abo über die installierte CLI; es fallen keine API-Kosten an.“
- Untertitel des Abschnitts zeigt den aktiven Anbieter.

### 16.4 Verfügbarkeit im Editor
- `hasAssistantKey` → `assistantAvailable` (OpenRouter: Key vorhanden; CLI: Binärdatei gefunden). Alert ohne Verfügbarkeit nennt den aktiven Anbieter und führt zu „Allgemein“.
- KI-Sheet: Untertitel „Anbieter · Modell“; Datenschutzhinweis in der Fußleiste nennt den Anbieter.
- `--suggest-regex` bekommt `--provider openrouter|claude|codex`.

## 17. Updates mit Sparkle (v1.4)

- **Sparkle 2** (SPM `https://github.com/sparkle-project/Sparkle`, Version 2.10.1) per `project.yml`; Framework eingebettet und signiert.
- **Info.plist:** `SUFeedURL` = `https://raw.githubusercontent.com/neobarthold/air-traffic/main/appcast.xml`, `SUPublicEDKey` = `DSww7ffzyGB8yGYAsBnxmn2URLUZMKkIRNx5xj+GkbI=`, `SUEnableAutomaticChecks` = YES, `SUScheduledCheckInterval` = 86400, `SUAutomaticallyUpdate` = YES, `SUAllowsAutomaticUpdates` = YES. Kein Sandbox, keine XPC-Dienste nötig.
- **Updater:** `SPUStandardUpdaterController` im AppDelegate. Weil die App selten beendet wird: im `SPUUpdaterDelegate` bei `willInstallUpdateOnQuit` sofort installieren und neu starten, **sobald kein Chooser und kein Einstellungsfenster offen ist** (sonst beim nächsten Schließen). `SPUStandardUserDriverDelegate.supportsGentleScheduledUpdateReminders = true`.
- **Bedienung:** Menü „Air Traffic → Nach Updates suchen …“ (Hauptmenü, solange Einstellungen offen). In Allgemein neuer Abschnitt „Updates“ (`arrow.triangle.2.circlepath`): Version (Marketing + Build), Toggle „Täglich nach Updates suchen“ (= `automaticallyChecksForUpdates`), Toggle „Updates automatisch installieren“ (= `automaticallyDownloadsUpdates`), Knopf „Jetzt suchen“, „Zuletzt geprüft: …“.
- **Versionen:** `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml`; Build-Nummer steigt mit jedem Release.
- **Release-Skript `scripts/release.sh <version>`:** Versionen setzen (Build +1), `xcodegen generate`, Release-Build, `ditto -c -k --keepParent` → `Air-Traffic-<version>.zip`, Sparkle-`sign_update --account air-traffic` (Werkzeuge werden bei Bedarf aus dem offiziellen Sparkle-Release 2.10.1 nach `build/sparkle-tools` geladen), `appcast.xml` im Repo-Root ergänzen (neuester Eintrag oben, `sparkle:version`, `sparkle:shortVersionString`, `sparkle:edSignature`, `length`, `minimumSystemVersion` 15.0, Download-URL `https://github.com/neobarthold/air-traffic/releases/download/v<version>/Air-Traffic-<version>.zip`, Release-Notes aus `--notes` bzw. CHANGELOG-Abschnitt), `gh release create v<version>` mit ZIP. Commit/Push macht das Skript **nicht**; es druckt die nächsten Befehle. `--dry-run` baut und signiert nur.
- Updates werden zusätzlich über die EdDSA-Signatur geprüft (auch beim Wechsel von ad hoc 1.4 auf Developer ID 1.5).

## 18. README und Demo-Daten
- `README.md` (Deutsch): Was ist Air Traffic, Funktionen (Regeln, Umschreiben, Test je Regel, KI-Assistent mit drei Anbietern, Choosy-Import, Updates), Screenshots, Installation (Release-ZIP, Hinweis Gatekeeper bei Ad-hoc-Signatur: Rechtsklick → Öffnen), Bauen aus dem Quellcode (XcodeGen, Xcode 27), Tests, Debug-Schalter, Release-Ablauf, Datenschutz (Key nur im Schlüsselbund, KI nur auf Klick), Lizenz-Hinweis („Alle Rechte vorbehalten“, sofern nicht anders festgelegt).
- `docs/demo-config.json`: neutrale Beispiel-Config (acme/example-Domains, keine echten Kunden), ≥ 6 Regeln inkl. Umschreibung, Vorrang-Fall und deaktivierter Regel.
- `scripts/screenshots.sh`: `--snapshot` mit `AIRTRAFFIC_CONFIG_PATH=docs/demo-config.json` nach `docs/images/`; README bindet `docs/images/*-light.png` ein.

## 19. Developer-ID-Signatur und Notarisierung (v1.5)
- `scripts/release.sh` signiert nach dem Build von innen nach außen mit `Developer ID Application: Neoskop GmbH (PVW9KTQ7MR)` (SHA-1 `EF3BF4DE…7186D2`, überschreibbar per `DEVELOPER_ID`): Sparkle-XPC-Dienste, `Autoupdate`, `Updater.app`, `Sparkle.framework`, App – jeweils `--options runtime --timestamp`.
- Notarisierung mit `xcrun notarytool submit --keychain-profile air-traffic --wait`, danach `stapler staple` und Prüfung `spctl` („Notarized Developer ID“); erst dann ZIP und Sparkle-Signatur.
- Zugangsdaten: notarytool-Profil `air-traffic` im Schlüsselbund (App-spezifisches Passwort), nie im Repo.
- Zertifikat läuft am 1. 2. 2027 ab – vorher erneuern (Neoskop Account Holder/Admin). Bestehende Releases bleiben gültig.

## 20. Safari-Erweiterung, Stufe 1 (v1.6)

Links, die in Safari angeklickt werden, gehen nicht über den Standardbrowser. Die Erweiterung gibt sie gezielt an Air Traffic. **Nur Safari**; Chrome und automatisches Umleiten sind spätere Stufen.

### 20.1 URL-Schema `airtraffic://`
- `CFBundleURLTypes` um Schema `airtraffic` ergänzen (Rolle Viewer).
- `airtraffic://open?url=<prozentkodiert>[&source=<bundleID>][&prompt=1]`:
  - `url` muss http/https sein, sonst ignorieren + Log.
  - `source` überschreibt die Quell-App für Regeln (Erweiterung sendet `com.apple.Safari`); fehlt sie, gilt die Absender-PID wie bisher.
  - ohne `prompt`: normaler Ablauf (§5: Regeln → Umschreiben → Aktion). Mit `prompt=1`: Umschreibungen der passenden Regel anwenden, dann **immer** das Auswahlfenster (alle Browser).
- Andere Hosts/Pfade unter `airtraffic://` ignorieren. Parsen als reine Funktion im Core (`AirTrafficURL.parse`) mit Tests (Kodierung, fehlende/ungültige `url`, `javascript:`/`file:` abweisen, `prompt`, `source`).
- Schleifenschutz (Opener) gilt weiter; Air Traffic öffnet `airtraffic://` nie selbst.

### 20.2 Safari-Web-Extension (neues Target `SafariExtension`, Typ `app-extension`, eingebettet unter `Contents/PlugIns`)
- Bundle-ID `de.neoskop.AirTraffic.SafariExtension`, Anzeigename „Air Traffic“, Manifest V3, Icons aus dem App-Icon (16/32/48/96/128, Toolbar-Symbol als einfarbige Vorlage).
- **Rechtsklick auf einen Link:** „Mit Air Traffic öffnen“ und „Mit Air Traffic auswählen …“ (`prompt=1`). **Symbolleisten-Knopf:** öffnet die aktuelle Seite mit Air Traffic (Klick) – kein Popup.
- Übergabe per `browser.runtime.sendNativeMessage` an `SafariWebExtensionHandler` (in der Erweiterung), der die `airtraffic://`-URL mit `NSWorkspace.shared.open` öffnet – so erscheint keine Safari-Rückfrage. Erweiterung minimal berechtigt (`contextMenus`, `activeTab`, `nativeMessaging`), keine Host-Berechtigungen, kein Content-Script.
- Entitlements der Erweiterung: `com.apple.security.app-sandbox` = YES (Pflicht für Safari-Erweiterungen); sonst nichts.
- Die App bleibt ohne Sandbox.

### 20.3 Einstellungen → Allgemein → neuer Abschnitt „Safari-Erweiterung“ (`safari`)
- Status per `SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier:)`: Pill „Aktiv“ / „Nicht aktiviert“ / „Unbekannt“; Aktualisierung beim Öffnen und bei App-Aktivierung.
- Knopf „In Safari aktivieren …“ → `SFSafariApplication.showPreferencesForExtension(withIdentifier:)`.
- Kurzer Text: „Links, die du in Safari anklickst, gehen nicht über den Standardbrowser. Mit der Erweiterung schickst du sie per Rechtsklick oder Symbolleisten-Knopf an Air Traffic – dann greifen deine Regeln.“
- `--snapshot` zeigt den Abschnitt.

### 20.4 Release und Signatur
- `scripts/release.sh` signiert die Erweiterung **vor** der App: `codesign --force --options runtime --timestamp --entitlements <Erweiterungs-Entitlements> --sign $DEVELOPER_ID …/Contents/PlugIns/SafariExtension.appex`; Prüfung, dass die appex eingebettet und signiert ist (`codesign -d --entitlements` enthält app-sandbox).
- Debug-Builds bleiben ad hoc; Safari lädt die Erweiterung dann nur mit „Entwickler → Nicht signierte Erweiterungen erlauben“ (README-Hinweis für Entwickler).

### 20.5 README
- Abschnitt „Safari-Erweiterung“: Zweck, Aktivieren (Air Traffic → Allgemein → „In Safari aktivieren …“ bzw. Safari → Einstellungen → Erweiterungen), Bedienung.

## 21. Safari-Erweiterung: eigenes Verhalten, Vollbild, Umlaute (v1.7)

### 21.1 Umlaute im Kontextmenü (erledigt)
Safari liest `background.js` nicht als UTF-8 („Ã¶ffnen“). Strings im Erweiterungs-Code enthalten nur ASCII; Umlaute und „…“ als `\uXXXX`. Test: ein Unit-/Skript-Check, dass `SafariExtension/Resources/*.js` in String-Literalen nur ASCII enthält.

### 21.2 Eigenes Verhalten für Links aus der Erweiterung
- Config (Core, optional, abwärtskompatibel): `extensionSettings: ExtensionSettings?` mit
  - `applyRules: Bool` (Standard `true`) – Regeln (Bedingungen + Umschreibungen) wie beim Standardbrowser anwenden;
  - `fallbackAction: Action?` – Aktion, wenn keine Regel passt bzw. wenn `applyRules == false`; `nil` = „Wie unter ‚Wenn keine Regel passt‘“ (globale Standardaktion).
- Gilt für „Mit Air Traffic öffnen“ und den Symbolleisten-Knopf. „Mit Air Traffic auswählen …“ (`prompt=1`) zeigt weiterhin immer die Auswahl.
- `AirTrafficURL.decide` berücksichtigt die Einstellungen (reine Funktion, Tests: Regeln an/aus, eigene Fallback-Aktion, nil = global, prompt unverändert).
- Einstellungen → Allgemein → „Safari-Erweiterung“: Toggle „Regeln anwenden“; darunter „Wenn keine Regel passt“ bzw. (Regeln aus) „Links aus Safari“: Picker „Wie Standardaktion“ / eigene Aktion (bestehender Aktions-Editor). Kurzer Hilfetext. `--snapshot` zeigt den Abschnitt.

### 21.3 Auswahlfenster über Vollbild-Apps
Problem: Ist Safari (oder ein anderer Browser) im Vollbild, erscheint das Auswahlfenster im Desktop-Space statt über dem Vollbild-Fenster.
- Panel muss im **aktuell aktiven Space** erscheinen, auch über Vollbild-Apps: `styleMask` mit `.nonactivatingPanel`, `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]` (bzw. `.moveToActiveSpace` + `.fullScreenAuxiliary`, je nachdem, was nachweislich funktioniert), Level über Vollbild-Fenstern (z. B. `.popUpMenu` oder `.modalPanel`). Kein Space-Wechsel durch `NSApp.activate()` vor dem Anzeigen – erst Panel zeigen und Key machen.
- Tastatur (1–9, Pfeile, ⏎, ⌥⏎, ⇥, ⌘C, esc) muss weiter funktionieren, auch wenn Air Traffic nicht aktive App ist (nicht aktivierendes Panel wird trotzdem Key). Fokusverlust schließt das Panel wie bisher; Fenster der Einstellungen bleiben unberührt.
- Nach dem Öffnen eines Browsers: Fokus geht an den Ziel-Browser; bei Abbruch (esc) zurück an die vorherige App, ohne Space-Wechsel.
- Gilt für alle Wege ins Auswahlfenster (Standardbrowser-Links, Erweiterung).
- Verifikation: Testfenster einer Hilfs-App (z. B. ein per Skript gestartetes Vollbild-Fenster) ist optional; mindestens per Code-Review und Log, dass Panel-Space = aktiver Space. Der Nutzer testet mit Safari im Vollbild.
