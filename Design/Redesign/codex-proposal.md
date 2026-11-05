# Air Traffic – ruhige Präzision

## 1. Designprinzipien

- **Ziel vor Werkzeug:** Im Chooser dominieren Browser und Zieladresse; im Editor der Weg vom Treffer zur Aktion.
- **Radar als Haltung:** Petrol, klare Konturen und gerichtete Pfeile übernehmen die Identität des betrachteten Icons. Radar-Ringe und Sweep bleiben im Icon.
- **Native Substanz:** NSPanel, NSTextField, List, Picker und gruppierte Form bleiben die Grundlage. Gestaltung entsteht durch Hierarchie und Abstände.
- **Glas markiert die schwebende Ebene:** Der Chooser erhält Tiefe; längere Inhalte liegen auf ruhigen, lesbaren Flächen.
- **Jeder Zustand ist lesbar:** Auswahl, Treffer und Fehler unterscheiden sich durch Kontur, Symbol und Text; Farbe unterstützt.

## 2. Chooser

Das titellose NSPanel bleibt mittig auf dem aktiven Bildschirm. Breite: 480–900 pt, zusätzlich auf die verfügbare Bildschirmbreite begrenzt. Inhalt: 20 pt Außenabstand, 12 pt zwischen Ebenen. Bei einer Browserreihe etwa 230–250 pt Höhe; Hinweise dürfen das Panel vergrößern.

Oben eine kompakte Herkunftszeile: Quell-App-Icon 16 pt, „Von …“ in 12 pt Sekundärschrift. Darunter das URL-Feld, 36 pt hoch, mit ruhigem Textfeldhintergrund und 8 pt Innenabstand. Unfokussiert wird der tatsächlich geparste Host halbfett, der übrige URL-Text sekundär dargestellt. Bei langen URLs bleibt der Host sichtbar, gekürzt wird nach Möglichkeit im Pfad. Keine pauschale Dekodierung oder Entfernung von URL-Bestandteilen. Bei Tab erscheint derselbe vollständige Wert im vorhandenen NSTextField, monospaced, horizontal scrollbar und mit nativem Fokusring.

Browser stehen in einer horizontalen Reihe: Kacheln 96 × 100 pt, Abstand 8 pt, Radius 12 pt; Icon 44 pt, Name 12 pt mit maximal zwei Zeilen. Ziffern 1–9 sitzen oben rechts als kleine Tastenkappen. Weitere Browser tragen keine Ziffer. Bei Überlauf bleibt die Reihe scrollbar; die Tastaturauswahl wird sichtbar gehalten.

Eine ausgewählte Kachel erhält 12 % Systemakzent als Füllung und eine 2-pt-Akzentkontur; damit ersetzt sie die bisher recht flächige 25-%-Tönung. Hover übernimmt weiterhin unmittelbar die Auswahl. Keine zusätzliche Vergrößerung der Icons. Unterhalb bleiben die vorhandenen Tastaturhinweise in 11 pt. Esc verlässt beim Bearbeiten zunächst das URL-Feld; außerhalb schließt es das Panel.

Eine gemeinsame Glasfläche mit 20-pt-Radius und systemnaher Schattierung trägt den Chooser. Einblenden: 120 ms Opazität und Skalierung 0,985 → 1, ohne Überschwingen. Auswahlwechsel: 90 ms Farbwechsel, unmittelbar bedienbar. Bei reduzierter Bewegung nur Opazität.

## 3. Einstellungsfenster

**TabView beibehalten:** Drei gleichrangige Bereiche rechtfertigen keine zusätzliche Navigationssidebar. Neben der Regelliste würde sie bei 820 × 560 pt wertvollen Editorplatz verbrauchen. Tabs weiterhin mit Symbol und Beschriftung; kein eigener Navigationsbaukasten.

Mindestgröße bleibt 820 × 560 pt. Allgemein und Browser bekommen eine zentrierte Inhaltsbreite von maximal 680 pt mit 20 pt Rand. Regeln nutzt die volle Breite. Einheitliche Abschnittsüberschriften, 16 pt Gruppenabstand und native Fensterflächen ersetzen den Eindruck beliebig aneinandergereihter Formulare.

## 4. Regeln: Liste und Editor

**Liste:** 280 pt bleiben. Suche oben, native Auswahlhervorhebung, keine alternierenden Streifen. Zeilen mindestens 58 pt: Checkbox links, Name 13 pt semibold, darunter maximal zwei Zeilen Zusammenfassung in 11 pt. Bestehende Zusammenfassung typografisch gliedern: Bedingung → Ziel; „Umschreiben“ als kleiner neutraler Hinweis. Deaktivierte Regeln behalten lesbaren Sekundärtext. +/−/Duplizieren bilden unten eine kompakte native Button-Gruppe.

**Editor:** Name und Aktivzustand bilden den Kopf. Darunter eine schmale, nicht interaktive Orientierung „Bedingungen → Umschreiben → Aktion“, keine neuen Navigationstabs. Die vorhandene Testsektion bleibt früh erreichbar. Die drei folgenden Formgruppen erhalten passende nummerierte Überschriften. „Passt, wenn“ rückt direkt zu den Bedingungen.

Bedingungen werden zweizeilig: oben Feld- und Operator-Picker, darunter der ausreichend breite Wert. Aa, KI und Entfernen bleiben kompakt rechts. Modifier erscheinen als beschriftete native Toggle-Tastenkappen. Chips dienen nur der Übersicht; editierbare Werte bleiben normale Textfelder.

Jede Umschreibung erhält zwei übereinanderliegende, ausdrücklich beschriftete Zeilen „Muster“ und „Vorlage“. Darunter das vorhandene Zwischenergebnis auf leicht abgesetzter Fläche, mit Pfeil und auswählbarem Monospace-Text. `$1`, `$2` werden im Hilfetext als kleine Monospace-Token erklärt; keine zusätzliche Syntaxeditor-Logik.

Teststatus: Grün mit Haken für Treffer, neutrales Grau mit Kreuz für Nichttreffer; Rot ausschließlich für ungültige Eingaben oder Ergebnisse. Vorrang-Warnung amberfarben mit Symbol, vollständigem Text und vorhandenem „Zeigen“-Button. Statuswechsel verändern keine Eingabepositionen unnötig.

## 5. Allgemein, Browser, KI

Allgemein beginnt mit einer kompakten Statusgruppe: App-Icon 32 pt, Standardbrowserstatus und bestehende Aktionen. Danach Default-Aktion, KI, Choosy und Konfiguration. Schlüsselbundstatus steht beim SecureField, Verbindungsergebnis darunter.

Browserliste: 52-pt-Zeilen, Icons 32 pt, Name primär, Pfad sekundär und mittig gekürzt. Fehlende Apps erhalten Warnsymbol plus Text. Sortierung und Aktionen bleiben bestehen.

KI-Sheet behält 660 × 620 pt: Eingabe und Ergebnis klar gruppieren, TextEditor mit nativer Textfläche und 8-pt-Radius statt dünner Rechteckrahmen. Bestehende Vorschau erhält mehr Zeilenabstand. Fußleiste bleibt sichtbar; „Übernehmen“ bleibt die hervorgehobene Aktion.

## 6. Gestaltungssystem

SF Pro: Titel 20 pt semibold, Abschnitt 13 pt semibold, Inhalt 13 pt, Hilfen 11–12 pt. SF Mono nur für technische Werte. Abstände 4/8/12/20 pt. Markenfarbe hell `#24685C`, dunkel `#83DAC4`; Icon-Verlauf `#123F39` → `#071F24`. Auswahl und Fokus verwenden den Systemakzent. Flächen und Text nutzen semantische Systemfarben.

SF Symbols: `gearshape`, `globe`, `list.bullet.rectangle`, `line.3.horizontal.decrease`, `arrow.right`, `arrow.up.right`, `sparkles`. Keine zusätzlichen Statusfarben pro Pipeline-Stufe.

Glas ab macOS 26 via `glassEffect`, auf macOS 15 mit `.regularMaterial` als Fallback ([Apple](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)). Keine Glasflächen stapeln. Reduzierte Transparenz verlangt deckende Systemflächen, erhöhter Kontrast stärkere Konturen. Ziel: mindestens 4,5:1 Textkontrast. VoiceOver benennt Browser, Auswahl, Nummer sowie jeden Icon-Button; Textvergrößerung darf Zeilen wachsen lassen.

## 7. Top 5 nach Wirkung pro Aufwand

1. **Editor entflechten – sehr hoch/klein:** `VStack`, `LabeledContent`, `.layoutPriority(1)` statt überfüllter HStacks.
2. **Chooser-Kacheln – hoch/klein:** `.overlay`, `RoundedRectangle`, `.tint`, `.animation(_:value:)`.
3. **Regelhierarchie – hoch/klein:** `Section`-Header, `Label`, `.fontWeight`, konsistente Abstände.
4. **Listen beruhigen – mittel/klein:** `.listStyle(.inset)`, Zeilenabstände; alternierende Hintergründe entfernen.
5. **Chooser-Material und URL – hoch/mittel:** Availability-Branch, `.glassEffect(_:in:)`; vorhandenes NSTextField außerhalb der Bearbeitung attributiert darstellen. Vollständigen Editierwert erhalten.
