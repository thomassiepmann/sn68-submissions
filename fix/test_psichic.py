"""
PSICHIC Standalone-Test
========================
Prüft ob PSICHIC korrekt läuft und echte, variierende Scores liefert.

Ausführen auf dem Server:
  cd /root/nova && python3 fix/test_psichic.py

Erwartetes Ergebnis:
  - Scores variieren (nicht alle identisch)
  - Min/Max/Std werden angezeigt
  - Kein ImportError / Modell-Fehler

Wenn alle Scores identisch sind → PSICHIC schlägt still fehl.
"""

import sys
import os
import time

BASE_DIR = "/root/nova"
sys.path.insert(0, BASE_DIR)

from dotenv import load_dotenv
load_dotenv("/root/nova/.env", override=True)

# --- Test-Moleküle (valide SMILES aus SAVI-2020, verschiedene Strukturen) ---
TEST_SMILES = [
    "CC(=O)Nc1ccc(O)cc1",                          # Paracetamol
    "CC12CCC3C(C1CCC2O)CCC4=CC(=O)CCC34C",         # Testosteron
    "O=C(O)c1ccccc1O",                              # Salicylsäure
    "CC(C)Cc1ccc(C(C)C(=O)O)cc1",                  # Ibuprofen
    "CN1C=NC2=C1C(=O)N(C(=O)N2C)C",               # Koffein
    "OC(=O)c1ccc(N)cc1",                           # 4-Aminobenzoesäure
    "CC(O)c1ccc(Cl)cc1",                           # Chloramphenicol-ähnlich
    "O=C(O)CC(O)(CC(=O)O)C(=O)O",                 # Zitronensäure
    "CC(=O)OC1=CC=CC=C1C(=O)O",                   # Aspirin
    "c1ccc2c(c1)cc1ccc3cccc4ccc2c1c34",            # Pyren
]

# Test-Protein (O15379 = HDAC3, aktuelle NOVA Zielprotein)
TEST_PROTEIN_CODE = "O15379"

def test_psichic():
    print("=" * 60)
    print("PSICHIC STANDALONE TEST")
    print("=" * 60)

    # 1. Import-Test
    print("\n[1/5] Import PsichicWrapper...")
    try:
        from PSICHIC.wrapper import PsichicWrapper
        print("    OK — PsichicWrapper importiert")
    except ImportError as e:
        print(f"    FEHLER: {e}")
        print("    Fix: cd /root/nova && pip install -r requirements.txt")
        return False

    # 2. Protein-Sequenz holen
    print(f"\n[2/5] Protein-Sequenz für {TEST_PROTEIN_CODE} laden...")
    try:
        from utils import get_sequence_from_protein_code
        t0 = time.time()
        sequence = get_sequence_from_protein_code(TEST_PROTEIN_CODE)
        print(f"    OK — Sequenz: {sequence[:40]}... ({len(sequence)} AA, {time.time()-t0:.1f}s)")
    except Exception as e:
        print(f"    FEHLER: {e}")
        return False

    # 3. Modell initialisieren
    print("\n[3/5] PSICHIC Modell initialisieren (run_challenge_start)...")
    try:
        t0 = time.time()
        model = PsichicWrapper()
        model.run_challenge_start(sequence)
        print(f"    OK — Modell geladen ({time.time()-t0:.1f}s)")
    except Exception as e:
        print(f"    FEHLER beim Laden: {e}")
        print("    Mögliche Ursache: Modell-Weights fehlen unter PSICHIC/trained_weights/")
        return False

    # 4. Scoring ausführen
    print(f"\n[4/5] Scoring von {len(TEST_SMILES)} Testmolekülen...")
    try:
        t0 = time.time()
        result = model.run_validation(TEST_SMILES)
        elapsed = time.time() - t0

        if isinstance(result, dict):
            if 'predicted_binding_affinity' in result:
                scores = result['predicted_binding_affinity']
            else:
                scores = list(result.values())[0]
        else:
            scores = result

        print(f"    OK — Scoring in {elapsed:.1f}s")
        print(f"    Ergebnis-Typ: {type(scores)}")

    except Exception as e:
        print(f"    FEHLER beim Scoring: {e}")
        import traceback
        traceback.print_exc()
        return False

    # 5. Score-Varianz prüfen (DER KRITISCHE TEST)
    print("\n[5/5] Score-Varianz prüfen...")
    try:
        import statistics
        score_list = list(scores) if hasattr(scores, '__iter__') else [scores]
        score_floats = [float(s) for s in score_list]

        print(f"\n    {'SMILES':<45} {'Score':>10}")
        print(f"    {'-'*55}")
        for smiles, score in zip(TEST_SMILES, score_floats):
            print(f"    {smiles[:45]:<45} {score:>10.4f}")

        print(f"\n    --- Statistik ---")
        print(f"    Min:    {min(score_floats):.4f}")
        print(f"    Max:    {max(score_floats):.4f}")
        print(f"    Mean:   {statistics.mean(score_floats):.4f}")
        if len(score_floats) > 1:
            print(f"    Stdev:  {statistics.stdev(score_floats):.4f}")

        # Urteil
        unique_scores = len(set(round(s, 4) for s in score_floats))
        print(f"\n    Einzigartige Scores: {unique_scores} von {len(score_floats)}")

        if unique_scores == 1:
            print("\n    *** PROBLEM: Alle Scores identisch! ***")
            print("    PSICHIC schlägt still fehl — liefert immer denselben Wert.")
            print("    Mögliche Ursachen:")
            print("    - Falsche Modell-Weights (TREAT1 statt TREAT2?)")
            print("    - CUDA/CPU-Inkompatibilität")
            print("    - run_challenge_start() nicht korrekt aufgerufen")
            print("    Debugging:")
            print("      cd /root/nova")
            print("      ls PSICHIC/trained_weights/")
            print("      python3 -c \"from PSICHIC.wrapper import PsichicWrapper; help(PsichicWrapper)\"")
            return False
        elif unique_scores < 3:
            print("\n    *** WARNUNG: Wenig Score-Varianz — möglicherweise defekt ***")
            return True
        else:
            print("\n    *** OK: PSICHIC liefert echte, variierende Scores ***")
            print("    Fix war erfolgreich!")
            return True

    except Exception as e:
        print(f"    FEHLER bei Score-Analyse: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_btdr():
    print("\n" + "=" * 60)
    print("BTDR TIMELOCK-VERSCHLÜSSELUNG TEST")
    print("=" * 60)

    print("\n[1/2] Import btdr...")
    try:
        from btdr import QuicknetBittensorDrandTimelock
        print("    OK — btdr importiert")
    except ImportError:
        print("    FEHLER: btdr nicht installiert")
        print("    Fix: pip install btdr")
        return False

    print("\n[2/2] Verschlüsselung testen...")
    try:
        bdt = QuicknetBittensorDrandTimelock()
        test_data = "CC(=O)Nc1ccc(O)cc1,c1ccc2c(c1)cc1ccc3cccc4ccc2c1c34"
        encrypted = bdt.encrypt(20, test_data, 27000000)
        enc_str = str(encrypted)

        print(f"    Verschlüsselt: {enc_str[:80]}...")
        if "stub_encrypted" in enc_str:
            print("    *** PROBLEM: Btdr liefert stub_encrypted — falsche Version? ***")
            return False
        else:
            print("    OK — echte Verschlüsselung (kein stub_encrypted)")
            return True
    except Exception as e:
        print(f"    FEHLER: {e}")
        return False


def test_github_token():
    print("\n" + "=" * 60)
    print("GITHUB TOKEN TEST")
    print("=" * 60)

    token = os.environ.get("GITHUB_TOKEN", "")
    owner = os.environ.get("GITHUB_REPO_OWNER", "")
    repo = os.environ.get("GITHUB_REPO_NAME", "")

    print(f"\n    Token: {token[:10]}... (Classic PAT: {token.startswith('ghp_')})")
    print(f"    Repo:  {owner}/{repo}")

    if not token.startswith("ghp_"):
        print("    *** WARNUNG: Kein Classic PAT (ghp_...)! ***")
        print("    Fine-grained PATs verursachen 403-Fehler beim Upload.")

    import requests
    r = requests.get(
        f"https://api.github.com/repos/{owner}/{repo}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10,
    )
    if r.status_code == 200:
        print(f"    OK — GitHub-Repo erreichbar")
        return True
    else:
        print(f"    FEHLER: HTTP {r.status_code} — {r.text[:100]}")
        return False


if __name__ == "__main__":
    results = {}
    results["psichic"] = test_psichic()
    results["btdr"]    = test_btdr()
    results["github"]  = test_github_token()

    print("\n" + "=" * 60)
    print("GESAMTERGEBNIS")
    print("=" * 60)
    for name, ok in results.items():
        status = "✓ OK" if ok else "✗ FEHLER"
        print(f"  {name:<15}: {status}")

    all_ok = all(results.values())
    print()
    if all_ok:
        print("Alle Tests bestanden — Miner sollte korrekt scoren.")
    else:
        print("Fehler gefunden — siehe Details oben.")
        sys.exit(1)
