#!/bin/bash
# diagnose.sh — Vollständige Serverdiagnose für NOVA SN68 Miner
# Ausführen: bash /root/nova/fix/diagnose.sh 2>&1 | tee /tmp/diagnose.log
# Dann: cat /tmp/diagnose.log | head -200

NOVA_DIR="/root/nova"
cd "$NOVA_DIR" || exit 1

echo "======================================================"
echo " NOVA SN68 MINER DIAGNOSE — $(date)"
echo "======================================================"

# --- PM2 Status ---
echo ""
echo "[PM2] Prozess-Status:"
pm2 list 2>/dev/null | grep -E "sn68|watch|monitor|arbos"

# --- Letzte Logs ---
echo ""
echo "[LOGS] Letzte 30 Zeilen sn68-miner:"
pm2 logs sn68-miner --lines 30 --nostream 2>/dev/null

# --- Score-Varianz aus Logs ---
echo ""
echo "[PSICHIC] Score-Varianz in Logs (letzter Run):"
grep -i "psichic\|score\|pool\|batch\|warnung\|OK\|range" \
  /root/.pm2/logs/sn68-miner-out.log 2>/dev/null | tail -30

# --- Submissions prüfen ---
echo ""
echo "[SUBMISSIONS] Letzte GitHub-Submissions:"
grep -i "upload\|commit\|github\|submitted\|encrypted" \
  /root/.pm2/logs/sn68-miner-out.log 2>/dev/null | tail -20

# --- Fehler in Logs ---
echo ""
echo "[FEHLER] Errors & Warnings:"
grep -i "error\|exception\|traceback\|fail\|403\|401" \
  /root/.pm2/logs/sn68-miner-out.log 2>/dev/null | tail -30
grep -i "error\|exception\|traceback\|fail" \
  /root/.pm2/logs/sn68-miner-error.log 2>/dev/null | tail -20

# --- .env prüfen ---
echo ""
echo "[ENV] /root/nova/.env Konfiguration:"
if [ -f "$NOVA_DIR/.env" ]; then
    grep -v "^#" "$NOVA_DIR/.env" | grep -v "^$" | while IFS= read -r line; do
        key=$(echo "$line" | cut -d= -f1)
        val=$(echo "$line" | cut -d= -f2-)
        # Token zensieren
        if echo "$key" | grep -qi "token\|password\|secret\|key"; then
            echo "  $key=${val:0:10}... (zensiert)"
        else
            echo "  $line"
        fi
    done
else
    echo "  NICHT GEFUNDEN: $NOVA_DIR/.env"
fi

# --- Python-Packages ---
echo ""
echo "[PACKAGES] Kritische Python-Packages:"
for pkg in btdr bittensor torch psichic dotenv datasets huggingface_hub; do
    version=$(python3 -c "import $pkg; print(getattr($pkg,'__version__','?'))" 2>/dev/null)
    if [ -z "$version" ]; then
        echo "  $pkg: NICHT INSTALLIERT"
    else
        echo "  $pkg: $version"
    fi
done

# --- PSICHIC Weights ---
echo ""
echo "[PSICHIC] Model Weights:"
ls -lh "$NOVA_DIR/PSICHIC/trained_weights/" 2>/dev/null || echo "  Verzeichnis nicht gefunden"
find "$NOVA_DIR/PSICHIC/trained_weights/" -name "*.pt" -exec ls -lh {} \; 2>/dev/null

# --- Miner Code Version ---
echo ""
echo "[CODE] Aktueller Miner-Code (erste 10 Zeilen enhanced_miner.py):"
head -10 "$NOVA_DIR/neurons/enhanced_miner.py" 2>/dev/null

echo ""
echo "[CODE] Verwendete Verschlüsselung:"
grep -n "encrypt\|stub\|btdr\|timelock" "$NOVA_DIR/neurons/enhanced_miner.py" 2>/dev/null | head -10

echo ""
echo "[CODE] load_dotenv Aufruf:"
grep -rn "load_dotenv" "$NOVA_DIR/neurons/" "$NOVA_DIR/utils/" 2>/dev/null

# --- On-Chain Status ---
echo ""
echo "[CHAIN] On-Chain Status UID 20:"
python3 -c "
import bittensor as bt
try:
    sub = bt.subtensor(network='finney')
    n = sub.neuron_for_uid(20, 68)
    print(f'  Active:    {n.active}')
    print(f'  Axon:      {n.axon_info}')
    print(f'  Incentive: {n.incentive}')
    print(f'  Trust:     {n.trust}')
    print(f'  Stake:     {n.stake}')
except Exception as e:
    print(f'  FEHLER: {e}')
" 2>/dev/null

# --- PSICHIC Standalone-Test ---
echo ""
echo "[TEST] PSICHIC Score-Varianz Test:"
python3 fix/test_psichic.py 2>/dev/null || echo "  test_psichic.py nicht gefunden oder Fehler"

echo ""
echo "======================================================"
echo " DIAGNOSE ABGESCHLOSSEN"
echo "======================================================"
echo ""
echo "Wichtigste Prüfpunkte:"
echo "  1. [PSICHIC] Score-Varianz: Variieren die Scores? (nein = kaputt)"
echo "  2. [CODE] encrypt: 'stub_encrypted' oder echte btdr-Verschlüsselung?"
echo "  3. [CHAIN] Incentive > 0 nach mehreren Epochen?"
echo "  4. [FEHLER] Gibt es PSICHIC/btdr Import-Fehler?"
