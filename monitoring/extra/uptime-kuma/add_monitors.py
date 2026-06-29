#!/usr/bin/env python3
"""Create an Uptime Kuma HTTP monitor for every Ingress host in the cluster.

Idempotent: re-run any time you add apps — monitors that already exist (matched
by name) are skipped, not duplicated.

Credentials come from env vars or uptime-kuma/.env.local (see kuma_common.py).

Usage:
    python add_monitors.py [--dry-run]

Env vars:
    UPTIME_KUMA_URL       default https://uptime.mysite.com
    UPTIME_KUMA_USERNAME  required (or .env.local)
    UPTIME_KUMA_PASSWORD  required (or .env.local)
    KUMA_INTERVAL         check interval seconds, default 60
"""
import json
import os
import subprocess
import sys

from uptime_kuma_api import UptimeKumaApi, MonitorType

from kuma_common import config

INTERVAL = int(os.environ.get("KUMA_INTERVAL", "60"))
DRY_RUN = "--dry-run" in sys.argv

# Hosts we don't want a monitor for (the monitor's own UI, infra you don't care
# about). Edit to taste.
SKIP_HOSTS = {"uptime.mysite.com"}


def primary_host(hosts):
    """Pick the canonical host: prefer a non-www host, else the first."""
    non_www = [h for h in hosts if not h.startswith("www.")]
    return (non_www or hosts)[0]


def discover():
    """Return {app_name: url} from every Ingress in the cluster via kubectl."""
    out = subprocess.check_output(
        ["kubectl", "get", "ingress", "-A", "-o", "json"], text=True
    )
    targets = {}
    for it in json.loads(out)["items"]:
        name = it["metadata"]["name"]
        hosts = [
            h
            for r in it["spec"].get("rules", [])
            for h in [r.get("host")]
            if h and h not in SKIP_HOSTS
        ]
        if not hosts:
            continue
        targets[name] = f"https://{primary_host(hosts)}"
    return targets


def main():
    targets = discover()
    print(f"Discovered {len(targets)} app(s) to monitor:")
    for name, url in sorted(targets.items()):
        print(f"  {name:24} {url}")

    if DRY_RUN:
        print("\n--dry-run: not contacting Uptime Kuma.")
        return

    cfg = config()
    with UptimeKumaApi(cfg["url"]) as api:
        api.login(cfg["username"], cfg["password"])
        existing = {m["name"] for m in api.get_monitors()}

        created = skipped = 0
        for name, url in sorted(targets.items()):
            if name in existing:
                print(f"  skip   {name} (already exists)")
                skipped += 1
                continue
            api.add_monitor(
                type=MonitorType.HTTP,
                name=name,
                url=url,
                interval=INTERVAL,
                maxretries=2,        # tolerate one blip before going DOWN
                retryInterval=60,
                accepted_statuscodes=["200-299", "300-399"],
            )
            print(f"  create {name} -> {url}")
            created += 1

    print(f"\nDone. {created} created, {skipped} already existed.")


if __name__ == "__main__":
    main()
