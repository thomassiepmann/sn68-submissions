#!/bin/bash
# deploy_official.sh — Ersetzt enhanced_miner.py + btdr.py durch offizielle Versionen
# =====================================================================================
# Ausführen auf dem Server:
#   cd /root/nova && bash fix/deploy_official.sh 2>&1 | tee /tmp/deploy_official.log
#
# Oder direkt von GitHub (ohne lokalen Checkout):
#   bash <(curl -fsSL https://raw.githubusercontent.com/thomassiepmann/sn68-submissions/claude/fix-nova-miner-JTslb/fix/deploy_official.sh)

set -euo pipefail

NOVA_DIR="/root/nova"
FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS=$(date +%Y%m%d_%H%M%S)

echo "======================================================"
echo " NOVA SN68 — Offizieller Miner Deploy"
echo " $(date)"
echo "======================================================"

cd "$NOVA_DIR"

# ── 1. Fix-Dateien holen (falls direkt von GitHub via curl ausgeführt) ─────
if [ ! -f "$FIX_DIR/official_miner.py" ]; then
    echo ""
    echo "[1/6] Fix-Dateien von GitHub holen..."
    mkdir -p /tmp/nova-fix
    BASE_URL="https://raw.githubusercontent.com/thomassiepmann/sn68-submissions/claude/fix-nova-miner-JTslb/fix"
    curl -fsSL "$BASE_URL/official_miner.py" -o /tmp/nova-fix/official_miner.py
    curl -fsSL "$BASE_URL/official_btdr.py"  -o /tmp/nova-fix/official_btdr.py
    FIX_DIR="/tmp/nova-fix"
    echo "    Dateien heruntergeladen."
else
    echo "[1/6] Fix-Dateien vorhanden ($FIX_DIR)"
fi

# ── 2. Dependencies prüfen ─────────────────────────────────────────────────
echo ""
echo "[2/6] Dependencies prüfen..."

# timelock (Pflicht für btdr.py)
if python3 -c "import timelock" 2>/dev/null; then
    echo "    timelock: OK"
else
    echo "    timelock nicht installiert — installiere..."
    pip install timelock -q
fi

# cryptography
if python3 -c "from cryptography.fernet import Fernet" 2>/dev/null; then
    echo "    cryptography: OK"
else
    pip install cryptography -q
fi

# btdr package (optional — wird durch btdr.py ersetzt, aber falls importiert)
python3 -c "from btdr import QuicknetBittensorDrandTimelock; print('    btdr package: OK')" 2>/dev/null || \
    echo "    btdr package nicht installiert (OK — nutzen btdr.py direkt)"

# ── 3. Backup ─────────────────────────────────────────────────────────────
echo ""
echo "[3/6] Backup..."
[ -f "$NOVA_DIR/neurons/enhanced_miner.py" ] && \
    cp "$NOVA_DIR/neurons/enhanced_miner.py" "$NOVA_DIR/neurons/enhanced_miner.py.bak.$TS" && \
    echo "    Backup: enhanced_miner.py.bak.$TS"

[ -f "$NOVA_DIR/neurons/miner.py" ] && \
    cp "$NOVA_DIR/neurons/miner.py" "$NOVA_DIR/neurons/miner.py.bak.$TS" && \
    echo "    Backup: miner.py.bak.$TS"

[ -f "$NOVA_DIR/btdr.py" ] && \
    cp "$NOVA_DIR/btdr.py" "$NOVA_DIR/btdr.py.bak.$TS" && \
    echo "    Backup: btdr.py.bak.$TS"

# ── 4. Deploy offizielle Dateien ──────────────────────────────────────────
echo ""
echo "[4/6] Deploy..."

# btdr.py: offizielle Implementierung (echte Timelock-Verschlüsselung)
cp "$FIX_DIR/official_btdr.py" "$NOVA_DIR/btdr.py"
echo "    btdr.py ersetzt durch offizielle Version"

# enhanced_miner.py: offizielles miner.py als neue Basis
cp "$FIX_DIR/official_miner.py" "$NOVA_DIR/neurons/enhanced_miner.py"
echo "    neurons/enhanced_miner.py ersetzt durch offizielles miner.py"

# Auch neurons/miner.py aktualisieren (falls PM2 das direkt aufruft)
cp "$FIX_DIR/official_miner.py" "$NOVA_DIR/neurons/miner.py"
echo "    neurons/miner.py auch aktualisiert"

# ── 5. Verify deploy ──────────────────────────────────────────────────────
echo ""
echo "[5/6] Verify..."
echo ""
echo "    btdr.py — QuicknetBittensorDrandTimelock vorhanden:"
grep -c "QuicknetBittensorDrandTimelock" "$NOVA_DIR/btdr.py" && echo "    OK" || echo "    FEHLER"

echo "    btdr.py — kein stub_encrypted:"
grep -c "stub_encrypted" "$NOVA_DIR/btdr.py" 2>/dev/null && echo "    WARNUNG: stub_encrypted gefunden!" || echo "    OK (kein stub)"

echo ""
echo "    enhanced_miner.py — offizieller Import:"
grep -c "from btdr import QuicknetBittensorDrandTimelock" "$NOVA_DIR/neurons/enhanced_miner.py" && echo "    OK" || echo "    FEHLER"

echo "    enhanced_miner.py — PSICHIC Varianz-Log:"
grep -c "PSICHIC OK\|PSICHIC WARNUNG" "$NOVA_DIR/neurons/enhanced_miner.py" && echo "    OK" || echo "    nicht vorhanden"

# Schneller Python-Syntax-Check
echo ""
python3 -m py_compile "$NOVA_DIR/btdr.py" && echo "    btdr.py: Syntax OK" || echo "    btdr.py: SYNTAX FEHLER!"
python3 -m py_compile "$NOVA_DIR/neurons/enhanced_miner.py" && echo "    enhanced_miner.py: Syntax OK" || echo "    enhanced_miner.py: SYNTAX FEHLER!"

# ── 6. PM2 Restart + Logs ──────────────────────────────────────────────────
echo ""
echo "[6/6] PM2 sn68-miner neustarten..."
pm2 restart sn68-miner
echo "    Restart-Befehl gesendet. Warte 8s..."
sleep 8

echo ""
echo "======================================================"
echo " ERSTE LOGS NACH NEUSTART:"
echo "======================================================"
pm2 logs sn68-miner --lines 40 --nostream 2>/dev/null

echo ""
echo "======================================================"
echo " DEPLOY ABGESCHLOSSEN — Was jetzt tun?"
echo "======================================================"
echo ""
echo " 1) PSICHIC Score-Varianz überwachen (WICHTIGSTER TEST):"
echo "    pm2 logs sn68-miner --lines 100 | grep -i 'psichic'"
echo "    → '[PSICHIC OK] ... einzigartige Scores' = Fix erfolgreich"
echo "    → '[PSICHIC WARNUNG] identisch' = PSICHIC noch defekt"
echo ""
echo " 2) Live-Logs:"
echo "    pm2 logs sn68-miner"
echo ""
echo " 3) Falls PSICHIC noch defekt → TREAT1 Weights neu laden:"
echo "    wget -O /root/nova/PSICHIC/trained_weights/TREAT1/model.pt \\"
echo "      https://huggingface.co/Metanova/TREAT-1/resolve/main/model.pt"
echo "    pm2 restart sn68-miner"
echo ""
echo " 4) btdr Verschlüsselung testen:"
echo "    python3 -c \""
echo "    from btdr import QuicknetBittensorDrandTimelock"
echo "    b = QuicknetBittensorDrandTimelock()"
echo "    r = b.encrypt(20, 'CC(=O)Nc1ccc(O)cc1', 3700000)"
echo "    print('OK:', type(r), str(r)[:60])"
echo "    \""
