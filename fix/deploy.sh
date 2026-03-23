#!/bin/bash
# deploy.sh — Deploy fixed NOVA SN68 miner
# Ausführen auf dem Server:
#   cd /root/nova && bash fix/deploy.sh
# Oder direkt aus GitHub:
#   bash <(curl -s https://raw.githubusercontent.com/thomassiepmann/sn68-submissions/claude/fix-nova-miner-JTslb/fix/deploy.sh)

set -e

NOVA_DIR="/root/nova"
FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================"
echo " NOVA SN68 Miner Fix Deployment"
echo " $(date)"
echo "======================================================"
echo " Nova dir: $NOVA_DIR"
echo " Fix dir:  $FIX_DIR"

# ── 1. btdr installieren ──────────────────────────────────
echo ""
echo "[1/6] btdr (Timelock-Verschlüsselung) prüfen..."
if python3 -c "from btdr import QuicknetBittensorDrandTimelock; print('OK')" 2>/dev/null; then
    echo "    btdr bereits installiert"
else
    echo "    btdr nicht gefunden — installiere..."
    cd "$NOVA_DIR"
    if [ -d ".venv" ]; then
        .venv/bin/pip install btdr -q
    else
        pip install btdr -q
    fi
    # Validieren
    if python3 -c "from btdr import QuicknetBittensorDrandTimelock" 2>/dev/null; then
        echo "    btdr installiert OK"
    else
        echo "    FEHLER: btdr Installation fehlgeschlagen!"
        echo "    Versuche: pip install --upgrade btdr"
        exit 1
    fi
fi

# btdr Stub-Check
enc_test=$(python3 -c "
from btdr import QuicknetBittensorDrandTimelock
bdt = QuicknetBittensorDrandTimelock()
r = str(bdt.encrypt(20, 'CC(=O)Nc1ccc(O)cc1', 27000000))
print('stub' if 'stub_encrypted' in r else 'real')
" 2>/dev/null)
if [ "$enc_test" = "stub" ]; then
    echo "    WARNUNG: btdr liefert stub_encrypted — falsche Version?"
    echo "    Versuche Upgrade: pip install --upgrade btdr"
    pip install --upgrade btdr -q 2>/dev/null || true
elif [ "$enc_test" = "real" ]; then
    echo "    btdr liefert echte Verschlüsselung OK"
fi

# ── 2. GitHub Token prüfen ────────────────────────────────
echo ""
echo "[2/6] GitHub Token prüfen..."
TOKEN=$(python3 -c "
import os; from dotenv import load_dotenv
load_dotenv('/root/nova/.env', override=True)
print(os.getenv('GITHUB_TOKEN',''))
" 2>/dev/null)

if [ -z "$TOKEN" ]; then
    echo "    FEHLER: GITHUB_TOKEN nicht in /root/nova/.env"
    echo "    → Classic PAT erstellen: https://github.com/settings/tokens"
    echo "    → In .env eintragen: GITHUB_TOKEN=ghp_..."
    exit 1
elif [[ "$TOKEN" == ghp_* ]]; then
    echo "    Token OK (Classic PAT: ${TOKEN:0:10}...)"
else
    echo "    WARNUNG: Token ist ${TOKEN:0:10}... — kein Classic PAT (ghp_...)!"
    echo "    Fine-grained PATs verursachen 403 Fehler beim Upload."
    echo "    Classic PAT erstellen: https://github.com/settings/tokens → Tokens (classic)"
    read -p "    Trotzdem fortfahren? (j/N): " cont
    [[ "$cont" == "j" || "$cont" == "J" ]] || exit 1
fi

# ── 3. PSICHIC Test VOR dem Deploy ───────────────────────
echo ""
echo "[3/6] PSICHIC Score-Varianz Test (vor Deploy)..."
cd "$NOVA_DIR"
psichic_before="unbekannt"
if python3 fix/test_psichic.py > /tmp/psichic_before.log 2>&1; then
    psichic_before="OK"
    echo "    PSICHIC läuft korrekt"
else
    psichic_before="FEHLER"
    echo "    PSICHIC-Test fehlgeschlagen — Details:"
    grep -E "WARNUNG|FEHLER|PROBLEM|identisch" /tmp/psichic_before.log | head -10
fi

# ── 4. Backup + Deploy ───────────────────────────────────
echo ""
echo "[4/6] Backup und Deploy..."
ts=$(date +%Y%m%d_%H%M%S)

if [ -f "$NOVA_DIR/neurons/enhanced_miner.py" ]; then
    cp "$NOVA_DIR/neurons/enhanced_miner.py" "$NOVA_DIR/neurons/enhanced_miner.py.bak.$ts"
    echo "    Backup: enhanced_miner.py.bak.$ts"
fi
if [ -f "$NOVA_DIR/utils/github.py" ]; then
    cp "$NOVA_DIR/utils/github.py" "$NOVA_DIR/utils/github.py.bak.$ts"
    echo "    Backup: github.py.bak.$ts"
fi

cp "$FIX_DIR/enhanced_miner.py" "$NOVA_DIR/neurons/enhanced_miner.py"
cp "$FIX_DIR/github_utils.py"   "$NOVA_DIR/utils/github.py"
cp "$FIX_DIR/test_psichic.py"   "$NOVA_DIR/fix/test_psichic.py" 2>/dev/null || \
cp "$FIX_DIR/test_psichic.py"   "$NOVA_DIR/test_psichic.py"
echo "    Dateien deployed"

# Verify deploy
grep -q "QuicknetBittensorDrandTimelock" "$NOVA_DIR/neurons/enhanced_miner.py" && \
    echo "    Verify: btdr-Import gefunden OK" || \
    echo "    WARNUNG: btdr-Import nicht gefunden in enhanced_miner.py!"

grep -q "stub_encrypted" "$NOVA_DIR/neurons/enhanced_miner.py" && \
    echo "    WARNUNG: stub_encrypted noch im Code!" || \
    echo "    Verify: kein stub_encrypted mehr OK"

# ── 5. Miner neustarten ──────────────────────────────────
echo ""
echo "[5/6] sn68-miner neustarten..."
pm2 restart sn68-miner
sleep 5
echo ""
echo "    Erste Log-Zeilen nach Neustart:"
pm2 logs sn68-miner --lines 15 --nostream 2>/dev/null

# ── 6. Post-Deploy Check ─────────────────────────────────
echo ""
echo "[6/6] Post-Deploy Verifikation (warte 30s auf ersten Batch)..."
sleep 30

echo ""
echo "    Log-Check auf Score-Varianz:"
grep -i "psichic\|pool\|score\|batch\|warnung\|range" \
  /root/.pm2/logs/sn68-miner-out.log 2>/dev/null | tail -15

echo ""
echo "    Stub-Encrypt noch aktiv?"
if grep -q "stub_encrypted" /root/.pm2/logs/sn68-miner-out.log 2>/dev/null; then
    echo "    WARNUNG: stub_encrypted noch in Logs — ggf. alter Prozess"
else
    echo "    OK: kein stub_encrypted in Logs"
fi

# ── Zusammenfassung ───────────────────────────────────────
echo ""
echo "======================================================"
echo " DEPLOY ABGESCHLOSSEN"
echo "======================================================"
echo ""
echo " PSICHIC vor Deploy: $psichic_before"
echo ""
echo " Nächste Schritte:"
echo "   # Score-Varianz überwachen (wichtigster Test!):"
echo "   pm2 logs sn68-miner --lines 100 | grep -i 'psichic\|pool\|score'"
echo ""
echo "   # Wenn '[PSICHIC OK]' → echte Scores, Fix funktioniert"
echo "   # Wenn '[PSICHIC WARNUNG] identisch' → PSICHIC defekt, mehr Debugging:"
echo "   cd /root/nova && python3 fix/test_psichic.py"
echo "   ls PSICHIC/trained_weights/"
echo ""
echo "   # On-Chain nach 2-3 Epochen prüfen (~2-3h):"
echo "   btcli wallet overview --wallet.name sn68-metanova --wallet.hotkey sn68 --subtensor.network finney"
echo ""
echo "   # Vollständige Diagnose:"
echo "   bash fix/diagnose.sh 2>&1 | tee /tmp/diagnose.log"
