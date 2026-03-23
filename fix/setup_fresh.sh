#!/bin/bash
# setup_fresh.sh — Komplett-Setup auf leerem Targon-Pod (Ubuntu, kein persistenter Storage)
# ===========================================================================================
# Ausführen als root:
#   bash <(curl -fsSL https://raw.githubusercontent.com/thomassiepmann/sn68-submissions/claude/fix-nova-miner-JTslb/fix/setup_fresh.sh)
# Oder nach git clone:
#   bash /root/nova/fix/setup_fresh.sh
#
# Voraussetzungen (Umgebungsvariablen setzen VOR dem Ausführen):
#   export GITHUB_TOKEN=ghp_...
#
# Idempotent: mehrfaches Ausführen ist sicher.

set -euo pipefail

NOVA_DIR="/root/nova"
NOVA_REPO="https://github.com/metanova-labs/nova"
FIX_BRANCH="claude/fix-nova-miner-JTslb"
FIX_REPO="https://github.com/thomassiepmann/sn68-submissions"

# Konfiguration — aus Umgebungsvariablen oder Defaults
WALLET_NAME="${WALLET_NAME:-sn68-metanova}"
HOTKEY_NAME="${HOTKEY_NAME:-sn68}"
SUBTENSOR_URL="${SUBTENSOR_URL:-wss://entrypoint-finney.opentensor.ai:443}"
GITHUB_REPO="${GITHUB_REPO:-thomassiepmann/sn68-submissions}"
GITHUB_BRANCH="${GITHUB_BRANCH:-main}"

# ── Farben ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
OK()   { echo -e "    ${GREEN}OK${NC}  $*"; }
WARN() { echo -e "    ${YELLOW}WARN${NC} $*"; }
ERR()  { echo -e "    ${RED}ERR${NC}  $*"; }
STEP() { echo -e "\n${BLUE}[$1/$TOTAL_STEPS]${NC} $2"; }

TOTAL_STEPS=10
ISSUES=()  # Gesammelte Probleme für Abschlussbericht

echo "======================================================"
echo " NOVA SN68 — Fresh Pod Setup"
echo " $(date)"
echo "======================================================"
echo " Nova-Dir:      $NOVA_DIR"
echo " Wallet:        $WALLET_NAME / $HOTKEY_NAME"
echo " Subtensor:     $SUBTENSOR_URL"
echo " GitHub-Repo:   $GITHUB_REPO ($GITHUB_BRANCH)"
echo "======================================================"

# ── Voraussetzungen prüfen ─────────────────────────────────────────────────
if [ -z "${GITHUB_TOKEN:-}" ]; then
    ERR "GITHUB_TOKEN ist nicht gesetzt!"
    echo ""
    echo "  Bitte setzen:"
    echo "    export GITHUB_TOKEN=ghp_..."
    echo "  Dann erneut ausführen."
    exit 1
fi

# ── 1. System-Dependencies ─────────────────────────────────────────────────
STEP 1 "System-Dependencies installieren"

apt-get update -qq 2>/dev/null || WARN "apt-get update fehlgeschlagen — fortfahren"

PKGS_MISSING=()
for pkg in git python3 python3-pip curl; do
    command -v "$pkg" &>/dev/null || PKGS_MISSING+=("$pkg")
done
# pip kann als pip3 vorhanden sein
command -v pip3 &>/dev/null && pip3 --version &>/dev/null && PKGS_MISSING=("${PKGS_MISSING[@]/python3-pip}")

if [ ${#PKGS_MISSING[@]} -gt 0 ]; then
    echo "    Installiere: ${PKGS_MISSING[*]}"
    apt-get install -y -qq "${PKGS_MISSING[@]}" 2>/dev/null
else
    OK "git, python3, pip bereits vorhanden"
fi

# Node.js + npm
if ! command -v node &>/dev/null || ! command -v npm &>/dev/null; then
    echo "    Installiere Node.js + npm..."
    # NodeSource LTS
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - &>/dev/null
    apt-get install -y -qq nodejs 2>/dev/null
    OK "Node.js $(node --version), npm $(npm --version)"
else
    OK "Node.js $(node --version), npm $(npm --version) bereits vorhanden"
fi

# ── 2. PM2 installieren ────────────────────────────────────────────────────
STEP 2 "PM2 global installieren"

if command -v pm2 &>/dev/null; then
    OK "PM2 bereits installiert ($(pm2 --version))"
else
    npm install -g pm2 -q
    OK "PM2 $(pm2 --version) installiert"
fi

# ── 3. Nova-Repo klonen ────────────────────────────────────────────────────
STEP 3 "Nova-Repo klonen ($NOVA_REPO)"

if [ -d "$NOVA_DIR/.git" ]; then
    OK "$NOVA_DIR bereits vorhanden — überspringe Clone"
    cd "$NOVA_DIR"
    git pull --ff-only origin main 2>/dev/null && OK "git pull OK" || WARN "git pull fehlgeschlagen (offline?)"
else
    git clone "$NOVA_REPO" "$NOVA_DIR"
    OK "Geklont nach $NOVA_DIR"
fi

cd "$NOVA_DIR"

# Fix-Scripts holen (falls noch nicht vorhanden — z.B. direkt via curl gestartet)
FIX_DIR="$NOVA_DIR/fix"
if [ ! -f "$FIX_DIR/official_miner.py" ]; then
    echo "    Fix-Dateien von GitHub holen..."
    mkdir -p "$FIX_DIR"
    BASE_RAW="https://raw.githubusercontent.com/thomassiepmann/sn68-submissions/$FIX_BRANCH/fix"
    for f in official_miner.py official_btdr.py; do
        curl -fsSL "$BASE_RAW/$f" -o "$FIX_DIR/$f"
    done
    OK "Fix-Dateien heruntergeladen"
else
    OK "Fix-Dateien bereits vorhanden ($FIX_DIR)"
fi

# ── 4. Dependencies installieren ──────────────────────────────────────────
STEP 4 "Python-Dependencies installieren (install_deps_cpu.sh)"

if [ -f "$NOVA_DIR/install_deps_cpu.sh" ]; then
    # Idempotent: nur ausführen wenn wichtige Pakete fehlen
    if python3 -c "import bittensor" &>/dev/null 2>&1; then
        OK "bittensor bereits installiert — überspringe install_deps_cpu.sh"
    else
        echo "    Führe install_deps_cpu.sh aus (kann einige Minuten dauern)..."
        bash "$NOVA_DIR/install_deps_cpu.sh" 2>&1 | tail -5
        OK "install_deps_cpu.sh abgeschlossen"
    fi
else
    WARN "install_deps_cpu.sh nicht gefunden — installiere Basis-Pakete manuell"
    pip install bittensor timelock cryptography python-dotenv requests -q
    ISSUES+=("install_deps_cpu.sh nicht gefunden — manuelle Basis-Installation")
fi

# Zusatz-Dependencies für den Miner
pip install timelock cryptography python-dotenv requests -q 2>/dev/null || true
OK "Basis-Dependencies sichergestellt"

# ── 5. .env anlegen ───────────────────────────────────────────────────────
STEP 5 ".env anlegen"

ENV_FILE="$NOVA_DIR/.env"

if [ -f "$ENV_FILE" ]; then
    # Idempotent: vorhandene .env updaten (Werte überschreiben, neue hinzufügen)
    echo "    $ENV_FILE vorhanden — aktualisiere Werte..."
    backup_env="${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$ENV_FILE" "$backup_env"
    OK "Backup: $backup_env"
fi

# Funktion: Zeile in .env setzen (überschreiben oder anhängen)
set_env_var() {
    local key="$1" val="$2"
    if [ -f "$ENV_FILE" ] && grep -q "^${key}=" "$ENV_FILE"; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$ENV_FILE"
    else
        echo "${key}=${val}" >> "$ENV_FILE"
    fi
}

touch "$ENV_FILE"
set_env_var "GITHUB_TOKEN"   "$GITHUB_TOKEN"
set_env_var "WALLET_NAME"    "$WALLET_NAME"
set_env_var "HOTKEY_NAME"    "$HOTKEY_NAME"
set_env_var "SUBTENSOR_URL"  "$SUBTENSOR_URL"
set_env_var "GITHUB_REPO"    "$GITHUB_REPO"
set_env_var "GITHUB_BRANCH"  "$GITHUB_BRANCH"

OK ".env angelegt/aktualisiert:"
grep -v "TOKEN" "$ENV_FILE" | sed 's/^/      /'
echo "      GITHUB_TOKEN=${GITHUB_TOKEN:0:10}... (maskiert)"

# ── 6. Fix-Dateien deployen ───────────────────────────────────────────────
STEP 6 "Fix-Dateien deployen (btdr.py + neurons/miner.py)"

TS=$(date +%Y%m%d_%H%M%S)

# btdr.py → /root/nova/btdr.py
if [ -f "$NOVA_DIR/btdr.py" ]; then
    cp "$NOVA_DIR/btdr.py" "$NOVA_DIR/btdr.py.bak.$TS"
    OK "Backup: btdr.py.bak.$TS"
fi
cp "$FIX_DIR/official_btdr.py" "$NOVA_DIR/btdr.py"
OK "btdr.py → offiziell"

# neurons/miner.py
mkdir -p "$NOVA_DIR/neurons"
if [ -f "$NOVA_DIR/neurons/miner.py" ]; then
    cp "$NOVA_DIR/neurons/miner.py" "$NOVA_DIR/neurons/miner.py.bak.$TS"
    OK "Backup: neurons/miner.py.bak.$TS"
fi
cp "$FIX_DIR/official_miner.py" "$NOVA_DIR/neurons/miner.py"
OK "neurons/miner.py → offiziell"

# Auch enhanced_miner.py setzen (Fallback falls PM2 das aufruft)
cp "$FIX_DIR/official_miner.py" "$NOVA_DIR/neurons/enhanced_miner.py"
OK "neurons/enhanced_miner.py → offiziell"

# Syntax-Check
python3 -m py_compile "$NOVA_DIR/btdr.py"         && OK "btdr.py: Syntax OK"          || { ERR "btdr.py: SYNTAX FEHLER!"; ISSUES+=("btdr.py Syntax-Fehler!"); }
python3 -m py_compile "$NOVA_DIR/neurons/miner.py" && OK "neurons/miner.py: Syntax OK" || { ERR "neurons/miner.py: SYNTAX FEHLER!"; ISSUES+=("neurons/miner.py Syntax-Fehler!"); }

# ── 7. config/strategy.json anlegen ───────────────────────────────────────
STEP 7 "config/strategy.json anlegen"

mkdir -p "$NOVA_DIR/config"
STRATEGY_FILE="$NOVA_DIR/config/strategy.json"

if [ -f "$STRATEGY_FILE" ]; then
    OK "strategy.json bereits vorhanden — nicht überschreiben"
    cat "$STRATEGY_FILE" | sed 's/^/      /'
else
    cat > "$STRATEGY_FILE" <<'EOF'
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
    OK "strategy.json mit Initialwerten angelegt"
fi

# ── 8. Wallet-Verzeichnis ─────────────────────────────────────────────────
STEP 8 "Wallet-Verzeichnis anlegen"

WALLET_DIR="/root/.bittensor/wallets/$WALLET_NAME"
HOTKEY_DIR="$WALLET_DIR/hotkeys"
COLDKEY_FILE="$WALLET_DIR/coldkeypub.txt"
HOTKEY_FILE="$HOTKEY_DIR/$HOTKEY_NAME"

mkdir -p "$HOTKEY_DIR"
OK "Verzeichnis erstellt: $WALLET_DIR"

WALLET_MISSING=false
if [ ! -f "$COLDKEY_FILE" ]; then
    WARN "coldkeypub.txt fehlt: $COLDKEY_FILE"
    WALLET_MISSING=true
fi
if [ ! -f "$HOTKEY_FILE" ]; then
    WARN "Hotkey fehlt: $HOTKEY_FILE"
    WALLET_MISSING=true
fi

if [ "$WALLET_MISSING" = true ]; then
    ISSUES+=("Wallet-Keys fehlen — MANUELL kopieren (siehe unten)")
fi

# ── 9. PM2 Miner starten ──────────────────────────────────────────────────
STEP 9 "PM2 Miner starten"

cd "$NOVA_DIR"

# Ecosystem-File suchen (bevorzugt), sonst direkter Start
if [ -f "$NOVA_DIR/ecosystem.config.js" ]; then
    PM2_START_CMD="pm2 start ecosystem.config.js"
    PM2_CONFIG="ecosystem.config.js"
elif [ -f "$NOVA_DIR/pm2.config.js" ]; then
    PM2_START_CMD="pm2 start pm2.config.js"
    PM2_CONFIG="pm2.config.js"
else
    PM2_START_CMD="pm2 start neurons/miner.py --name sn68-miner --interpreter python3 -- --wallet.name $WALLET_NAME --wallet.hotkey $HOTKEY_NAME --subtensor.chain_endpoint $SUBTENSOR_URL"
    PM2_CONFIG="direkter Start"
fi

echo "    Methode: $PM2_CONFIG"

if pm2 describe sn68-miner &>/dev/null 2>&1; then
    echo "    sn68-miner bereits registriert — restarte..."
    pm2 restart sn68-miner
    OK "pm2 restart sn68-miner"
else
    echo "    Starte sn68-miner neu..."
    eval "$PM2_START_CMD"
    OK "pm2 start OK"
fi

pm2 save --force
OK "pm2 save"

# pm2 startup (idempotent)
pm2 startup 2>/dev/null | grep -E "sudo|systemctl" | bash 2>/dev/null || \
    pm2 startup systemd -u root --hp /root 2>/dev/null | tail -1 | bash 2>/dev/null || \
    OK "pm2 startup (bereits konfiguriert oder kein sudo nötig)"

# ── 10. Erste Log-Ausgabe ──────────────────────────────────────────────────
STEP 10 "Erste 30 Sekunden Logs"

echo "    Warte 30s auf Miner-Start..."
sleep 30

echo ""
echo "------------------------------------------------------"
echo " PM2 Status:"
echo "------------------------------------------------------"
pm2 list 2>/dev/null | grep -E "sn68|name|online|error" || pm2 list

echo ""
echo "------------------------------------------------------"
echo " Letzte Logs:"
echo "------------------------------------------------------"
pm2 logs sn68-miner --lines 40 --nostream 2>/dev/null || \
    cat /root/.pm2/logs/sn68-miner-out.log 2>/dev/null | tail -40 || \
    WARN "Noch keine Logs verfügbar"

# ── Abschlussbericht ───────────────────────────────────────────────────────
echo ""
echo "======================================================"
echo " SETUP ABGESCHLOSSEN"
echo "======================================================"
echo ""

if [ ${#ISSUES[@]} -eq 0 ]; then
    echo -e " ${GREEN}Alles OK — keine manuellen Schritte nötig.${NC}"
else
    echo -e " ${YELLOW}Folgende Punkte erfordern manuelle Aktion:${NC}"
    echo ""
    for i in "${!ISSUES[@]}"; do
        echo -e "  ${YELLOW}$((i+1)).${NC} ${ISSUES[$i]}"
    done
fi

echo ""
echo "======================================================"
echo " WALLET-KEYS — MANUELL KOPIEREN"
echo "======================================================"
echo ""
echo "  Die Wallet-Keys können NICHT automatisch angelegt werden."
echo "  Ohne gültige Keys startet der Miner, aber kann nicht submitten."
echo ""
echo "  Ziel-Pfade auf diesem Pod:"
echo "    Coldkey:  /root/.bittensor/wallets/$WALLET_NAME/coldkeypub.txt"
echo "    Hotkey:   /root/.bittensor/wallets/$WALLET_NAME/hotkeys/$HOTKEY_NAME"
echo ""
echo "  Optionen:"
echo "    A) Von anderem Server kopieren:"
echo "       scp -r user@SERVER:/root/.bittensor/wallets/$WALLET_NAME \\"
echo "         /root/.bittensor/wallets/"
echo ""
echo "    B) Aus Backup wiederherstellen:"
echo "       tar -xzf wallet-backup.tar.gz -C /root/.bittensor/wallets/"
echo ""
echo "    C) Aus Mnemonic neu erzeugen:"
echo "       btcli wallet regen_coldkey --wallet.name $WALLET_NAME"
echo "       btcli wallet regen_hotkey  --wallet.name $WALLET_NAME --wallet.hotkey $HOTKEY_NAME"
echo ""
echo "  Nach dem Kopieren der Keys:"
echo "    pm2 restart sn68-miner"
echo ""
echo "======================================================"
echo " MONITORING"
echo "======================================================"
echo ""
echo "  Live-Logs:          pm2 logs sn68-miner"
echo "  PSICHIC-Status:     pm2 logs sn68-miner --lines 100 | grep -i psichic"
echo "  Score-Entwicklung:  pm2 logs sn68-miner --lines 100 | grep -i 'best score'"
echo "  On-Chain prüfen:    btcli wallet overview --wallet.name $WALLET_NAME --wallet.hotkey $HOTKEY_NAME"
echo ""
echo "  Re-Deploy (Updates):"
echo "    cd $NOVA_DIR && bash fix/deploy_official.sh"
echo ""
