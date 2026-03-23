"""
Enhanced NOVA SN68 Miner — Fixed Version
=========================================
Key fixes vs original enhanced_miner.py:
  1. Real btdr.QuicknetBittensorDrandTimelock encryption (not stub)
  2. Submits SMILES strings (not custom hex encoding)
  3. load_dotenv with absolute /root/nova/.env path
  4. Molecule pool: top-200 by (affinity - antitarget_weight * antitarget)
  5. No axon needed — NOVA uses GitHub-based submissions

Deploy:
  cp /root/nova/neurons/enhanced_miner.py /root/nova/neurons/enhanced_miner.py.bak
  cp /path/to/this/fix/enhanced_miner.py /root/nova/neurons/enhanced_miner.py
  cp /path/to/this/fix/github_utils.py /root/nova/utils/github.py
  pip install btdr
  pm2 restart sn68-miner
"""

import os
import sys
import math
import random
import argparse
import asyncio
import datetime
import tempfile
import traceback
import base64
import hashlib

from typing import Any, Dict, List, Optional, Tuple

from dotenv import load_dotenv

# Use absolute path so dotenv works regardless of working directory
load_dotenv("/root/nova/.env", override=True)

import bittensor as bt
from bittensor.core.errors import MetadataError
from substrateinterface import SubstrateInterface
from datasets import load_dataset
from huggingface_hub import list_repo_files
import pandas as pd

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.append(BASE_DIR)

from config.config_loader import load_config
from utils import (
    get_sequence_from_protein_code,
    upload_file_to_github,
    get_challenge_params_from_blockhash,
    get_heavy_atom_count,
    compute_maccs_entropy,
)
from PSICHIC.wrapper import PsichicWrapper
from btdr import QuicknetBittensorDrandTimelock

# Pool size: keep top N molecules between batches
POOL_SIZE = 200
ANTITARGET_WEIGHT = 0.9


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument('--network', default=os.getenv('SUBTENSOR_NETWORK'), help='Network to use')
    parser.add_argument('--netuid', type=int, default=68)
    bt.subtensor.add_args(parser)
    bt.logging.add_args(parser)
    bt.wallet.add_args(parser)

    config = bt.config(parser)
    config.update(load_config())

    config.full_path = os.path.expanduser(
        "{}/{}/{}/netuid{}/{}".format(
            config.logging.logging_dir,
            config.wallet.name,
            config.wallet.hotkey_str,
            config.netuid,
            'miner',
        )
    )
    os.makedirs(config.full_path, exist_ok=True)
    return config


def load_github_path() -> str:
    github_repo_name = os.environ.get('GITHUB_REPO_NAME')
    github_repo_branch = os.environ.get('GITHUB_REPO_BRANCH')
    github_repo_owner = os.environ.get('GITHUB_REPO_OWNER')
    github_repo_path = os.environ.get('GITHUB_REPO_PATH', '')

    if not github_repo_name or not github_repo_branch or not github_repo_owner:
        raise ValueError("Missing GitHub env vars: GITHUB_REPO_NAME, GITHUB_REPO_BRANCH, GITHUB_REPO_OWNER")

    if github_repo_path == "":
        github_path = f"{github_repo_owner}/{github_repo_name}/{github_repo_branch}"
    else:
        github_path = f"{github_repo_owner}/{github_repo_name}/{github_repo_branch}/{github_repo_path}"

    if len(github_path) > 100:
        raise ValueError(f"GitHub path too long ({len(github_path)} chars, max 100): {github_path}")

    return github_path


def stream_random_chunk_from_dataset(dataset_repo: str, chunk_size: int) -> Any:
    files = list_repo_files(dataset_repo, repo_type='dataset')
    files = [f for f in files if f.endswith('.csv')]
    random_file = random.choice(files)

    dataset_dict = load_dataset(
        dataset_repo,
        data_files={'train': random_file},
        streaming=True,
    )
    dataset = dataset_dict['train']
    return dataset.batch(chunk_size)


async def setup_bittensor_objects(config: argparse.Namespace) -> Tuple[Any, Any, Any, int, int]:
    bt.logging.info("Setting up Bittensor objects.")
    wallet = bt.wallet(config=config)
    bt.logging.info(f"Wallet: {wallet}")

    async with bt.async_subtensor(network=config.network) as subtensor:
        metagraph = await subtensor.metagraph(config.netuid)
        await metagraph.sync()
        bt.logging.info(f"Metagraph synced: {metagraph.n} neurons")

        miner_uid = metagraph.hotkeys.index(wallet.hotkey.ss58_address)
        bt.logging.info(f"Miner UID: {miner_uid}")

        node = SubstrateInterface(url=config.network)
        epoch_length = node.query("SubtensorModule", "Tempo", [config.netuid]).value + 1
        bt.logging.info(f"Epoch length: {epoch_length} blocks")

    return wallet, subtensor, metagraph, miner_uid, epoch_length


def _check_score_variance(scores: list, label: str) -> None:
    """
    Loggt Score-Varianz — wichtigster Indikator ob PSICHIC wirklich läuft.
    Wenn alle Scores identisch → PSICHIC schlägt still fehl.
    """
    if not scores:
        return
    unique = len(set(round(float(s), 4) for s in scores))
    mn, mx = min(float(s) for s in scores), max(float(s) for s in scores)
    if unique == 1:
        bt.logging.warning(
            f"[PSICHIC WARNUNG] {label}: ALLE {len(scores)} Scores identisch = {mn:.4f}! "
            f"PSICHIC schlägt still fehl — echte Scores würden variieren."
        )
    else:
        bt.logging.debug(
            f"[PSICHIC OK] {label}: {unique} einzigartige Scores, "
            f"min={mn:.4f} max={mx:.4f} range={mx-mn:.4f}"
        )


async def run_psichic_model_loop(state: Dict[str, Any]) -> None:
    """
    Continuously runs PSICHIC on batches from SAVI-2020.
    Maintains a pool of top-POOL_SIZE molecules by combined score.
    Submits near epoch end.
    """
    bt.logging.info("Starting PSICHIC inference loop.")
    state['batches_processed'] = 0

    dataset_iter = stream_random_chunk_from_dataset(
        dataset_repo=state['hugging_face_dataset_repo'],
        chunk_size=state['chunk_size']
    )

    while not state['shutdown_event'].is_set():
        try:
            for chunk in dataset_iter:
                if state['shutdown_event'].is_set():
                    break

                df = pd.DataFrame.from_dict(chunk)
                df['product_name'] = df['product_name'].apply(lambda x: x.replace('"', ''))
                df['product_smiles'] = df['product_smiles'].apply(lambda x: x.replace('"', ''))

                df['heavy_atoms'] = df['product_smiles'].apply(get_heavy_atom_count)
                df = df[df['heavy_atoms'] >= getattr(state['config'], 'min_heavy_atoms', 20)]
                if df.empty:
                    continue

                state['batches_processed'] = state.get('batches_processed', 0) + 1

                # Score targets
                target_scores = []
                for protein in state['current_challenge_targets']:
                    if protein not in state['psichic_models']:
                        await _init_psichic_model(state, protein, is_target=True)
                    if protein in state['psichic_models']:
                        scores = state['psichic_models'][protein].run_validation(
                            df['product_smiles'].tolist()
                        )
                        raw = scores['predicted_binding_affinity']
                        _check_score_variance(list(raw), f"target={protein} batch={state['batches_processed']}")
                        target_scores.append(raw)

                # Score antitargets
                antitarget_scores = []
                for protein in state['current_challenge_antitargets']:
                    if protein not in state['psichic_models']:
                        await _init_psichic_model(state, protein, is_target=False)
                    if protein in state['psichic_models']:
                        scores = state['psichic_models'][protein].run_validation(
                            df['product_smiles'].tolist()
                        )
                        antitarget_scores.append(scores['predicted_binding_affinity'])

                if not target_scores:
                    continue

                df['target_affinity'] = pd.DataFrame(target_scores).mean(axis=0)
                if antitarget_scores:
                    df['antitarget_affinity'] = pd.DataFrame(antitarget_scores).mean(axis=0)
                else:
                    df['antitarget_affinity'] = 0.0
                df['combined_score'] = (
                    df['target_affinity'] - ANTITARGET_WEIGHT * df['antitarget_affinity']
                )

                # Antitarget Score-Varianz prüfen
                for protein in state['current_challenge_antitargets']:
                    if protein in state['psichic_models']:
                        s = state['psichic_models'][protein].run_validation(
                            df['product_smiles'].tolist()[:5]  # nur 5 zur Überprüfung
                        )
                        _check_score_variance(
                            list(s['predicted_binding_affinity']),
                            f"antitarget={protein} batch={state['batches_processed']}"
                        )

                # Merge with existing pool
                pool = state['molecule_pool']
                pool = pd.concat([pool, df], ignore_index=True)
                pool = pool.sort_values('combined_score', ascending=False)
                pool = pool.drop_duplicates(subset=['product_smiles'])
                state['molecule_pool'] = pool.head(POOL_SIZE).reset_index(drop=True)

                best = state['molecule_pool']['combined_score'].iloc[0] if len(state['molecule_pool']) > 0 else 0
                bt.logging.info(
                    f"[Pool] {len(state['molecule_pool'])} Moleküle | "
                    f"Best={best:.4f} | "
                    f"Batch={state['batches_processed']} | "
                    f"Combined-Range: "
                    f"{df['combined_score'].min():.4f}…{df['combined_score'].max():.4f}"
                )

                # Check if close to epoch end
                current_block = await state['subtensor'].get_current_block()
                next_epoch_block = ((current_block // state['epoch_length']) + 1) * state['epoch_length']
                blocks_until_epoch = next_epoch_block - current_block

                if len(state['molecule_pool']) >= 10 and blocks_until_epoch <= 20:
                    top10 = state['molecule_pool'].head(10)
                    candidate = ','.join(top10['product_name'].tolist())
                    if candidate != state['last_submitted_product']:
                        bt.logging.info(
                            f"Epoch end in {blocks_until_epoch} blocks — submitting top-10 candidates"
                        )
                        state['candidate_product'] = candidate
                        try:
                            await submit_response(state)
                        except Exception as e:
                            bt.logging.error(f"Submission error: {e}")

                await asyncio.sleep(1)

        except StopIteration:
            bt.logging.info("Dataset exhausted — restarting stream")
            dataset_iter = stream_random_chunk_from_dataset(
                dataset_repo=state['hugging_face_dataset_repo'],
                chunk_size=state['chunk_size']
            )
        except Exception as e:
            bt.logging.error(f"Error in PSICHIC loop: {e}")
            traceback.print_exc()
            if "shutdown" in str(e).lower():
                state['shutdown_event'].set()
                break
            await asyncio.sleep(5)


async def _init_psichic_model(state: Dict, protein: str, is_target: bool) -> None:
    label = "target" if is_target else "antitarget"
    try:
        sequence = get_sequence_from_protein_code(protein)
        model = PsichicWrapper()
        model.run_challenge_start(sequence)
        state['psichic_models'][protein] = model
        bt.logging.info(f"Initialized PSICHIC for {label}: {protein}")
    except Exception as e:
        bt.logging.error(f"Failed to init PSICHIC for {label} {protein}: {e}")


async def submit_response(state: Dict[str, Any]) -> None:
    """
    Encrypts candidate SMILES with real btdr timelock encryption and uploads to GitHub.
    """
    candidate_product = state['candidate_product']
    if not candidate_product:
        bt.logging.warning("No candidate product to submit")
        return

    bt.logging.info(f"Submitting: {candidate_product[:80]}...")

    current_block = await state['subtensor'].get_current_block()

    # REAL timelock encryption via btdr
    encrypted_response = state['bdt'].encrypt(state['miner_uid'], candidate_product, current_block)
    bt.logging.info(f"Timelock encrypted at block {current_block}")

    content_str = str(encrypted_response)
    encoded_content = base64.b64encode(content_str.encode()).decode()
    filename = hashlib.sha256(content_str.encode()).hexdigest()[:20]
    commit_content = f"{state['github_path']}/{filename}.txt"

    bt.logging.info(f"Attempting chain commitment: {commit_content}")
    try:
        commitment_status = await state['subtensor'].set_commitment(
            wallet=state['wallet'],
            netuid=state['config'].netuid,
            data=commit_content
        )
    except MetadataError:
        bt.logging.info("Too soon to commit again — will retry next epoch end")
        return

    if commitment_status:
        bt.logging.info(f"Chain commitment OK: {commit_content}")
        github_status = upload_file_to_github(filename, encoded_content)
        if github_status:
            bt.logging.info(f"GitHub upload OK: {filename}.txt")
            state['last_submitted_product'] = candidate_product
            state['last_submission_time'] = datetime.datetime.now()
        else:
            bt.logging.error(f"GitHub upload FAILED for {filename}")
    else:
        bt.logging.warning("Chain commitment returned False — not uploading to GitHub")


async def run_miner(config: argparse.Namespace) -> None:
    wallet, subtensor, metagraph, miner_uid, epoch_length = await setup_bittensor_objects(config)

    state: Dict[str, Any] = {
        'config': config,
        'hugging_face_dataset_repo': 'Metanova/SAVI-2020',
        'chunk_size': 128,
        'github_path': load_github_path(),
        'wallet': wallet,
        'subtensor': subtensor,
        'metagraph': metagraph,
        'miner_uid': miner_uid,
        'epoch_length': epoch_length,
        'psichic_models': {},
        'bdt': QuicknetBittensorDrandTimelock(),
        'molecule_pool': pd.DataFrame(columns=['product_name', 'product_smiles', 'combined_score']),
        'candidate_product': None,
        'last_submitted_product': None,
        'last_submission_time': None,
        'shutdown_event': asyncio.Event(),
        'current_challenge_targets': [],
        'last_challenge_targets': [],
        'current_challenge_antitargets': [],
        'last_challenge_antitargets': [],
    }

    bt.logging.info("Entering main miner loop.")

    current_block = await subtensor.get_current_block()
    last_boundary = (current_block // epoch_length) * epoch_length
    next_boundary = last_boundary + epoch_length

    if next_boundary - current_block < 20:
        bt.logging.info("Too close to epoch end — waiting for next epoch")
        block_to_check = next_boundary
        await asyncio.sleep(12 * 10)
    else:
        block_to_check = last_boundary

    block_hash = await subtensor.determine_block_hash(block_to_check)
    startup_proteins = get_challenge_params_from_blockhash(
        block_hash=block_hash,
        weekly_target=config.weekly_target,
        num_antitargets=config.num_antitargets
    )

    if startup_proteins:
        state['current_challenge_targets'] = startup_proteins["targets"]
        state['last_challenge_targets'] = startup_proteins["targets"]
        state['current_challenge_antitargets'] = startup_proteins["antitargets"]
        state['last_challenge_antitargets'] = startup_proteins["antitargets"]
        bt.logging.info(
            f"Startup targets: {startup_proteins['targets']}, "
            f"antitargets: {startup_proteins['antitargets']}"
        )

        for protein in startup_proteins["targets"] + startup_proteins["antitargets"]:
            is_t = protein in startup_proteins["targets"]
            await _init_psichic_model(state, protein, is_target=is_t)

        state['inference_task'] = asyncio.create_task(run_psichic_model_loop(state))
        bt.logging.info("Inference task started.")

    while True:
        try:
            current_block = await subtensor.get_current_block()

            if current_block % epoch_length == 0:
                bt.logging.info(f"Epoch boundary at block {current_block}")

                block_hash = await subtensor.determine_block_hash(current_block)
                new_proteins = get_challenge_params_from_blockhash(
                    block_hash=block_hash,
                    weekly_target=config.weekly_target,
                    num_antitargets=config.num_antitargets
                )

                if new_proteins and (
                    new_proteins["targets"] != state['last_challenge_targets'] or
                    new_proteins["antitargets"] != state['last_challenge_antitargets']
                ):
                    state['current_challenge_targets'] = new_proteins["targets"]
                    state['last_challenge_targets'] = new_proteins["targets"]
                    state['current_challenge_antitargets'] = new_proteins["antitargets"]
                    state['last_challenge_antitargets'] = new_proteins["antitargets"]
                    bt.logging.info(
                        f"New challenge — targets: {new_proteins['targets']}, "
                        f"antitargets: {new_proteins['antitargets']}"
                    )

                # Cancel old inference
                if 'inference_task' in state and not state['inference_task'].done():
                    state['shutdown_event'].set()
                    await state['inference_task']

                # Reset state for new epoch
                state['molecule_pool'] = pd.DataFrame(
                    columns=['product_name', 'product_smiles', 'combined_score']
                )
                state['candidate_product'] = None
                state['last_submitted_product'] = None
                state['shutdown_event'] = asyncio.Event()

                for protein in (
                    state['current_challenge_targets'] + state['current_challenge_antitargets']
                ):
                    is_t = protein in state['current_challenge_targets']
                    await _init_psichic_model(state, protein, is_target=is_t)

                state['inference_task'] = asyncio.create_task(run_psichic_model_loop(state))
                bt.logging.info("New inference task started for new epoch.")

            if current_block % 60 == 0:
                await metagraph.sync()
                bt.logging.info(
                    f"Block: {metagraph.block.item()} | "
                    f"Neurons: {metagraph.n} | "
                    f"Epoch: {metagraph.block.item() // epoch_length}"
                )

            await asyncio.sleep(1)

        except KeyboardInterrupt:
            bt.logging.success("KeyboardInterrupt — shutting down.")
            break
        except RuntimeError as e:
            bt.logging.error(f"RuntimeError: {e}")
            traceback.print_exc()


async def main() -> None:
    config = parse_arguments()
    bt.logging(config=config, logging_dir=config.full_path)
    bt.logging.info(f"Running NOVA SN68 miner (fixed) on network: {config.subtensor.network}")
    await run_miner(config)


if __name__ == "__main__":
    asyncio.run(main())
