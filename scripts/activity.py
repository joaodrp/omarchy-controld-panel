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

# One row per host, not per lookup. A resolver asks for A and AAAA at the same
# instant, and a chatty host is asked for again every minute, so a raw page
# spends most of its rows on a handful of names. What the reader is scanning
# for is which hosts were blocked, and repetition is a count, so rows for the
# same question and verdict fold into the newest one and carry a tally.
# The most this hands back, and the page it reads to fill that. The caller
# draws a slice and expands into the rest, so keeping them all is what makes
# expanding cost nothing. The ceiling is small on purpose: past twenty or so a
# bar panel is the wrong place to be reading a log.
#
# The page is the API's maximum because folding by host costs rows: this
# endpoint's last hundred blocked lookups are four hosts, one of them eighty
# times over. Five hundred is what it takes to fill the ceiling with names
# worth reading, and it is still one request.
PAGE_SIZE = 500
MAX_ROWS = 20
# How far back the log reaches. Recent is the whole point, and the panel polls
# every fifteen seconds, so a wide window only buys rows nobody scrolls to --
# except for the verdicts that hardly ever happen, where a short window reports
# their absence rather than their rarity. The caller says which it is asking
# for.
WINDOW_HOURS = 6


def collapse(rows, limit, by_host=True):
    """Fold the page, newest kept, and tally what folded into each row.

    By host, every row for a question and verdict folds together wherever it
    sits: which hosts were blocked is the question, and repetition is a count.
    By lookup, only neighbours fold, which still spares the A/AAAA pair of one
    lookup its own row but keeps the sequence intact.

    The whole page is folded before truncating, so a tally counts every lookup
    in the window rather than only those above the cut.
    """
    out = []
    seen = {}
    for row in rows:
        question = str(row.get("question") or "")
        if question == "":
            continue
        action = int(row.get("action") if row.get("action") is not None else -1)
        kind = str(row.get("rrType") or "")
        if by_host:
            entry = seen.get((question, action))
        else:
            entry = out[-1] if out else None
            if entry is not None and (entry["question"], entry["action"]) != (question, action):
                entry = None
        if entry is not None:
            entry["repeats"] += 1
            if kind and kind not in entry["types"]:
                entry["types"].append(kind)
            continue
        # Rows arrive newest first, so the one that lands here is the latest.
        entry = {
            "time": str(row.get("timestamp") or ""),
            "question": question,
            "action": action,
            "trigger": str(row.get("trigger") or ""),
            "triggerValue": str(row.get("triggerValue") or ""),
            "protocol": str(row.get("protocol") or ""),
            "types": [kind] if kind else [],
            "repeats": 1,
        }
        seen[(question, action)] = entry
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
        # Ask for more than we keep: collapsing several raw rows into one means
        # a page of 100 can be worth far fewer entries.
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
