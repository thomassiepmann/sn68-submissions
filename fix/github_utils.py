"""
Fixed utils/github.py for NOVA SN68 miner.
Key fix: load_dotenv with absolute path so it works from any working directory.

Deploy:
  cp /root/nova/utils/github.py /root/nova/utils/github.py.bak
  cp /path/to/this/fix/github_utils.py /root/nova/utils/github.py
"""

import os
import requests
import bittensor as bt
from dotenv import load_dotenv

# Use absolute path — required when miner is started via pm2 from a different cwd
load_dotenv("/root/nova/.env", override=True)


def upload_file_to_github(filename: str, encoded_content: str) -> bool:
    github_repo_name = os.environ.get('GITHUB_REPO_NAME')
    github_repo_branch = os.environ.get('GITHUB_REPO_BRANCH')
    github_token = os.environ.get('GITHUB_TOKEN')
    github_repo_owner = os.environ.get('GITHUB_REPO_OWNER')
    github_repo_path = os.environ.get('GITHUB_REPO_PATH', '')

    if not github_repo_name or not github_repo_branch or not github_token or not github_repo_owner:
        raise ValueError(
            "Missing GitHub env vars. Check /root/nova/.env for: "
            "GITHUB_REPO_NAME, GITHUB_REPO_BRANCH, GITHUB_TOKEN, GITHUB_REPO_OWNER"
        )

    # Validate token type — must be Classic PAT (ghp_...)
    if not github_token.startswith('ghp_'):
        bt.logging.warning(
            f"GITHUB_TOKEN starts with '{github_token[:10]}...' — "
            "expected Classic PAT starting with 'ghp_'. Fine-grained PATs cause 403 errors."
        )

    if github_repo_path:
        target_file_path = f"{github_repo_path}/{filename}.txt"
    else:
        target_file_path = f"{filename}.txt"

    url = (
        f"https://api.github.com/repos/{github_repo_owner}/"
        f"{github_repo_name}/contents/{target_file_path}"
    )
    headers = {
        "Authorization": f"Bearer {github_token}",
        "Accept": "application/vnd.github+json",
    }

    # Check for existing file (needed for updates)
    existing = requests.get(url, headers=headers, params={"ref": github_repo_branch})
    sha = existing.json().get("sha") if existing.status_code == 200 else None

    payload = {
        "message": f"Encrypted response for {filename}",
        "content": encoded_content,
        "branch": github_repo_branch,
    }
    if sha:
        payload["sha"] = sha

    response = requests.put(url, headers=headers, json=payload)
    if response.status_code in [200, 201]:
        bt.logging.info(f"Successfully uploaded {filename}.txt to GitHub")
        return True
    else:
        bt.logging.error(
            f"GitHub upload failed for {filename}: "
            f"HTTP {response.status_code} — {response.text[:200]}"
        )
        if response.status_code == 403:
            bt.logging.error(
                "403 Forbidden: Token lacks permissions. "
                "Use a Classic PAT (ghp_...) with 'repo' scope from github.com/settings/tokens"
            )
        return False
