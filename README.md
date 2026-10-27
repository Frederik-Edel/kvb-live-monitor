# KVB Live Abfahrtsmonitor

Eine Flutter-App für Live-Abfahrten an KVB-Haltestellen in Köln. Sie findet
Haltestellen in der Umgebung, zeigt Fußweg-Schätzungen und lässt sich über
Suche, Linienfilter und Einstellungen anpassen.

## Funktionen

- **Live-Abfahrten:** Anzeige von Linie, Fahrtziel, Soll- und Echtzeit sowie
  Verspätungsstatus. Über Pull-to-Refresh oder den Aktualisieren-Button können
  die Daten jederzeit neu geladen werden.
- **Zeitdarstellung:** Abfahrtszeiten können als Uhrzeit, Countdown oder beides
  zusammen angezeigt werden.
- **Standort und nächste Haltestelle:** Mit Standortberechtigung wird beim Start
  die nächstgelegene Station gewählt. Der Standortbutton löst die Suche erneut
  aus. Sind Standortdienste aus, führt die App in die Android-Standorteinstellungen;
  Android erlaubt Apps nicht, GPS selbst einzuschalten.
- **Haltestellensuche:** Durchsucht den mitgelieferten Stationskatalog nach Name
  oder Stations-ID. Die Ergebnisliste reagiert verzögert auf Eingaben, um
  unnötige Neuberechnungen zu vermeiden.
- **Fußweg:** OSRM berechnet eine Fußroute zwischen Standort und Haltestelle.
  Die App zeigt daraus eine geschätzte Gehzeit mit angenommenen 5 km/h an. Wenn
  der öffentliche OSRM-Dienst ausfällt, wird Luftlinie × 1,3 als ausdrücklich
  gekennzeichnete Schätzung verwendet.
- **Fußweg und Abfahrten:** Abfahrten, für die die Gehzeit abzüglich einer
  kurzen Reserve nicht mehr reicht, werden als „Zu knapp“ markiert.
- **Fahrtausfälle:** Falls die KVB-Antwort ein Ausfallkennzeichen enthält,
  werden Fahrt und Uhrzeit rot und durchgestrichen dargestellt.
- **Linienfilter:** Die Chips unter dem Header schalten Linien ein und aus.
  Ein Doppeltipp auf eine Linie isoliert diese; ein weiterer Doppeltipp darauf
  aktiviert wieder alle Linien. Die Filterleiste lässt sich in den Einstellungen
  abschalten.
- **Automatische Aktualisierung:** Optional werden Abfahrten alle 60 Sekunden
  neu geladen. Diese Funktion ist standardmäßig deaktiviert und wird in den
  Einstellungen eingeschaltet.
- **Dark Mode:** Über den Schalter in den Einstellungen aktivierbar.
- **Android-Widget:** Das Startbildschirm-Widget zeigt bis zu fünf Abfahrten
  einer in den Einstellungen ausgewählten Station und nur der dort ausgewählten
  Linien. Es wird aktualisiert, sobald die App neue Widget-Daten lädt. Ist die
  App längere Zeit geschlossen, zeigt das Widget den zuletzt geladenen Stand.
- **Einstellungen:** Linienfilter, automatische Aktualisierung, Dark Mode sowie
  Status und System-Einstellungslinks für Standortberechtigung und Standortdienste.
- **Persistenz:** Letzte Station und Einstellungen werden lokal mit
  `shared_preferences` gespeichert.

## Projektaufbau

```text
lib/
  main.dart                        App, UI, Standort-, Filter- und Ladeablauf
  data/station_catalog.dart        CSV laden und Stationen validieren
  models/
    departure.dart                 HAFAS-Antworten in Abfahrten umwandeln
    station.dart                   Stationsmodell
  services/
    walking_route_service.dart     OSRM-Fußrouten-Anfrage und Fallback
    kvb_departure_service.dart     KVB-Abfahrtsanfrage
assets/
  kvb_koeln_stationen_nach_nummer.csv
                                    Lokaler Stationskatalog
android/
  app/src/main/AndroidManifest.xml Android-Berechtigungen und Widget-Provider
  app/src/main/kotlin/...          Flutter-Kanal und nativer Widget-Provider
  app/src/main/res/layout/         Widget-Layout
  app/src/main/res/xml/            Widget-Konfiguration
test/
  widget_test.dart                 Parser-, Katalog- und Service-Tests
```

### Datenfluss

1. `StationCatalog.load()` liest die CSV aus `assets/` ein. Die Daten enthalten
   Stations-ID, Name und Koordinaten und werden beim Laden validiert.
2. Beim Start fragt `geolocator` nach Standortberechtigung und ermittelt
   gegebenenfalls die Position. Ist das nicht möglich, verwendet die App die
   zuletzt gewählte Station oder Neumarkt als Fallback.
3. Die ausgewählte Station wird mit `shared_preferences` gespeichert. Die
   Abfahrten werden anschließend beim KVB-Auskunftsserver angefragt.
4. `parseDepartures` validiert die Antwort und wandelt Fahrten in
   `Departure`-Objekte um. Die UI wendet den Linienfilter nur auf die Darstellung
   an; ein Filterwechsel benötigt keine erneute API-Anfrage.
5. Für die Fußweg-Schätzung sendet `WalkingRouteService` die Positions- und
   Stationskoordinaten an OSRM.

## Abfahrts-API

Die App stellt eine HTTPS-POST-Anfrage an den KVB-Auskunfts-Endpunkt:

```text
https://auskunft.kvb.koeln/gate
```

Die Anfrage wird in `lib/services/kvb_departure_service.dart` zusammengestellt. Sie
enthält JSON im HAFAS-Format mit:

- Dienst `StationBoard` und Abfragetyp `DEP` (Abfahrten),
- `stbLoc.extId` als Stations-ID aus dem lokalen Stationskatalog,
- aktuellem Datum (`yyyyMMdd`) und aktueller Uhrzeit (`HHmmss`),
- maximal 15 Fahrten,
- Produkt-/Metadatenfiltern für die gewünschten KVB-Verbindungen.

Die Anfrage enthält außerdem die vom Web-Auskunftsdienst erwarteten HTTP-Header
sowie dessen AID-/Client-Kennungen. Die Kennungen werden als Teil der
KVB-Webschnittstelle verwendet und sind keine vom App-Benutzer eingegebenen
Daten.

Bei HTTP 200 wird der JSON-Inhalt in `lib/models/departure.dart` ausgewertet:
Produktindex und `prodL` liefern den Liniennamen, `dirTxt` das Ziel und `stbStop`
Soll-/Echtzeit sowie Datum. Daraus berechnet die App eine Verspätung. Eine
Service-Antwort mit `err: "ok"` ist erfolgreich; andere Servicefehler und
ungültige Antwortstrukturen werden als Fehler angezeigt.

Dies ist die von der KVB-Webauskunft verwendete Schnittstelle, keine hier
garantierte öffentliche API. Verfügbarkeit, Antwortformat, Zugangsdaten und
Nutzungsbedingungen können sich ändern. Die App fängt HTTP-Fehler, Zeitlimits
und ungültige Antworten ab und zeigt den Grund im Statusbereich an.

## Fußweg-API

`lib/services/walking_route_service.dart` ruft OSRM über HTTPS auf:

```text
https://router.project-osrm.org/route/v1/foot/{lon1},{lat1};{lon2},{lat2}?overview=false
```

OSRM liefert die Streckenlänge in Metern. Die UI rechnet diese Länge für die
Anzeige mit einer angenommenen Gehgeschwindigkeit von 5 km/h in Minuten um.
Wenn Anfrage, Antwort oder Routing fehlschlagen, nutzt
`WalkingRouteService` die Haversine-Luftlinie zwischen beiden Koordinaten,
multipliziert sie mit 1,3 und markiert die daraus entstehende Gehzeit als
Schätzung. Auch OSRM-Routen sind Schätzungen und hängen vom verfügbaren
Fußwegenetz ab.

## Berechtigungen und lokale Einstellungen

Android deklariert Internet- sowie grobe und präzise Standortberechtigungen in
`android/app/src/main/AndroidManifest.xml`. Die Standortberechtigung wird zur
Laufzeit angefragt; Benutzer können sie in den Systemeinstellungen ändern.
Standortzugriff wird für Standortsuche und Fußweg benötigt, nicht für die
manuelle Haltestellensuche oder die Anzeige von Abfahrten.

Lokal gespeicherte Schlüssel:

| Schlüssel | Bedeutung | Standard |
| --- | --- | --- |
| `last_station_id` | Zuletzt gewählte Station | Keine; Fallback Neumarkt |
| `line_filter_enabled` | Linien-Chips anzeigen | Aktiviert |
| `auto_refresh_enabled` | Abfahrten zyklisch neu laden | Deaktiviert |
| `dark_mode_enabled` | Dunkles Farbschema verwenden | Deaktiviert |
| `departure_time_display` | Uhrzeit, Countdown oder beides | Uhrzeit |
| `walking_check_enabled` | Gehzeit auf Abfahrten anwenden | Aktiviert |
| `widget_station_id` | Haltestelle im Android-Widget | Startstation |
| `widget_lines` | Linien im Android-Widget | Alle Linien der Station |

Die automatische Aktualisierung ruft dieselbe Abfahrtsfunktion wie der
Aktualisieren-Button auf und fragt die aktuell ausgewählte Station ab. Das
Intervall beträgt derzeit fest 60 Sekunden.

## Android-Widget

Der native `KvbDeparturesWidgetProvider` stellt ein Android-Startbildschirm-
Widget bereit. In der App unter **Einstellungen → Widget** werden Haltestelle
und Linien ausgewählt. Flutter sendet Stationsname und gefilterte Abfahrten
über einen MethodChannel an `MainActivity`; der native Provider speichert den
letzten Inhalt lokal und zeichnet alle vorhandenen Widget-Instanzen neu.
Antippen des Widgets öffnet die App. Das Widget führt selbst keine
Hintergrund-Netzwerkanfragen aus und zeigt deshalb bei geschlossener App den
zuletzt geladenen Datenstand.

## Entwicklung und Build

Voraussetzungen: Flutter SDK (Dart inklusive), Android SDK und eine passende
Java-Version für die Android-Gradle-Konfiguration.

```powershell
flutter pub get
flutter analyze
flutter test
flutter run
```

Debug-APK bauen:

```powershell
flutter build apk --debug
```

Die APK wird unter `build/app/outputs/flutter-apk/app-debug.apk` abgelegt.

## Progressive Web App und GitHub Pages

Die `web/`-Dateien enthalten den PWA-Einstiegspunkt, Manifest und Icons. Flutter
generiert beim Web-Build die JavaScript-/Canvas-Anwendung sowie den
Service-Worker für installierbares und zwischenspeicherbares PWA-Verhalten.
Die Stationsdaten sind als Asset gebündelt. KVB-Abfahrten und OSRM-Routen
benötigen weiterhin eine Internetverbindung.

Für das Repository `Frederik-Edel/kvb-live-monitor` liegt der automatische
Deployment-Workflow in `.github/workflows/deploy-pages.yml`. Ein Push auf
`main` baut die Anwendung mit dem nötigen Unterpfad
`/kvb-live-monitor/` und veröffentlicht `build/web` über GitHub Pages. Der
Workflow kann auch manuell über **Actions → Deploy Flutter PWA to GitHub
Pages → Run workflow** gestartet werden.

Zur ersten Aktivierung auf GitHub:

1. Repository erstellen und den App-Quellcode samt Workflow auf den Branch
   `main` pushen.
2. Unter **Settings → Pages → Build and deployment** als Quelle **GitHub
   Actions** auswählen.
3. Im Tab **Actions** den Deployment-Workflow erfolgreich laufen lassen.
4. Die veröffentlichte Website ist anschließend unter
   `https://frederik-edel.github.io/kvb-live-monitor/` erreichbar.

Das Repository wurde als privat gewünscht. GitHub Pages für private
Repositories ist nur bei Tarifen verfügbar, die Pages für private Repositories
unterstützen. Falls der Tarif das nicht unterstützt, muss das Repository
öffentlich werden oder ein anderer Hosting-Anbieter verwendet werden. Die
Website selbst kann je nach GitHub-Tarif öffentlich erreichbar sein, obwohl der
Quellcode privat bleibt.

Standortzugriff im Browser benötigt HTTPS und eine vom Benutzer erteilte
Berechtigung. Das native Android-Startbildschirm-Widget ist nicht Bestandteil
der Web-App. Der KVB-Endpunkt antwortet derzeit mit CORS-Freigaben; sollte der
Betreiber diese ändern, kann die Browser-App die Abfahrtsdaten nicht mehr direkt
laden. In diesem Fall ist ein eigener, regelkonformer Backend-Proxy erforderlich.
