# GOAL #0 — Tägliche Miner-Strategie-Anpassung

## Zweck
Arbos analysiert 1× täglich die letzten Miner-Logs und passt `/root/nova/config/strategy.json`
mit optimierten Parametern an. Kein unkontrolliertes Laufen, keine Code-Änderungen.

## Trigger
Cron-ähnlich: einmal täglich, z.B. 03:00 UTC (zwischen Epochen, kein Submissionsdruck).

---

## Eingaben (nur Lesen — keine Schreibrechte auf Logs)

| Datei | Inhalt |
|---|---|
| `/root/.pm2/logs/sn68-miner-out.log` | PSICHIC Scores, Pool-Updates, Submissions, Fehler |
| `/root/nova/logs/miner-stats.log` | (optional) Zusammengefasste Score-Statistiken |
| `/root/nova/config/strategy.json` | Aktuelle Parameter (Quelle und Ziel) |

---

## Ausgabe (nur eine Datei wird beschrieben)

**`/root/nova/config/strategy.json`** — angepasste Parameter:

```json
{
  "chunk_size": 128,
  "antitarget_weight": 0.5,
  "entropy_threshold": 2.5,
  "min_heavy_atoms": 20,
  "num_molecules": 10,
  "last_updated": "2026-03-23T03:00:00Z",
  "reason": "PSICHIC OK, Score-Varianz hoch — chunk_size erhöht"
}
```

---

## Analyse-Logik (Schritt für Schritt)

### Schritt 1 — Logs einlesen
```
Lese die letzten 500 Zeilen von /root/.pm2/logs/sn68-miner-out.log
```

### Schritt 2 — PSICHIC-Status erkennen
- Suche nach `[PSICHIC OK]` und `[PSICHIC WARNUNG]`
- Falls nur WARNUNGen, kein `OK`: PSICHIC defekt → Parameteranpassung hat keinen Effekt → Abbrechen + Telegram-Alarm

### Schritt 3 — Score-Entwicklung analysieren
- Extrahiere `New best score: X.XXXX` Zeilen der letzten 24h
- Berechne: Trend (steigend/fallend/stagnierend), Max-Score, Anzahl Updates

### Schritt 4 — Parameter-Empfehlung

| Situation | Anpassung |
|---|---|
| Score stagiert (< 3 Updates / 24h) | `chunk_size` × 1.5 (max 512) |
| Score fällt | `antitarget_weight` − 0.1 (min 0.2) |
| Score steigt stark | Parameter beibehalten |
| Entropy niedrig (< 1.5 im Log) | `entropy_threshold` − 0.3 |
| Viele `Error initializing model` | `chunk_size` ÷ 2 (Speicherschonung) |

### Schritt 5 — strategy.json schreiben
- Lese aktuelle `strategy.json`
- Passe maximal **2 Parameter** an (kein Radikalumbau)
- Schreibe Änderung mit `last_updated` Timestamp und `reason` (1 Satz)
- Kein Neustart des Miners — der Miner liest `strategy.json` beim nächsten Epochenwechsel

### Schritt 6 — Telegram-Report

Sende an Telegram-Bot (Token + Chat-ID aus `/root/nova/.env`):

```
SN68 Miner Tagesreport 📊

Status: ✅ PSICHIC OK / ⚠️ PSICHIC defekt
Best Score (24h): X.XXXX
Score-Updates: N

Änderungen strategy.json:
  chunk_size: 128 → 192
  Grund: Score stagiert, weniger als 3 Updates/24h

Nächster Report: morgen 03:00 UTC
```

---

## Harte Constraints

| Constraint | Wert |
|---|---|
| Max. Chutes-Calls pro Tag | **1** (die Analyse selbst) |
| Code-Änderungen | **Verboten** — nur strategy.json |
| Miner-Neustart | **Verboten** — Arbos startet PM2 nicht |
| Dateien außer strategy.json schreiben | **Verboten** |
| Parameter-Änderungen pro Lauf | Max. **2** |
| Läuft unkontrolliert / in Schleife | **Verboten** — einmal täglich, dann Stop |

---

## Fehlerbehandlung

- Falls `/root/.pm2/logs/sn68-miner-out.log` nicht existiert → Telegram-Alarm, kein strategy.json schreiben
- Falls PSICHIC ausschließlich WARNUNGen → Telegram-Alarm mit Text `PSICHIC defekt — manuelle Diagnose nötig: python3 fix/test_psichic.py`, kein strategy.json schreiben
- Falls strategy.json Schreibfehler → Telegram-Alarm, Original-Datei nicht überschreiben

---

## Deployment auf Server

```bash
# strategy.json initial anlegen (falls noch nicht vorhanden):
cat > /root/nova/config/strategy.json <<'EOF'
{
  "chunk_size": 128,
  "antitarget_weight": 0.5,
  "entropy_threshold": 2.5,
  "min_heavy_atoms": 20,
  "num_molecules": 10,
  "last_updated": null,
  "reason": "Initialwerte"
}
EOF

# Arbos-Goal aktivieren:
# Dieses GOAL.md in das Arbos-Goals-Verzeichnis kopieren und als GOAL #0 setzen.
```

---

## Erwartetes Ergebnis nach 7 Tagen
- strategy.json enthält angepasste Parameter basierend auf tatsächlichem Score-Verhalten
- Tägliche Telegram-Reports zeigen Score-Trend
- Kein manuelles Eingreifen nötig außer bei PSICHIC-Fehlern
