#!/usr/bin/env python3
"""Query Control D analytics for one endpoint and print a normalized document.

The fan-out lives here rather than in QML because it is nine requests folded
into one document, against an origin `cdctl api` cannot reach (see
controld_api). One run answers one (window, action) pair: the totals and the
series do not change with the action, so the panel can cache per pair and still
redraw its summary from any of them.

    {"ok": true, "hours": 24, "action": 0,
     "totals": {"all": 20000, "blocked": 6000, "bypassed": 14000, "redirected": 0},
     "series": [{"time": "...", "total": 300, "blocked": 25}, ...],
     "domains":   [{"value": "telemetry.example", "count": 2000}, ...],
     "filters":   [{"value": "x-example-list", "count": 6000}, ...],
     "networks":  [{"value": "Example Cloud", "count": 70}, ...],
     "countries": [{"value": "US", "count": 200}, ...]}

On failure, the same envelope with "ok": false and an "error" string, exit 1.
"""

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import controld_api as api

# The verdict analytics records per query. Values match the dashboard's tabs.
ACTIONS = {"blocked": 0, "bypassed": 1, "redirected": 2}
# The API picks the series interval from the window and this cap.
SERIES_BUCKETS = 24


def counts(body, limit):
    # `limit` is asked of the API, not enforced by it, so stop at the cap here
    # rather than building the whole list and slicing it.
    out = []
    for entry in (body.get("counts") or []):
        if len(out) >= limit:
            break
        value = str(entry.get("value") or "")
        if value:
            out.append({"value": value, "count": int(entry.get("count") or 0)})
    return out


def series(body, now):
    """Total and blocked per bucket, which is all the sparkline draws.

    A last bucket still filling when the window ends lands a fraction of the
    others and would draw as a cliff, so it is dropped.
    """
    # SERIES_BUCKETS is what the API is asked for, not what it must return, and
    # every bucket becomes a point in a layered Shape the shell renders.
    out = []
    for bucket in (body.get("queries") or [])[:SERIES_BUCKETS]:
        per_action = bucket.get("count") or {}
        out.append({
            "time": str(bucket.get("time") or ""),
            "total": sum(int(v or 0) for v in per_action.values()),
            "blocked": int(per_action.get(str(ACTIONS["blocked"])) or 0),
        })
    if len(out) > 2:
        try:
            first, second, last = (datetime.fromisoformat(row["time"].replace("Z", "+00:00"))
                                   for row in (out[0], out[1], out[-1]))
            if now - last < second - first:
                out.pop()
        except ValueError:
            pass
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="device id to report on")
    parser.add_argument("--region", required=True, help="account region, as `cdctl auth status` reports it")
    parser.add_argument("--hours", type=int, default=24, help="window size, ending now")
    parser.add_argument("--action", type=int, default=0, help="verdict the lists describe: 0 blocked, 1 bypassed, 2 redirected")
    parser.add_argument("--top", type=int, default=5, help="rows per list")
    args = parser.parse_args()

    try:
        token = api.read_token()
        host = api.host_for(args.region)
    except RuntimeError as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        return 1

    now = datetime.now(timezone.utc).replace(microsecond=0)
    hours = max(1, min(args.hours, 24 * 30))
    action = args.action if args.action in ACTIONS.values() else 0
    top = max(1, min(args.top, 20))
    window = api.window(hours, args.endpoint, now)
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
        futures = {name: pool.submit(api.get, host, path, params, token) for name, (path, params) in calls.items()}
        try:
            bodies = {name: future.result() for name, future in futures.items()}
        except RuntimeError as exc:
            json.dump({"ok": False, "error": str(exc)}, sys.stdout)
            return 1

    json.dump({
        "ok": True,
        "hours": hours,
        "action": action,
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
