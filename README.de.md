# NTNX-vm-write-stats-collector

Ein read-only Bash-Tool zur Erfassung von VM-Write-I/O-Statistiken aus Prism Central. Das Script löst VMs über Prism-Central-Kategorien auf, fragt historische VM-Statistiken über die Nutanix-v4-REST-APIs ab und erzeugt Auswertungen für Write-Bandwidth, gemessenes Datenvolumen und optionale Kostenszenarien.

[English documentation](README.md)

Dieses Projekt ist ein unabhängiges Hilfsprogramm. Es ist kein offizielles Nutanix-Produkt, kein offizielles Support-Tool und keine Aussage zur Produktsupportability.

## Funktionen

* VMs über eine oder mehrere Prism-Central-Kategorien auflösen.
* VM-Write-Bandwidth-Statistiken über die Categories-, VMM- und Stats-APIs abfragen.
* Interaktiv oder im Parameter-Modus ohne Konfigurationsprompts ausführen.
* Passwort verdeckt abfragen; Passwörter werden niemals als Kommandozeilenargument akzeptiert.
* Aggregierte durchschnittliche, P95- und Peak-Write-Raten berechnen.
* Gemessenes Sample-Volumen und optionale Kostenszenarien berechnen.
* Mehrere Zeitfenster wie `1h`, `24h`, `7d` oder `4w` in einem Lauf auswerten.
* Detaillierte VM-Samples, Zuordnungen, Diagnosedaten und rohe API-Antworten speichern.
* CSV-Ausgabe mit locale-unabhängigem US- oder deutschem Format erzeugen.

## Wichtige fachliche Einordnung

Das Script verwendet die VM-Metrik `controllerWriteIoBandwidthKbps` als Workload-Write-Sizing-Proxy. Es wird keine Storage-Kapazität in GB/TB ausgewertet. Die Ergebnisse beschreiben Write-Bandwidth in kB/s sowie daraus abgeleitetes Datenvolumen und Szenarien. Die Metrik ist kein direkter Zähler für Azure-Netzwerktraffic, SyncRep, Abrechnung oder replizierte Bytes. Data Reduction, Replikations-Overhead, Metadaten, Retransmissions und Protokoll-Overhead werden durch dieses Tool nicht separat hergeleitet.

Die Option `--capacity-aggregation PEAK` ist eine technische Bezeichnung im Script. Sie wählt die `MAX`-Aggregation der Write-Bandwidth-Rate und bedeutet nicht, dass Storage-Kapazität gemessen wird.

Fehlende VM-Statistiken werden als fehlend ausgewiesen und nicht stillschweigend als null behandelt. Ein Volumenfenster erhält die Kennzeichnung `partial`, wenn der angeforderte Zeitraum länger ist als die von Prism Central gelieferten Daten. Fehlende Zeit wird nicht extrapoliert.

## Voraussetzungen

* Bash 4 oder neuer.
* `curl`.
* `jq`.
* Standardwerkzeuge: `awk`, `sed`, `sort`, `date` und `mktemp`.
* Ein Prism-Central-Konto mit Leseberechtigung für die VM-Konfiguration und historischen Statistiken.

Unter macOS ist die mitgelieferte System-Bash möglicherweise älter als Bash 4. Mit Homebrew können die benötigten Werkzeuge beispielsweise so installiert werden:

```bash
brew install bash jq
```

## Schnellstart

Repository klonen und Scripts ausführbar machen:

```bash
git clone https://github.com/mheistruevers/NTNX-vm-write-stats-collector.git
cd NTNX-vm-write-stats-collector
chmod +x nutanix_category_vm_write_stats_v1.4.1.sh
```

Optionen anzeigen:

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh --help
```

Interaktiv ausführen:

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh
```

## Nicht-interaktiver Parameter-Modus

Auch im Parameter-Modus wird das Prism-Central-Passwort verdeckt abgefragt. Das Passwort darf nicht in der Kommandozeile, in einem Script oder in einer Repository-Datei stehen.

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh \
  --host pc.example.com \
  --port 9440 \
  --categories-api-version v4.4 \
  --vmm-api-version v4.3 \
  --user 'admin@example.com' \
  --category 'DR=Critical' \
  --match-mode OR \
  --lookback 7d \
  --sampling-interval 60 \
  --capacity-aggregation PEAK \
  --calculate-cost yes \
  --price-per-gb 0.009 \
  --volume-windows '1h,24h,7d' \
  --csv-format de \
  --verify-tls yes \
  --confirm-read-only
```

Das Flag `--confirm-read-only` ist im Parameter-Modus verpflichtend, weil das Script potenziell viele schreibgeschützte API-Aufrufe ausführt.

Für einen verkürzten Validierungslauf:

```bash
./nutanix_category_vm_write_stats_v1.4.1.sh \
  --dry-run \
  --host pc.example.com \
  --user 'admin@example.com' \
  --category 'DR=Critical' \
  --lookback 24h \
  --confirm-read-only
```

Der Dry-Run validiert die Konfiguration, authentifiziert sich und führt die Vorabprüfungen des Scripts aus. Die vollständige Statistikabfrage wird dabei nicht durchgeführt.

Für wiederholbare lokale Läufe ist ein bereinigter Environment-Variable-Launcher enthalten:

```bash
export PRISM_CENTRAL_HOST='pc.example.com'
export PRISM_CENTRAL_USER='admin@example.com'
export VM_CATEGORY='DR=Critical'
./examples/non-interactive-example.sh
```

Der Launcher speichert und übergibt kein Passwort. Das Collector-Script fragt es weiterhin verdeckt ab.

## Zeitbereiche und Volumenfenster

`--lookback` bestimmt, wie viele historische Daten angefordert werden, zum Beispiel `24h`, `7d` oder `4w`.

`--volume-windows` bestimmt, für welche Zeitfenster aus den gelieferten Samples ein Report berechnet wird. Mehrere Fenster werden kommasepariert angegeben:

```bash
--lookback 7d --volume-windows '1h,24h,7d'
```

Wird `--volume-windows '4w'` zusammen mit `--lookback 7d` verwendet, kann der 4-Wochen-Report nur die verfügbaren 7-Tage-Daten verwenden und wird als `partial` markiert. Für ein vollständiges 4-Wochen-Fenster muss mindestens `--lookback 28d` angefordert werden.

Alternativ kann ein konkreter RFC-3339-Zeitraum angegeben werden:

```bash
--start '2026-11-23T00:00:00Z' \
--end '2026-11-24T00:00:00Z'
```

`--lookback` darf nicht zusammen mit `--start`/`--end` verwendet werden.

## Ausgabestruktur

Jeder Lauf erstellt standardmäßig ein zeitgestempeltes Ausgabeverzeichnis. Mit `--output-dir` kann ein eigenes Ziel angegeben werden:

```text
nutanix-category-stats-YYYYMMDDTHHMMSSZ/
├── run_summary.txt
├── calculation_methodology.txt
├── aggregate_capacity_summary.csv
├── aggregate_volume_summary.csv
├── volume_windows.csv
├── details/
│   ├── write_samples_capacity.csv
│   ├── write_samples_volume.csv
│   ├── selected_vms.tsv
│   └── category_matches.tsv
└── diagnostics/
    ├── run.log
    ├── stats_diagnostics.txt
    └── raw_api_responses/
```

Die Feldbeschreibungen und Hinweise zur Interpretation stehen in [docs/output-format.md](docs/output-format.md).

## TLS und Zugangsdaten

Die TLS-Prüfung sollte aktiviert bleiben, wenn Prism Central ein vertrauenswürdiges Zertifikat verwendet. `--verify-tls no` sollte nur in einer kontrollierten Laborumgebung oder bei einem selbstsignierten Zertifikat eingesetzt werden.

Folgende Inhalte dürfen niemals committed werden:

* Prism-Central-Passwörter.
* API-Tokens.
* Private Schlüssel oder Zertifikate.
* Reale Kundenausgaben.
* Lokale `.env`-Dateien oder Shell-History mit Secrets.

Die `.gitignore`-Datei schließt typische generierte Daten, Logs und lokale Secret-Dateien aus. Vor jedem Push sollte trotzdem `git diff` sowie `git diff --cached` geprüft werden.

## Validierung

Lokale Syntax- und Ausführbarkeitsprüfungen starten:

```bash
./tests/validate.sh
```

Der GitHub-Actions-Workflow führt dieselben Prüfungen bei Pushes und Pull Requests aus.

## Repository-Status und Lizenz

Das Repository bildet den aktuellen Projektstand als Version `1.4.1` ab. Das bereitgestellte Script wird absichtlich so übernommen, wie es vorliegt; die interne Versionsanzeige des Scripts kann weiterhin die Quellscript-Version ausgeben.

Das Repository steht unter der MIT-Lizenz. Der vollständige Lizenztext steht in [LICENSE](LICENSE). Die Software wird ohne Gewährleistung bereitgestellt. Hinweise zu Sicherheitsmeldungen stehen in [SECURITY.md](SECURITY.md), Beiträge sind in [CONTRIBUTING.md](CONTRIBUTING.md) beschrieben.