#!/usr/bin/env python3
# Offizielle btdr.py von metanova-labs/nova
# Quelle: https://raw.githubusercontent.com/metanova-labs/nova/main/btdr.py
# Credits: Rhef
from concurrent.futures import ThreadPoolExecutor
from typing import Dict, Tuple, Optional, List
import asyncio
import base64
import hashlib
import logging
import secrets
import time

from cryptography.fernet import Fernet
import os
import requests
import timelock
import bittensor as bt

logger = logging.getLogger(__name__)


class TooEarly(RuntimeError):
    pass


class DrandClient:
    """Class for Drand-based timelock encryption and decryption."""

    RETRY_LIMIT = 30
    RETRY_BACKOFF_S = 2

    def __init__(self, base_urls: List[str]):
        """Initialize a requests session and list of base URLs for failover."""
        self.session: requests.Session = requests.Session()
        self.base_urls = list(base_urls)
        self._idx = 0

    def get(self, round_number: int, retry_if_too_early=False) -> str:
        """Fetch the randomness for a given round, using cache to prevent duplicate requests."""
        a = 0
        while a <= self.RETRY_LIMIT:
            a += 1
            base = self.base_urls[self._idx % len(self.base_urls)]
            try:
                response: requests.Response = self.session.get(
                    f"{base}/public/{round_number}", timeout=8
                )
            except requests.exceptions.RequestException as e:
                bt.logging.warning(
                    f"drand endpoint error on {base}: {e}; rotating"
                )
                self._idx += 1
                time.sleep(self.RETRY_BACKOFF_S)
                continue
            if response.status_code == 200:
                break
            elif response.status_code in (404, 425):
                bt.logging.debug(f"Randomness for round {round_number} is not yet available.")
                if not retry_if_too_early:
                    try:
                        response.raise_for_status()
                    except Exception as e:
                        raise TooEarly() from e
            elif response.status_code >= 500:
                bt.logging.debug(f'{response.status_code} {response} {response.headers} {response.text}')
                self._idx += 1
            time.sleep(self.RETRY_BACKOFF_S)
            continue
        response.raise_for_status()
        bt.logging.debug(f"Got randomness for round {round_number} successfully.")
        return response.json()


class AbstractBittensorDrandTimelock:
    """Class for Drand-based timelock encryption and decryption using the timelock library."""
    DRAND_URLS: List[str] = [
        "https://api.drand.sh",
        "https://drand.cloudflare.com",
        "https://api2.drand.sh",
    ]
    EPOCH_LENGTH = 361  # Number of blocks per epoch

    def __init__(self) -> None:
        """Initialize the Timelock client."""
        self.tl = timelock.Timelock(self.PK_HEX)
        env_urls = os.environ.get("DRAND_URLS")
        urls = [u.strip() for u in env_urls.split(",")] if env_urls else self.DRAND_URLS
        base_urls = [f"{u}/{self.CHAIN}" for u in urls if u]
        self.drand_client = DrandClient(base_urls)

    def _get_drand_round_info(self, round_number: int, cache: Dict[int, str]):
        if not (round_info := cache.get(round_number)):
            try:
                round_info = cache[round_number] = self.drand_client.get(round_number)
            except ValueError:
                raise RuntimeError(f"Randomness for round {round_number} is not yet available.")
        return round_info

    def _get_drand_signature(self, round_number: int, cache: Dict[int, str]) -> str:
        return bytearray.fromhex(
            self._get_drand_round_info(round_number, cache)['signature']
        )

    def get_current_round(self) -> int:
        return int(time.time() - self.NET_START) // self.ROUND_DURATION

    def encrypt(self, uid: int, message: str, current_block: int) -> Tuple[int, bytes]:
        """
        Encrypt a message with a future Drand round key, prefixing it with the UID.
        The target round is calculated to be within the last 10 blocks of the competition.
        """
        next_epoch_boundary = ((current_block // self.EPOCH_LENGTH) + 1) * self.EPOCH_LENGTH
        target_block = next_epoch_boundary - 10
        target_round: int = self.get_current_round() + ((target_block - current_block) * 4)

        bt.logging.info(f"Encrypting message for UID {uid}... Unlockable at round {target_round} (block {target_block})")

        prefixed_message: str = f"{uid}:{message}"
        sk = secrets.token_bytes(32)
        ciphertext: bytes = self.tl.tle(target_round, prefixed_message, sk)

        return target_round, ciphertext

    def decrypt(self, uid: int, ciphertext: bytes, target_round: int, signature: Optional[str] = None) -> Optional[str]:
        """Attempt to decrypt a single message, verifying the UID prefix."""
        if not signature:
            try:
                signature: bytes = self._get_drand_signature(target_round, {})
            except RuntimeError as e:
                bt.logging.error(e)
                raise

        bt.logging.info(f"Decrypting message for UID {uid} at round {target_round}...")
        plaintext = self.tl.tld(ciphertext, signature).decode()

        expected_prefix = f"{uid}:"
        if not plaintext.startswith(expected_prefix):
            bt.logging.warning(f"UID mismatch: Expected {expected_prefix} but got {plaintext}")
            return None

        return plaintext[len(expected_prefix):]

    def decrypt_dict(self, encrypted_dict: Dict[int, Tuple[int, bytes]]) -> Dict[int, Optional[str]]:
        """Decrypt a dictionary of {uid: (target_round, encrypted_payload)}."""
        decrypted_dict: Dict[int, Optional[bytes]] = {}
        cache: Dict[int, str] = {}

        for uid, (target_round, ciphertext) in encrypted_dict.items():
            try:
                signature = self._get_drand_signature(target_round, cache)
                decrypted_dict[uid] = self.decrypt(uid, ciphertext, target_round, signature)
            except RuntimeError:
                current_round = self.get_current_round()
                bt.logging.warning(f"Skipping UID {uid}: Too early to decrypt: {target_round=}, {current_round=}")
                decrypted_dict[uid] = None
                continue
            except ValueError:
                bt.logging.warning(f"Skipping UID {uid}: Invalid ciphertext")
                decrypted_dict[uid] = None
                continue
        return decrypted_dict


class QuicknetBittensorDrandTimelock(AbstractBittensorDrandTimelock):
    ROUND_DURATION = 3
    PK_HEX = "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
    CHAIN = '52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971'
    NET_START = 1692803367
