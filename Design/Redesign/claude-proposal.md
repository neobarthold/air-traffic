# Air Traffic – Design-Vorschlag (Claude, Entwurf 1)

## Prinzipien
1. **Regel = Flugroute:** Jede Regel liest sich als Pipeline *Wenn → Umschreiben → Öffnen*. Die Struktur trägt die Bedeutung, nicht die Formularfelder.
2. **Live statt Raten:** Der Test läuft immer mit. Jeder Schritt zeigt direkt seinen Status (✓/✗, vorher → nachher).
3. **Nativ mit Markenakzent:** Liquid Glass, SF Symbols und Systemtypo. Die Marke zeigt sich nur über den Radar-Akzent (Petrol/Mint) und das Icon.
4. **Ruhige Dichte:** weniger Rahmen, mehr Weißraum, Hierarchie über Gewicht und Farbe statt über Linien.

## Chooser
- **Material:** Glas-Panel, Radius 22, Breite 520–880 je nach Anzahl Browser. `glassEffect(.regular, in: .rect(cornerRadius: 22))`, Fallback `.regularMaterial`.
- **Kopf:**
  - Quell-App als Pille: Icon 16 + „von Slack“.
  - Daneben ein Hinweis „umgeschrieben“, wenn eine Umschreibung gegriffen hat (sparkle-Symbol `arrow.triangle.2.circlepath`).
- **URL-Zeile:** strukturiert statt reines Textfeld.
  - Schloss-Symbol, dann **Host fett**, Pfad in sekundärer Farbe, Query tertiär.
  - Tab oder Klick schaltet um in das monospace-Feld.
- **Kacheln:**
  - Icon 56, Name darunter, Breite 92.
  - Nummer als kleines Keycap (abgerundetes Rechteck mit Rahmen) oben rechts.
  - Ausgewählt: Glas-Highlight mit Akzent-Ring 2 pt und Scale 1.04 per Spring (0.25).
  - Laufende Apps mit Punkt unter dem Icon, wie im Dock.
- **Fußzeile:** Tastenhinweise als Keycaps: `⏎ Öffnen`, `⌥⏎ im Hintergrund`, `Tab bearbeiten`, `⌘C kopieren`, `esc`.
- **Erscheinen:** Scale 0.97 → 1 und Opacity, 160 ms.

## Einstellungsfenster
- **Struktur:** Toolbar-Tabs im Stil der Systemeinstellungen von Safari/Mail (NSToolbar mit großen Symbolen) statt eingebetteter TabView.
  - Gewinn: ganze Fensterfläche für Inhalt, nativer Settings-Look.
  - NavigationSplitView mit Sidebar abgelehnt: Bei den Regeln wären es sonst drei Spalten auf 820 pt.
- **Tabs:** Allgemein (`gearshape`), Browser (`safari`), Regeln (`point.topleft.down.to.point.bottomright.curvepath`).

## Regel-Liste
- Sidebar-Material (Source List), Breite 270.
- **Zeile:**
  - Reihenfolgenummer klein links: Priorität sichtbar, denn die erste Regel gewinnt.
  - Ziel-App-Icon 20.
  - Name.
  - Darunter Bedingungs-Chips, z. B. `host ∋ github.com`, max. 2 plus „+1“.
- **Aktiv-Status:** kleiner Switch rechts, inaktive Zeilen mit 50 % Deckkraft.
- **Suche:** Suchfeld oben (`.searchable`-Optik), unten Leiste mit + − ⧉.

## Regel-Editor
- **Kopf:** großer Name (Title2, inline editierbar), darunter Ziel-Zusammenfassung „→ Linear“, rechts Switch „Aktiv“.
- **Pipeline:** drei Karten, verbunden durch eine vertikale Linie mit Knoten. Die Knoten färben sich beim Test grün oder grau.
  1. **Wenn** (`line.3.horizontal.decrease`): Segmented „alle / eine / keine“ in der Kartenkopfzeile. Bedingungen als Token-Zeilen `[Host ▾] [enthält ▾] [github.com]` mit ✓/✗-Badge rechts.
  2. **Umschreiben** (`wand.and.rays`): Pattern und Vorlage monospace. Regex-Gruppen farbig: Gruppe 1 und `$1` in derselben Farbe. Darunter vorher → nachher als Diff mit hervorgehobenem geändertem Teil. Knopf „✦ Mit KI“ in der Kartenkopfzeile.
  3. **Öffnen** (`arrow.up.forward.app`): App-Picker mit Icon.
- **Test:** Leiste unten im Editor, immer sichtbar (`safeAreaInset(edge: .bottom)` mit Glas).
  - URL-Feld plus Ergebnis-Pille „✓ trifft → linear.review/… in Linear“.
  - Vorrang-Warnung als orange Pille mit „Zeigen“.
  - „Simulieren“ als Popover (Quell-App, Modifier).

## Allgemein
- Hero-Karte oben: App-Icon 64, „Air Traffic“, Statuszeile.
  - Ist Standardbrowser: grüne Glas-Pille.
  - Sonst: prominenter Knopf „Als Standardbrowser festlegen“.
- Darunter gruppierte Form, Abschnitte mit kleinen farbigen Symbolkacheln wie in den Systemeinstellungen.

## Browser
- **Vorschau:** Oben eine Live-Mini-Vorschau des Choosers („So sieht dein Auswahlfenster aus“).
- **Liste:** darunter mit Keycap-Nummer, Icon 32, Name, Pfad tertiär, Griff ≡ und Badge „nicht gefunden“.

## KI-Sheet
- **Kopf:** Sparkles mit Akzentverlauf.
- **Eingabe:** großes Beschreibungsfeld.
- **Ergebnis:** Karte mit Pattern/Vorlage und Beispiel-Diffs ✓/✗; „Übernehmen“ als Primärknopf.

## Farbe / Typo
- **Akzent:**
  - Hell: Radar-Petrol #0F7A62 als Text- und Ring-Farbe, Kontrast ≥ 4.5:1 auf Weiß. Das bisherige #28BA8D ist zu hell für Text.
  - Dunkel: Mint #7CFFD0.
- **Status:** trifft = systemGreen, trifft nicht = secondary, Warnung = systemOrange, Fehler = systemRed.
- **Regex-Gruppen:** Palette systemBlue, systemPurple, systemPink, systemTeal.
- **Typo:**
  - SF Pro: Kartentitel 13 semibold Versalien-frei, Labels 13, Hilfstexte 11 secondary.
  - SF Mono 12 für URL und Regex.
