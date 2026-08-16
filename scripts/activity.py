#!/usr/bin/env python3
"""Print this endpoint's most recent DNS queries, newest first.

    {"ok": true, "queries": [
      {"time": "2026-08-16T15:21:53.961Z", "question": "p.controld.com",
       "action": 0, "trigger": "filter", "triggerValue": "x-hagezi-proplus",
       "protocol": "dot", "types": ["AAAA", "A"], "repeats": 2}, ...]}

On failure, the same envelope with "ok": false and an "error" string, exit 1.
"""

import argparse
import json
import sys

import controld_api as api

# A resolver asks for A and AAAA (often HTTPS too) at the same instant, so the
# raw log spends three rows on one lookup. In a list this short that is most of
# the space, so consecutive rows for the same question and verdict collapse
# into one that keeps every record type it stood for.
COLLAPSE_SECONDS = 5
# The most this hands back, and the page it reads to fill that. The caller
# draws a slice and expands into the rest, so keeping them all is what makes
# expanding cost nothing. The ceiling is small on purpose: past twenty or so a
# bar panel is the wrong place to be reading a log. The page stays larger than
# the ceiling because collapsing folds several raw rows into one, and a burst
# of repeats would otherwise leave the list short of what it could show.
PAGE_SIZE = 100
MAX_ROWS = 20


def parse_time(value):
    text = str(value or "").replace("Z", "+00:00")
    try:
        from datetime import datetime
        return datetime.fromisoformat(text)
    except ValueError:
        return None


def collapse(rows, limit):
    out = []
    for row in rows:
        question = str(row.get("question") or "")
        if question == "":
            continue
        entry = {
            "time": str(row.get("timestamp") or ""),
            "question": question,
            "action": int(row.get("action") if row.get("action") is not None else -1),
            "trigger": str(row.get("trigger") or ""),
            "triggerValue": str(row.get("triggerValue") or ""),
            "protocol": str(row.get("protocol") or ""),
            "types": [str(row.get("rrType") or "")] if row.get("rrType") else [],
            "repeats": 1,
        }
        previous = out[-1] if out else None
        if previous and previous["question"] == entry["question"] and previous["action"] == entry["action"]:
            first, second = parse_time(previous["time"]), parse_time(entry["time"])
            close = first is not None and second is not None and abs((first - second).total_seconds()) <= COLLAPSE_SECONDS
            if close:
                previous["repeats"] += 1
                for kind in entry["types"]:
                    if kind not in previous["types"]:
                        previous["types"].append(kind)
                continue
        out.append(entry)
        if len(out) >= limit:
            break
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="device id to report on")
    parser.add_argument("--region", required=True, help="account region, as `cdctl auth status` reports it")
    parser.add_argument("--action", type=int, default=None,
                        help="keep only this verdict: 0 blocked, 1 bypassed, 2 redirected. "
                             "Omit for every verdict")
    parser.add_argument("--rows", type=int, default=MAX_ROWS,
                        help=f"how many queries to keep after collapsing, at most {MAX_ROWS}")
    parser.add_argument("--hours", type=int, default=6, help="how far back to look for them")
    args = parser.parse_args()

    try:
        token = api.read_token()
        rows = max(1, min(args.rows, MAX_ROWS))
        # Ask for more than we keep: collapsing several raw rows into one means
        # a page of 100 can be worth far fewer entries.
        params = dict(api.window(args.hours, args.endpoint), pageSize=PAGE_SIZE)
        # Narrowing server side is what keeps the list full: a page filtered to
        # blocked is a page of blocked, not the handful that survive a client
        # side filter.
        if args.action is not None:
            params["action"] = args.action
        body = api.get(api.host_for(args.region), "/v2/activity-log", params, token)
    except RuntimeError as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        return 1

    queries = body.get("queries") or []
    json.dump({"ok": True, "queries": collapse(queries, rows)}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
