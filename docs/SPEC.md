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

## 22. URL prüfen: welche Regeln greifen? (v1.8)

Ziel: Im Tab „Regeln“ eine beliebige URL eingeben und sofort sehen, welche Regeln für sie zutreffen, welche davon bei einem echten Klick greift und was dann passiert. Ergänzt den Test je Regel (§14): der beantwortet „trifft diese Regel?“, §22 beantwortet „was passiert mit dieser URL?“ und „warum greift meine Regel nicht?“.

### 22.1 Einstieg: Suchfeld der Regel-Liste
- Platzhalter wird „Regeln durchsuchen oder URL prüfen“.
- Ist der (getrimmte) Inhalt eine vollständige URL, schaltet die Seitenleiste in den **Prüfmodus**; sonst bleibt es die Textsuche aus §13.2. Erkennung (Core, `RuleCheck.url(from:)`): keine Leerzeichen, `URL(string:)` gültig, Schema vorhanden und entweder `http`/`https` mit Host, `file`, oder beliebiges Schema mit `://` und Host. Ohne Schema (z. B. `github.com/acme`) bleibt es Textsuche.
- Im Prüfmodus unter dem Suchfeld ein Umschalter „Als Text suchen“ (Textknopf). Er erzwingt für diesen Inhalt die Textsuche, bis sich der Inhalt ändert; dann steht dort „Als URL prüfen“.
- esc/Leeren verlässt den Modus wie bisher.

### 22.2 Ergebniskarte (Seitenleiste, unter dem Suchfeld)
Kompakte Karte (Radius 8, getönte Fläche), immer vollständig sichtbar, Text umbrechend:
- **Regel greift:** Pill ✓ „Regel n greift“ · Name halbfett · darunter „öffnet ‹Ergebnis-URL mono, auswählbar› in ‹App›“ bzw. Aktion in Worten (wie Testleiste §15.4). URL nur zeigen, wenn sie sich durch Umschreibungen ändert; sonst „öffnet in ‹App›“.
- **Keine Regel greift:** Pill neutral „Keine Regel greift“ · „Standardaktion: ‹Aktion in Worten›“.
- Engine-Warnungen (ungültige Regex, ungültige Ergebnis-URL) als rote Zeilen.
- Rechts im Kopf Knopf „Simulieren …“ (gleiches Popover wie §15.4: Quell-App, Modifier; Punkt bei aktiver Simulation). Die Simulation gilt für die Prüfung und für den Editor (22.4), solange der Prüfmodus aktiv ist; beim Verlassen zurücksetzen.
- Zeile darunter: „x von y Regeln treffen“ + Umschalter „Nur Treffer“ / „Alle Regeln“ (Standard: Nur Treffer).
- Fußnote (11, sekundär) nur, wenn `extensionSettings` vom Standard abweicht: „Links aus der Safari-Erweiterung verhalten sich anders (Allgemein → Safari-Erweiterung).“

### 22.3 Liste im Prüfmodus
- Reihenfolge = Gesamtreihenfolge (oben gewinnt), Positionsnummer bleibt. Sortieren aus (wie beim Filtern), Fußleiste „Sortieren nur ohne Prüfung“.
- **Nur Treffer:** alle Regeln, deren Bedingungen passen (auch deaktivierte). **Alle Regeln:** zusätzlich nicht passende.
- Je Zeile statt der Chips eine Status-Zeile (Symbol + Text, nie nur Farbe):
  - erste aktivierte passende Regel: grün ✓ „greift“ (bei Umschreibung: „greift · schreibt um“);
  - weitere aktivierte passende: orange „trifft, aber Regel n greift zuerst“;
  - deaktivierte passende: umrandet „Aus – würde treffen“;
  - nicht passend (nur bei „Alle Regeln“): grau ✗ „trifft nicht · Bedingung n (Feld)“ (bei MatchMode ≠ alle nur „trifft nicht“); Name `.secondary`.
- Leer bei „Nur Treffer“: „Keine Regel trifft. Mit „Alle Regeln“ siehst du, woran es scheitert.“
- Auswahl, Aktiv-Checkbox, +/−/Duplizieren wie bisher. „+“ legt eine neue Regel an, deren Test-URL die geprüfte URL ist und deren erste Bedingung „Host ist ‹host›“ lautet (nur im Prüfmodus); der Prüfmodus bleibt, die neue Regel muss sichtbar sein (Ansicht schaltet bei Bedarf auf „Alle Regeln“).

### 22.4 Editor im Prüfmodus
- Die Testleiste des ausgewählten Editors verwendet die **geprüfte URL** und die Simulation aus 22.2 statt der gespeicherten Test-URL. Das Feld zeigt die geprüfte URL, nicht editierbar, mit Pill „aus URL-Prüfung“. Damit zeigen ✓/✗ je Bedingung, Pipeline-Knoten, Zwischenschritte und Vorrang-Warnung, warum die Regel (nicht) greift.
- Knopf „Als Test-URL speichern“ setzt `rule.testURL` auf die geprüfte URL (deaktiviert, wenn gleich).
- Die gespeicherte Test-URL wird nicht verändert; nach Verlassen des Prüfmodus zeigt die Testleiste wieder sie.
- „Regel n zeigen“ in der Vorrang-Warnung wählt die Regel im Prüfmodus aus (sie ist als Treffer sichtbar).

### 22.5 Core
- `RuleCheck.url(from: String) -> URL?` (Erkennung aus 22.1).
- `RuleEngine.check(url:context:config:) -> RuleCheckResult` (rein): `decision: Decision` (identisch zu `decide`), `entries: [RuleCheckEntry]` für **alle** Regeln in Config-Reihenfolge mit `ruleID`, `position` (1-basiert), `matches`, `firstFailedCondition: Int?` (nur MatchMode alle), `status`: `.wins`, `.shadowed(by: UUID)`, `.disabledMatch`, `.noMatch`; `matchCount`.
- Tests: Erkennung (http/https/file/eigenes Schema/ohne Schema/Leerzeichen/leer), greift/verdeckt/deaktiviert/kein Treffer, Kette mit Umschreibung, `decision` == `decide`, Simulation (Quell-App, Modifier), firstFailedCondition, leere Bedingungen = immer.

### 22.6 Snapshot und Abnahme
- `--snapshot` zusätzlich: Regeln im Prüfmodus (URL aus der Demo-Config, die eine Regel trifft und eine zweite verdeckt), hell und dunkel, einmal „Nur Treffer“ mit ausgewähltem Gewinner, einmal „Alle Regeln“ bei Mindestgröße.
- Seitenleiste der Regeln 320 pt breit (statt 272), Suchfeld mit vollem Platzhalter „Regeln durchsuchen oder URL prüfen“ und Keycap `⌘F`; Mindestgröße Inhalt dafür 870 × 560 (statt 820 × 560), damit der Editor nicht schmaler wird.
- Build ohne Warnungen, alle Tests grün; bestehende Textsuche (§13.2) und Test je Regel (§14) unverändert.
- Nicht-Ziele: Verlauf echter Klicks, Prüfung über die Menüleiste, Simulation der Safari-Erweiterung als Quelle.

## 23. Darstellung wählbar, neue Tabs „Safari“ und „Updates & Import“ (v1.8)

### 23.1 Darstellung (Hell/Dunkel)
- Alle Fenster (Einstellungen, Auswahlfenster, Sheets, Popover, Alerts) unterstützen Hell und Dunkel; Farben nur über Asset-Farben bzw. semantische Systemfarben (§15.1). Fehlende Dunkel-Varianten ergänzen.
- Config (Core, optional, abwärtskompatibel): `appearance: AppAppearance?` mit `system` (Standard, auch bei nil), `light`, `dark`. nil wird nicht geschrieben; `system` wird als nil gespeichert.
- Anwendung: `NSApp.appearance = nil / .aqua / .darkAqua` beim Start und sofort bei jeder Änderung (auch nach externem Neuladen der Config). Gilt für alle Fenster der App, auch das Auswahlfenster.
- Einstellungen → Allgemein, neuer Abschnitt „Darstellung“ (`circle.lefthalf.filled`): segmentierter Picker „System“ / „Hell“ / „Dunkel“, Hilfetext „System folgt der Einstellung in macOS.“
- Tests: Config-Roundtrip mit/ohne `appearance`, alte Config ohne Feld lädt als `system`.

### 23.2 Tab „Safari“
- Neuer Toolbar-Tab „Safari“ (SF Symbol `safari`) mit dem kompletten bisherigen Abschnitt „Safari-Erweiterung“ (§20/§21: Status, „In Safari aktivieren …“, „Regeln anwenden“, Fallback-Aktion, Hilfetexte). Aus „Allgemein“ entfernen.
- Layout wie Allgemein (zentriert, max. 600 pt, scrollt), oben ein kurzer Einleitungssatz, was die Erweiterung tut (Kontextmenü „Mit Air Traffic öffnen“ / „… auswählen …“, Symbolleisten-Knopf).
- Fußnote der URL-Prüfung (§22.2) verweist auf „Safari“ statt „Allgemein → Safari-Erweiterung“.

### 23.3 Tab „Updates & Import“
- Neuer Toolbar-Tab „Updates & Import“ (SF Symbol `arrow.triangle.2.circlepath`) mit den bisherigen Abschnitten „Updates“ (§17) und „Import & Konfiguration“ (Choosy-Import, Datei-Pfad + „Im Finder zeigen“, „Air Traffic beenden“). Aus „Allgemein“ entfernen.
- Layout wie Allgemein.

### 23.4 Allgemein danach
Problem-Hinweis (optional) · Status-Karte · „Wenn keine Regel passt“ · KI-Assistent · Darstellung.

### 23.5 Reihenfolge und Navigation
- Tabs: Allgemein · Browser · Regeln · Safari · Updates & Import. `SettingsTab` um `safari`, `maintenance` erweitern; Fenstertitel = Tab-Name; Frame-Autosave bleibt.
- Alle Stellen, die bisher zu „Allgemein“ springen, um dort Updates/Import/Safari zu zeigen, springen in den neuen Tab. Menüpunkte (z. B. „Nach Updates suchen …“) bleiben.
- `--snapshot` erzeugt zusätzlich `safari-*` und `maintenance-*` (hell/dunkel) sowie Allgemein mit Darstellungs-Abschnitt; Snapshots setzen die Darstellung selbst und ignorieren `appearance` der Config.
- README und `docs/images` (über `scripts/screenshots.sh`) auf den neuen Stand.

## 24. Kommandozeile und MCP-Server für KI-Agenten (v1.8)

Ziel: Ein KI-Agent (Claude Code, Codex …) oder ein Mensch im Terminal kann Regeln auslesen, prüfen, anlegen, ändern, umsortieren und löschen – mit derselben Logik wie die App. Ein Programm `airtraffic`, zwei Zugänge: Unterbefehle (CLI) und `airtraffic mcp` (MCP-Server über stdio).

### 24.1 Programm und Einbettung
- Neues XcodeGen-Target `airtraffic` (Kommandozeilen-Tool, Swift 6, strict concurrency), linkt `AirTrafficCore`; wird in `Air Traffic.app/Contents/Helpers/airtraffic` eingebettet. Abhängigkeit höchstens `swift-argument-parser` (exakte Version); MCP ohne SDK, eigene schlanke JSON-RPC-Schicht.
- Die Logik (Befehle, Validierung, MCP-Dispatcher) liegt testbar im Core (z. B. `RuleEditing`, `AgentAPI`); das Target ist nur dünne Hülle (Argumente, stdin/stdout, Exit-Codes).
- Respektiert `AIRTRAFFIC_CONFIG_PATH` (§ConfigStore). Schreibt nie in Schlüsselbund, setzt nie den Standardbrowser, öffnet keine Links, kein Netzwerk.
- `release.sh`: Helper vor dem App-Bundle mit Developer ID, `--options runtime --timestamp` signieren; Prüfung wie bei der Erweiterung (gültig, TeamIdentifier).

### 24.2 Datenformat
- Regeln ein- und ausgeben im **selben JSON wie `config.json`** (`Rule` Codable), plus Feld `position` (1-basiert) in Ausgaben.
- Eingaben akzeptieren zusätzlich Kurzformen für Ziel-Apps: `"action": {"type": "open", "app": "Google Chrome"}` bzw. `"app": "com.google.Chrome"` (Name, Bundle-ID oder Pfad) → wird zu `AppRef` aufgelöst (LaunchServices/NSWorkspace). `id` fehlt → neue UUID. Unbekannte Felder → Fehler mit Feldname.
- `airtraffic schema` / MCP-Tool `describe_rule_format`: beschreibt das Format kompakt (Bedingungstypen, Operatoren, Match-Modi, Aktionen, Umschreibungen mit `$1`) mit 3 Beispielen (Host → App, Regex-Umschreibung, Quell-App → Auswahl).

### 24.3 Befehle (CLI) = Tools (MCP)
| CLI | MCP-Tool | Wirkung |
|---|---|---|
| `rules list [--json]` | `list_rules` | alle Regeln mit Position, aktiv, Kurzbeschreibung |
| `rules get <ref>` | `get_rule` | eine Regel vollständig |
| `rules add [--at n] [--dry-run]` (JSON über stdin oder Flags `--name --host --url-contains --regex --open <app> --prompt --rewrite <muster> <vorlage> --test-url`) | `create_rule` | anlegen (Standard: ans Ende) |
| `rules update <ref> [--dry-run]` (JSON-Teilobjekt über stdin; Felder ersetzen, `conditions`/`rewrites` als ganze Liste) | `update_rule` | ändern |
| `rules move <ref> --to n` | `move_rule` | umsortieren |
| `rules enable/disable <ref>` | `set_rule_enabled` | an/aus |
| `rules delete <ref> [--dry-run]` | `delete_rule` | löschen |
| `check <url> [--source <bundleID>] [--modifiers …]` | `check_url` | wie §22: Entscheidung + Status je Regel |
| `browsers list` | `list_browsers` | Browserliste + installierte Apps-Hinweis |
| `settings` | `get_settings` | Standardaktion, Erweiterungs-Verhalten, Darstellung (nur lesen) |
| `schema` | `describe_rule_format` | Format-Beschreibung |
| `mcp` | – | MCP-Server starten |
- `<ref>` = UUID, eindeutiges UUID-Präfix (≥ 6 Zeichen), Position (`#3`) oder exakter Name; mehrdeutig → Fehler mit Kandidaten.
- Ausgabe: menschenlesbar, mit `--json` maschinenlesbar (MCP immer JSON). Fehler auf stderr, Exit-Code ≠ 0; `--dry-run` zeigt die Regel nach der Änderung und schreibt nichts.
- Jede Schreiboperation antwortet mit der resultierenden Regel und einer kurzen `check`-Vorschau für ihre `testURL` (falls gesetzt).

### 24.4 Validierung und Sicherheit
- Vor dem Schreiben: Regex in Bedingungen/Umschreibungen kompilierbar, Ziel-App auflösbar (sonst Fehler; Warnung, wenn Pfad nicht existiert), Aktion gültig, Name nicht leer. Fehler nennen Feld und Grund.
- **Sicherung:** vor jedem Schreiben Kopie nach `…/Air Traffic/backups/config-<ISO-Zeit>.json`, die letzten 30 bleiben.
- **Gleichzeitiger Zugriff:** Lesen-Ändern-Schreiben unter `NSFileCoordinator` (Core-Funktion `ConfigStore.modify`), atomar. Die App nutzt beim Speichern ebenfalls Koordination.

### 24.5 App erkennt externe Änderungen
- Die App beobachtet `config.json` (NSFilePresenter oder Datei-/Ordner-Überwachung, robust gegen atomares Ersetzen) und lädt bei Änderung von außen neu; Auswahl im Regel-Tab bleibt, wenn die Regel noch existiert.
- Die App merkt sich den Inhalt/Hash der zuletzt geladenen/gespeicherten Datei. Vor dem Speichern: Hat sich die Datei inzwischen extern geändert, wird **nicht** überschrieben, sondern neu geladen; Hinweis „Regeln wurden von außen geändert und neu geladen.“ (orange Zeile im Einstellungsfenster, verschwindet nach 6 s oder bei Klick). Eigene Speichervorgänge lösen kein Neuladen aus.
- Tests: Hash-Logik/Konfliktentscheidung als reine Funktion im Core.

### 24.6 MCP-Server
- JSON-RPC 2.0 über stdin/stdout, eine Nachricht pro Zeile; Logs nur auf stderr. Unterstützt `initialize` (Protokollversion des Clients übernehmen, falls unterstützt; sonst `2025-06-18`), `notifications/initialized`, `ping`, `tools/list`, `tools/call`; unbekannte Methoden → Fehler `-32601`.
- `serverInfo`: `air-traffic`, App-Version. `instructions`: 2–3 Sätze (erst `describe_rule_format` und `list_rules`, Änderungen mit `check_url` prüfen, oben gewinnt).
- Jedes Tool mit `inputSchema` (JSON Schema) und kurzer Beschreibung; Ergebnis als `content` (Text-JSON) **und** `structuredContent`; Fachfehler als `isError: true` mit Text.
- Schreibende Tools tragen `annotations` (`destructiveHint` bei delete, `readOnlyHint` bei Lese-Tools).

### 24.7 Installation in der App
Tab „Updates & Import“, neuer Abschnitt „Kommandozeile & KI-Agenten“ (`terminal`):
- Status: „Installiert: ~/.local/bin/airtraffic“ (Pill grün) / „Nicht installiert“ / „Zeigt auf eine andere App-Kopie“ (orange, mit „Aktualisieren“).
- Knopf „Installieren“ legt Symlink `~/.local/bin/airtraffic` → `<App>/Contents/Helpers/airtraffic` an (Ordner bei Bedarf anlegen, kein Admin); „Entfernen“ löscht nur diesen Symlink. Hinweis, falls `~/.local/bin` nicht im `PATH` der Login-Shell ist (mit Zeile zum Ergänzen in `~/.zshrc`).
- Zwei kopierbare Befehle (mono, Knopf „Kopieren“): `claude mcp add --scope user air-traffic -- ~/.local/bin/airtraffic mcp` und `codex mcp add air-traffic -- ~/.local/bin/airtraffic mcp`.
- Kurzer Hilfetext: was ein Agent damit kann, dass vor jeder Änderung eine Sicherung angelegt wird.

### 24.8 Tests, Doku, Abnahme
- Core-Tests: Ref-Auflösung (UUID, Präfix, #n, Name, mehrdeutig), add/update/move/delete/enable, Kurzform-Aktion, Validierungsfehler, Backups (Rotation), `modify` atomar, Konfliktentscheidung 24.5, MCP-Dispatcher (initialize, tools/list enthält alle Tools mit Schema, tools/call Erfolg und Fehler, unbekannte Methode).
- Ende-zu-Ende-Skript-Test (manuell, im Bericht): CLI gegen eine Config-Kopie; `mcp` mit einer Folge von JSON-Zeilen über stdin.
- README: Abschnitt „Kommandozeile & KI-Agenten“ mit Installation, Beispielen, MCP-Einbindung.
- `--snapshot`: Tab „Updates & Import“ mit neuem Abschnitt.
- Nicht-Ziele: Browserliste, Standardaktion, KI-Einstellungen per CLI ändern; Netzwerk-Transport (HTTP/SSE); Authentifizierung.

## 25. Tabs neu geordnet (v1.8)

Ersetzt die Tab-Aufteilung aus §23.3/§24.7:
- Tabs: Allgemein · Browser · Regeln · Safari · **CLI & MCP** (`terminal`) · **Updates** (`arrow.triangle.2.circlepath`, immer zuletzt). `SettingsTab`: `general, browsers, rules, safari, cli, updates`.
- „CLI & MCP“ enthält den Abschnitt „Kommandozeile & KI-Agenten“ (§24.7), „Updates“ nur den Abschnitt Updates (§17).
- „Import & Konfiguration“ (Choosy-Import, Datei-Pfad, „Air Traffic beenden“) steht wieder in **Allgemein, ganz unten** (nach Darstellung).
- `--snapshot`: `cli-*`, `updates-*` statt `maintenance-*`; `general-full-*` zeigt Allgemein vollständig.

### 25.1 Status der Safari-Erweiterung im Entwicklungs-Build
Safari führt Erweiterungen als „<Bundle-ID> (<Team-ID>)“. Ein ad hoc signierter Debug-Build hat keine Team-ID; `SFSafariExtensionManager` und `showPreferencesForExtension` liefern dort `SFErrorDomain 1` (noExtensionFound). Die App erkennt das über die eigene Signatur (keine Team-ID) und zeigt „Entwicklungs-Build“ mit Erklärung statt „Unbekannt“ + Rohfehler; `SFErrorDomain 1` in der signierten App → „Von Safari nicht gefunden“ mit Hinweis (aus /Programme starten, Safari neu öffnen).

## 26. Sicherheits-Härtung nach Audit (v1.9)

Grundlage: Security-Audit vom 2026-11-06 (zwei unabhängige Prüfer, Stand 1.8). Ziel: alle code-seitig behebbaren Befunde schließen, ohne Funktionen zu verlieren.

### 26.1 Freigabe für riskante Agenten-Änderungen (Befund: Agent leitet Links still um)
- Änderungen über CLI/MCP (`AgentAPI`, beide Wege gleich – ein Agent kann auch die CLI nutzen) an **`rewrites`** oder **`action`** (auch beim Anlegen einer Regel mit Umschreibungen oder einer Aktion) werden **nicht sofort wirksam**. Die Regel bekommt `pendingChange` (Codable, optional, abwärtskompatibel): `since: Date`, `reason: String`, `previous: Rule?` (vollständige vorherige Regel; nil = neu angelegt).
- **Engine:** Regeln mit `pendingChange` gelten so, als gäbe es die Änderung nicht: neu angelegt → wird übersprungen; geändert → `previous` wird ausgewertet. Gilt für `decide`, `check`, `test`-Vorrang. Name/Bedingungen/Test-URL/Position/an-aus ohne Umschreibungs- oder Aktionsänderung bleiben sofort wirksam; `set_rule_enabled`/`enable` auf eine wartende neue Regel macht sie nicht wirksam.
- Agenten können nicht freigeben: kein CLI-Befehl, kein MCP-Tool, und `pendingChange` in Eingaben wird abgelehnt. Antworten von create/update nennen „wartet auf Freigabe in Air Traffic“; MCP-`instructions` und `describe_rule_format` erklären das. Ändert ein Agent eine wartende Regel erneut, bleibt `previous` der letzte freigegebene Stand.
- **App:** Regel-Liste: Chip „Freigabe nötig“ (orange) und Zähler in der Fußleiste. Editor: orange Karte oben „Von außen geändert – wartet auf Freigabe“ mit Vorher/Nachher für Umschreibungen (Muster, Vorlage) und Aktion (Ziel-App mit Pfad), Ergebnis-Vorschau mit Test-URL; Knöpfe „Freigeben“ (entfernt `pendingChange`) und „Verwerfen“ (neu → löschen, geändert → `previous` wiederherstellen). Bearbeitet der Nutzer die Regel in der App, bleibt die Freigabe trotzdem nötig (expliziter Knopf).
- **Mitteilung:** Bei jeder Übernahme einer Änderung von außen (§24.5) eine macOS-Mitteilung (UserNotifications; Berechtigung beim ersten Mal anfragen): „Regeln von außen geändert“ + „n wartet/warten auf Freigabe“; Klick öffnet Einstellungen → Regeln mit der ersten wartenden Regel. Ohne Berechtigung bleibt es bei der orangen Zeile.
- **Ziel sichtbar:** Kurzbeschreibungen (CLI `rules list`, MCP `list_rules`, Chips der Regel-Liste) zeigen bei Umschreibungen das Ziel (literaler Anfang der Vorlage bis zum ersten `$`, z. B. „↻ review.example.com“), nicht nur „umschreiben“.

### 26.2 Schema nach dem Umschreiben (Befund: beliebige Schemata)
- Ergebnis einer Umschreibung ist nur gültig, wenn ihr Schema `http`/`https` ist, **oder** gleich dem Schema der Original-URL, **oder** literal am Anfang der Vorlage steht (z. B. `linear://…` – vom Regel-Autor bewusst gesetzt, nicht aus der URL übernommen). Sonst: Original-URL + Warnung (wie ungültige URL). Opener prüft zusätzlich: `file:` nur, wenn die Original-URL `file:` war.
- Regel-Test/Prüfmodus zeigen einen Schemawechsel als Warnung. Tests: `?u=file:…`, `smb:`, `javascript:`, `vscode:` über `$1` → abgelehnt; literales `linear://` in der Vorlage → erlaubt; file→file erlaubt.

### 26.3 Laufzeit-Schutz beim Regel-Abgleich (Befund: App hängt bei langen URLs)
- **Platzhalter** (`wildcard`) ohne Regex: linearer Glob-Abgleich (`*`, `?`, `\`-Maskierung, Groß/Klein wie bisher), O(n·m) worst case ohne Backtracking-Explosion. Verhalten identisch zu bisher (bestehende Tests grün, plus Äquivalenztests).
- **URL-Länge:** URLs über 8192 Zeichen werden nicht gegen Regeln geprüft; es erscheint das Auswahlfenster mit Hinweis „Link zu lang für Regeln“ (Aktion `.prompt(.all)`), Warnung im Ergebnis.
- **Regex mit Zeitbudget:** Regex-Abgleich (Bedingungen und Umschreibungen) über `enumerateMatches(options: .reportProgress)` mit Abbruch nach Frist; Gesamtbudget je Link 500 ms. Überschritten → Regel gilt als „trifft nicht“, Warnung „Regel „X“: Zeitlimit überschritten“, bei Umschreibung Original-URL. Kompilierte Regex werden gecacht (Muster + Optionen).
- `decide` läuft nicht mehr blockierend auf dem Main Actor (Hintergrund-Task, Ergebnis zurück auf Main). Reihenfolge eingehender Links bleibt erhalten.
- Tests: pathologische Muster (`*a*b*c*d*`, `^(a|aa)+$`) mit 60 000 Zeichen enden < 1 s.

### 26.4 Quell-App aus `airtraffic://` (Befund: `source` fälschbar)
- `source` wird nur übernommen, wenn es `com.apple.Safari` ist (der einzige Wert der eigenen Erweiterung); andere Werte werden ignoriert (Warnung im Log, Quelle = tatsächlicher Absender des Apple Events, sonst „unbekannt“).
- Zusätzlich: Absender-PID aus dem Apple Event (`keySenderPIDAttr`/Audit-Token) ermitteln; liegt dessen Programm in `<eigene App>/Contents/PlugIns/`, gilt der Link als „von der Erweiterung“. Ist er das nicht, zeigt das Auswahlfenster statt „von Safari“ „über airtraffic://-Link“. (Falls die PID sich nicht zuverlässig ermitteln lässt: im Bericht melden, dann gilt nur die Safari-Beschränkung.)

### 26.5 Debug-Schalter nur im Debug-Build (Befund: `--suggest-regex` nutzt Key)
- `--decide`, `--suggest-regex`, `--snapshot` nur mit `#if DEBUG`. Release-Build ignoriert sie (normaler Start). README entsprechend.

### 26.6 KI-CLI-Pfade (Befund: beliebige ausführbare Datei)
- Konfigurierte `claudePath`/`codexPath` werden nur verwendet, wenn der Dateiname exakt `claude` bzw. `codex` ist (Symlink erlaubt, Ziel egal); sonst ignoriert und in den Einstellungen als „Pfad ungültig – Datei muss claude/codex heißen“ angezeigt. Die automatische Statusprüfung (`--version`) startet nur gültige Pfade.
- Codex: In den Einstellungen beim Anbieter Codex Hinweis „Codex darf dabei Dateien lesen (Sandbox nur lesend)“. Prompt für Codex mit klarer Anweisung, keine Werkzeuge/Shell zu nutzen und nur JSON zu antworten. (Keine ungetesteten Codex-Flags einbauen.)

### 26.7 Keine URLs öffentlich im Log
- Alle Log-Meldungen, die URLs oder Teile davon enthalten können (Engine-/Rewriter-Warnungen, ParseError-Beschreibungen, Erweiterung), mit `privacy: .private` bzw. ohne URL-Inhalt. Öffentlich bleiben nur Bundle-IDs, Pfade der App, Zähler, Regelnamen.

### 26.8 Auswahlfenster gegen Spam und Fehl-Tastendrücke
- Warteschlange höchstens 5 Einträge; identische URLs zusammenfassen; weitere verwerfen (Log-Warnung, ab dann für 10 s nur Log).
- Tasten (Ziffern, ⏎) in den ersten 300 ms nach dem Erscheinen eines Eintrags ignorieren.
- `airtraffic://` mit `prompt=1` höchstens 3 pro 10 s (weitere werden verworfen).
- Host-Anzeige: lange Hosts **vorne** kürzen (`…evil.example`), sodass die registrierbare Domain sichtbar bleibt; voller Host im Tooltip/VoiceOver.

### 26.9 Schleifenbremse
- Dieselbe URL wird innerhalb von 5 s höchstens 3-mal an eine App übergeben; danach Auswahlfenster mit Hinweis „Link kreist zwischen Apps“.

### 26.10 Sicherungen
- Aufbewahrung nach Zeit: alle Sicherungen der letzten 24 h (höchstens 100) plus jeweils die neueste pro Tag für 14 Tage. Die Sicherung vor der ersten Agenten-Änderung eines Tages bleibt so erhalten. Tests für die Rotation.

### 26.11 Abnahme
- Build ohne Warnungen, alle Tests grün (neue Tests je Punkt), `--snapshot` (Debug) zeigt wartende Regel in Liste und Editor (hell/dunkel).
- README: Abschnitt „Sicherheit“ (Freigabe, Schema-Regel, Grenzen) und Datenschutz ergänzen; Debug-Schalter nur Debug.
