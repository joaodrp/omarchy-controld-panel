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

# Folding by host costs rows -- a hundred blocked lookups can be a handful of
# hosts, one of them most of the tally -- so it takes a page this large to fill
# a ceiling this small with names worth reading. It is still one request, and
# the caller keeps every row, so expanding the list costs nothing.
PAGE_SIZE = 500
MAX_ROWS = 20
WINDOW_HOURS = 6


def collapse(rows, limit, by_host=True):
    """Fold the page, newest kept, and tally what folded into each row.

    By host, every row for a question and verdict folds together wherever it
    sits. By lookup, only neighbours fold, which still spares one lookup's
    A/AAAA pair a row each but keeps the sequence intact. Folding happens
    before truncating, so a tally counts the whole window, not just the top.
    """
    out = []
    seen = {}
    for row in rows:
        question = str(row.get("question") or "")
        if question == "":
            continue
        key = (question, int(-1 if row.get("action") is None else row["action"]))
        kind = str(row.get("rrType") or "")
        if by_host:
            entry = seen.get(key)
        else:
            entry = out[-1] if out and (out[-1]["question"], out[-1]["action"]) == key else None
        if entry is not None:
            entry["repeats"] += 1
            if kind and kind not in entry["types"]:
                entry["types"].append(kind)
            continue
        # Rows arrive newest first, so the one that lands here is the latest.
        entry = {
            "time": str(row.get("timestamp") or ""),
            "question": question,
            "action": key[1],
            "trigger": str(row.get("trigger") or ""),
            "triggerValue": str(row.get("triggerValue") or ""),
            "protocol": str(row.get("protocol") or ""),
            "types": [kind] if kind else [],
            "repeats": 1,
        }
        seen[key] = entry
        out.append(entry)
    return out[:limit]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--endpoint", required=True, help="device id to report on")
    parser.add_argument("--region", required=True, help="account region, as `cdctl auth status` reports it")
    parser.add_argument("--group", choices=("host", "lookup"), default="host",
                        help="fold rows by host anywhere in the page, or only where they neighbour")
    parser.add_argument("--hours", type=int, default=WINDOW_HOURS,
                        help="how far back to look (default %d)" % WINDOW_HOURS)
    parser.add_argument("--action", type=int, action="append", dest="actions",
                        help="keep only this verdict: 0 blocked, 1 bypassed, 2 redirected, "
                             "3 spoofed. Repeatable. Omit for every verdict")
    args = parser.parse_args()

    try:
        token = api.read_token()
        params = dict(api.window(args.hours, args.endpoint), pageSize=PAGE_SIZE)
        # Narrowing server side is what keeps the list full: a page filtered to
        # blocked is a page of blocked, not the handful that survive a client
        # side filter. `action[]` takes one verdict or several, so a chip
        # covering two of them is still one request.
        if args.actions:
            params["action[]"] = args.actions
        body = api.get(api.host_for(args.region), "/v2/activity-log", params, token)
    except RuntimeError as exc:
        json.dump({"ok": False, "error": str(exc)}, sys.stdout)
        return 1

    queries = body.get("queries") or []
    json.dump({"ok": True, "queries": collapse(queries, MAX_ROWS, args.group == "host")}, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
