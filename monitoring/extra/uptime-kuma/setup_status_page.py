#!/usr/bin/env python3
"""Create/refresh the public Uptime Kuma status page.

Idempotent: creates the page if missing, then (re)publishes it with every
current monitor listed under one group. Re-run after add_monitors.py to pick
up newly added apps.

Served at:
    https://uptime.mysite.com/status/<slug>
    https://status.mysite.com         (via the domain mapping below)

Credentials come from env vars or uptime-kuma/.env.local (see kuma_common.py).

Usage:
    python setup_status_page.py
"""
import os

from uptime_kuma_api import UptimeKumaApi

from kuma_common import config

SLUG = os.environ.get("STATUS_SLUG", "services")
TITLE = os.environ.get("STATUS_TITLE", "Service Status")
DOMAIN = os.environ.get("STATUS_DOMAIN", "status.mysite.com")


def main():
    cfg = config()
    with UptimeKumaApi(cfg["url"]) as api:
        api.login(cfg["username"], cfg["password"])

        existing = {p["slug"] for p in api.get_status_pages()}
        if SLUG not in existing:
            api.add_status_page(SLUG, TITLE)
            print(f"created status page '{SLUG}'")
        else:
            print(f"status page '{SLUG}' already exists, updating")

        monitors = sorted(api.get_monitors(), key=lambda m: m["name"])
        group = {
            "name": "Services",
            "monitorList": [{"id": m["id"]} for m in monitors],
        }

        api.save_status_page(
            SLUG,
            title=TITLE,
            theme="auto",
            published=True,
            showTags=False,
            domainNameList=[DOMAIN] if DOMAIN else [],
            publicGroupList=[group],
        )
        print(f"published '{TITLE}' with {len(monitors)} monitor(s)")
        print(f"  -> {cfg['url']}/status/{SLUG}")
        if DOMAIN:
            print(f"  -> https://{DOMAIN}")


if __name__ == "__main__":
    main()
