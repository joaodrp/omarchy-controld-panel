#!/usr/bin/env python3
"""Query Control D analytics for one endpoint and print a normalized document.

Analytics lives on a different origin than the REST API (`<region>.analytics.
controld.com`), which `cdctl api` cannot reach, so the panel comes here
instead. The fan-out lives in Python rather than QML because it is nine
requests folded into one document, and because the token must never reach a
process argument: it is read from the environment or cdctl's own config and
sent only in a request header.

One run answers one (window, action) pair: the totals and the series never
change with the action, so the panel can cache per pair and still redraw its
summary from any of them.

    {"ok": true, "hours": 24, "action": 0,
     "totals": {"all": 21405, "blocked": 6290, "bypassed": 14709, "redirected": 0},
     "series": [{"time": "...", "total": 273, "blocked": 23}, ...],
     "domains":   [{"value": "d.dropbox.com", "count": 2112}, ...],
     "filters":   [{"value": "x-hagezi-proplus", "count": 6288}, ...],
     "networks":  [{"value": "Google", "count": 72}, ...],
     "countries": [{"value": "US", "count": 211}, ...]}

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
# The verdict analytics records per query. Values match the dashboard's tabs.
ACTIONS = {"blocked": 0, "bypassed": 1, "redirected": 2}
# Buckets in the series. The API decides the interval from the window and this
# cap, and returns one more bucket than asked for.
SERIES_BUCKETS = 24


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
            detail = (json.load(exc).get("error") or {}).get("message") or ""
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


def counts(body, limit):
    out = []
    for entry in (body.get("counts") or []):
        value = str(entry.get("value") or "")
        if value:
            out.append({"value": value, "count": int(entry.get("count") or 0)})
    return out[:limit]


def series(body, now):
    """Total and blocked per bucket, which is all the sparkline draws.

    The last bucket is still filling when the window ends at now, so it lands
    a fraction of the others and would draw as a cliff. Drop it.
    """
    out = []
    for bucket in (body.get("queries") or []):
        per_action = bucket.get("count") or {}
        total = sum(int(v or 0) for v in per_action.values())
        out.append({
            "time": str(bucket.get("time") or ""),
            "total": total,
            "blocked": int(per_action.get(str(ACTIONS["blocked"])) or 0),
        })
    if len(out) > 2:
        try:
            first = datetime.fromisoformat(out[0]["time"].replace("Z", "+00:00"))
            second = datetime.fromisoformat(out[1]["time"].replace("Z", "+00:00"))
            last = datetime.fromisoformat(out[-1]["time"].replace("Z", "+00:00"))
            if now - last < (second - first):
                out.pop()
        except ValueError:
            pass
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="device id to report on")
    parser.add_argument("--region", default="europe", help="account region, as `cdctl auth status` reports it")
    parser.add_argument("--hours", type=int, default=24, help="window size, ending now")
    parser.add_argument("--action", type=int, default=0, help="verdict the lists describe: 0 blocked, 1 bypassed, 2 redirected")
    parser.add_argument("--top", type=int, default=5, help="rows per list")
    args = parser.parse_args()

    try:
        token = read_token()
    except RuntimeError as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        return 1

    host = "%s.analytics.controld.com" % (args.region or "europe")
    now = datetime.now(timezone.utc).replace(microsecond=0)
    hours = max(1, min(args.hours, 24 * 30))
    action = args.action if args.action in ACTIONS.values() else 0
    top = max(1, min(args.top, 20))
    window = {
        "startTime": (now - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endTime": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endpointId[]": args.endpoint,
    }
    listed = dict(window, **{"action[]": action, "limit": top, "sortOrder": "desc"})

    calls = {
        "all": ("/v2/statistic/count", dict(window)),
        "blocked": ("/v2/statistic/count", dict(window, **{"action[]": ACTIONS["blocked"]})),
        "bypassed": ("/v2/statistic/count", dict(window, **{"action[]": ACTIONS["bypassed"]})),
        "redirected": ("/v2/statistic/count", dict(window, **{"action[]": ACTIONS["redirected"]})),
        "series": ("/v2/statistic/timeseries/action", dict(window, limit=SERIES_BUCKETS)),
        "domains": ("/v2/statistic/count/question", dict(listed)),
        # triggerValue takes a scalar `action`, unlike the `action[]` above.
        "filters": ("/v2/statistic/count/triggerValue",
                    dict(window, trigger="filter", action=action, limit=top, sortOrder="desc")),
        "networks": ("/v2/statistic/count/dstIsp", dict(window, sortOrder="desc")),
        "countries": ("/v2/statistic/count/dstCountry", dict(window, sortOrder="desc")),
    }
    # Serially these add up to a visible wait every time a tab is switched.
    with ThreadPoolExecutor(max_workers=len(calls)) as pool:
        futures = {name: pool.submit(get, host, path, params, token) for name, (path, params) in calls.items()}
        try:
            bodies = {name: future.result() for name, future in futures.items()}
        except RuntimeError as exc:
            json.dump({"ok": False, "error": str(exc)}, sys.stdout)
            return 1

    json.dump({
        "ok": True,
        "hours": hours,
        "action": action,
        "start": window["startTime"],
        "end": window["endTime"],
        "totals": {name: int(bodies[name].get("count") or 0)
                   for name in ("all", "blocked", "bypassed", "redirected")},
        "series": series(bodies["series"], now),
        "domains": counts(bodies["domains"], top),
        "filters": counts(bodies["filters"], top),
        "networks": counts(bodies["networks"], top),
        "countries": counts(bodies["countries"], top),
    }, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
