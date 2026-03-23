#!/bin/bash
# deploy.sh — Deploy fixed NOVA SN68 miner
# Run this on the server: bash /root/nova/fix/deploy.sh
# Or: bash <(curl -s https://raw.githubusercontent.com/thomassiepmann/sn68-submissions/claude/fix-nova-miner-JTslb/fix/deploy.sh)

set -e

NOVA_DIR="/root/nova"
FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== NOVA SN68 Miner Fix Deployment ==="
echo "Nova dir: $NOVA_DIR"
echo "Fix dir:  $FIX_DIR"

# 1. Check btdr is installed (required for real timelock encryption)
echo ""
echo "[1/5] Checking btdr installation..."
if ! python3 -c "from btdr import QuicknetBittensorDrandTimelock" 2>/dev/null; then
    echo "    Installing btdr..."
    cd "$NOVA_DIR"
    if [ -d ".venv" ]; then
        .venv/bin/pip install btdr
    else
        pip install btdr
    fi
    echo "    btdr installed OK"
else
    echo "    btdr already installed OK"
fi

# 2. Verify GITHUB_TOKEN is a Classic PAT
echo ""
echo "[2/5] Checking GitHub token..."
TOKEN=$(grep GITHUB_TOKEN "$NOVA_DIR/.env" | cut -d= -f2 | tr -d '"' | tr -d "'")
if [ -z "$TOKEN" ]; then
    echo "    ERROR: GITHUB_TOKEN not found in $NOVA_DIR/.env"
    echo "    Create a Classic PAT at https://github.com/settings/tokens"
    echo "    Add to .env: GITHUB_TOKEN=ghp_..."
    exit 1
elif [[ "$TOKEN" == ghp_* ]]; then
    echo "    Token OK (Classic PAT: ${TOKEN:0:10}...)"
else
    echo "    WARNING: Token starts with '${TOKEN:0:10}' — not a Classic PAT!"
    echo "    Fine-grained PATs cause 403 errors. Create a Classic PAT at:"
    echo "    https://github.com/settings/tokens (Tokens classic)"
    echo "    Then update .env: GITHUB_TOKEN=ghp_..."
    read -p "    Continue anyway? (y/N): " cont
    [[ "$cont" == "y" || "$cont" == "Y" ]] || exit 1
fi

# 3. Backup and deploy fixed files
echo ""
echo "[3/5] Deploying fixed miner files..."

# Backup originals
cp "$NOVA_DIR/neurons/enhanced_miner.py" "$NOVA_DIR/neurons/enhanced_miner.py.bak.$(date +%Y%m%d_%H%M%S)"
cp "$NOVA_DIR/utils/github.py" "$NOVA_DIR/utils/github.py.bak.$(date +%Y%m%d_%H%M%S)"

# Deploy fixed versions
cp "$FIX_DIR/enhanced_miner.py" "$NOVA_DIR/neurons/enhanced_miner.py"
cp "$FIX_DIR/github_utils.py" "$NOVA_DIR/utils/github.py"
echo "    Files deployed OK"

# 4. Test GitHub token
echo ""
echo "[4/5] Testing GitHub connection..."
cd "$NOVA_DIR"
python3 -c "
import os
from dotenv import load_dotenv
load_dotenv('/root/nova/.env', override=True)
token = os.getenv('GITHUB_TOKEN', 'NOT_FOUND')
owner = os.getenv('GITHUB_REPO_OWNER', 'NOT_FOUND')
repo = os.getenv('GITHUB_REPO_NAME', 'NOT_FOUND')
branch = os.getenv('GITHUB_REPO_BRANCH', 'main')
print(f'  Token: {token[:10]}... (Classic PAT: {token.startswith(\"ghp_\")})')
print(f'  Repo:  {owner}/{repo} @ {branch}')
import requests
r = requests.get(
    f'https://api.github.com/repos/{owner}/{repo}',
    headers={'Authorization': f'Bearer {token}', 'Accept': 'application/vnd.github+json'}
)
if r.status_code == 200:
    print(f'  GitHub connection OK')
else:
    print(f'  GitHub connection FAILED: HTTP {r.status_code}')
    print(f'  Response: {r.text[:200]}')
"

# 5. Restart miner
echo ""
echo "[5/5] Restarting sn68-miner..."
pm2 restart sn68-miner
sleep 3
pm2 logs sn68-miner --lines 20 --nostream

echo ""
echo "=== Deployment complete ==="
echo "Monitor with: pm2 logs sn68-miner --lines 50"
echo "Check on-chain: btcli wallet overview --wallet.name sn68-metanova --wallet.hotkey sn68 --subtensor.network finney"
