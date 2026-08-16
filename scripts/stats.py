#!/usr/bin/env python3
"""Query Control D analytics for one endpoint and print a normalized document.

Analytics lives on a different origin than the REST API (`<region>.analytics.
controld.com`), which `cdctl api` cannot reach, so the panel comes here
instead. The multi-request shape lives in Python rather than QML because it is
several calls fanned into one document, and because the token must never reach
a process argument: it is read from the environment or cdctl's own config and
sent only in a request header.

Output on success (stdout, exit 0):

    {"ok": true, "hours": 24, "total": 21405, "blocked": 6290,
     "top_blocked": [{"value": "d.dropbox.com", "count": 2112}, ...]}

On failure, the same envelope with "ok": false and an "error" string, exit 1.
"""

import argparse
import json
import os
import sys
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone

TIMEOUT = 15
CONFIG_ENV = "CDCTL_CONFIG"
# Analytics reports an action per query: the rule or filter verdict that
# decided it. Only "blocked" is surfaced here; the rest are the remainder.
ACTION_BLOCK = 0


def config_path():
    override = os.environ.get(CONFIG_ENV)
    if override:
        return override
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "cdctl", "config.toml")


def read_token():
    """The environment wins, exactly as cdctl resolves it."""
    env = os.environ.get("CONTROLD_API_TOKEN")
    if env:
        return env
    path = config_path()
    try:
        with open(path, "rb") as handle:
            config = tomllib.load(handle)
    except FileNotFoundError:
        raise RuntimeError("no API token: set CONTROLD_API_TOKEN or run `cdctl auth login`")
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RuntimeError("could not read %s: %s" % (path, exc))
    context = config.get("current_context", "personal")
    token = (config.get("contexts", {}).get(context, {}) or {}).get("token")
    if not token:
        raise RuntimeError("no API token in %s for context %s" % (path, context))
    return token


def get(host, path, params, token):
    query = urllib.parse.urlencode(params, doseq=True)
    request = urllib.request.Request(
        "https://%s%s?%s" % (host, path, query),
        headers={"Authorization": "Bearer %s" % token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            body = json.load(exc)
            detail = (body.get("error") or {}).get("message") or ""
        except Exception:
            pass
        raise RuntimeError("HTTP %s from analytics%s" % (exc.code, ": " + detail if detail else ""))
    except urllib.error.URLError as exc:
        raise RuntimeError("analytics unreachable: %s" % exc.reason)
    except (ValueError, TimeoutError) as exc:
        raise RuntimeError("bad analytics response: %s" % exc)
    if not payload.get("success"):
        raise RuntimeError((payload.get("error") or {}).get("message") or "analytics request failed")
    return payload.get("body") or {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="device id to report on")
    parser.add_argument("--region", default="europe", help="account region, as `cdctl auth status` reports it")
    parser.add_argument("--hours", type=int, default=24, help="window size, ending now")
    parser.add_argument("--top", type=int, default=5, help="how many blocked domains to list")
    args = parser.parse_args()

    try:
        token = read_token()
    except RuntimeError as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        return 1

    host = "%s.analytics.controld.com" % (args.region or "europe")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    hours = max(1, min(args.hours, 24 * 30))
    window = {
        "startTime": (now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endTime": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endpointId[]": args.endpoint,
    }

    calls = {
        "total": ("/v2/statistic/count", dict(window)),
        "blocked": ("/v2/statistic/count", dict(window, **{"action[]": ACTION_BLOCK})),
        "top": ("/v2/statistic/count/question", dict(
            window, **{"action[]": ACTION_BLOCK, "limit": max(1, args.top), "sortOrder": "desc"})),
    }
    # Three independent requests; serially they add up to a visible wait when
    # the panel opens.
    with ThreadPoolExecutor(max_workers=len(calls)) as pool:
        futures = {name: pool.submit(get, host, path, params, token) for name, (path, params) in calls.items()}
        try:
            bodies = {name: future.result() for name, future in futures.items()}
        except RuntimeError as exc:
            json.dump({"ok": False, "error": str(exc)}, sys.stdout)
            return 1

    counts = bodies["top"].get("counts") or []
    json.dump({
        "ok": True,
        "hours": hours,
        "start": window["startTime"],
        "end": window["endTime"],
        "total": int(bodies["total"].get("count") or 0),
        "blocked": int(bodies["blocked"].get("count") or 0),
        "top_blocked": [
            {"value": str(entry.get("value") or ""), "count": int(entry.get("count") or 0)}
            for entry in counts if entry.get("value")
        ],
    }, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
