"""Shared config loading for the Uptime Kuma helper scripts.

Reads credentials from environment variables, falling back to a `.env.local`
file sitting next to these scripts (git-ignored). Real env vars win over the
file, so you can override per-invocation.
"""
import os
from pathlib import Path


def load_env():
    """Load KEY=VALUE lines from ./.env.local into os.environ (without override)."""
    env_file = Path(__file__).with_name(".env.local")
    if not env_file.exists():
        return
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        val = val.strip().strip('"').strip("'")
        os.environ.setdefault(key.strip(), val)


def config():
    load_env()
    cfg = {
        "url": os.environ.get("UPTIME_KUMA_URL", "https://uptime.mysite.com"),
        "username": os.environ.get("UPTIME_KUMA_USERNAME"),
        "password": os.environ.get("UPTIME_KUMA_PASSWORD"),
    }
    if not (cfg["username"] and cfg["password"]):
        raise SystemExit(
            "Missing credentials. Set UPTIME_KUMA_USERNAME and "
            "UPTIME_KUMA_PASSWORD (env vars or uptime-kuma/.env.local)."
        )
    return cfg
