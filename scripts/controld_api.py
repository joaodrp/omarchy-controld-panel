"""Shared access to Control D's analytics origin for the panel's helpers.

Analytics lives on `<region>.analytics.controld.com`, which `cdctl api` cannot
reach -- hence this module. The token comes from the environment or cdctl's own
config and is sent only in a request header: it must never reach a process
argument, since `/proc/*/cmdline` is world readable.
"""

import json
import os
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

TIMEOUT = 15


def read_token():
    """The environment wins, matching how cdctl resolves it."""
    env = os.environ.get("CONTROLD_API_TOKEN")
    if env:
        return env
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    path = os.environ.get("CDCTL_CONFIG") or os.path.join(base, "cdctl", "config.toml")
    try:
        with open(path, "rb") as handle:
            config = tomllib.load(handle)
    except FileNotFoundError:
        raise RuntimeError("no API token: set CONTROLD_API_TOKEN or run `cdctl auth login`")
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise RuntimeError("could not read %s: %s" % (path, exc))
    context = config.get("current_context", "personal")
    token = (config.get("contexts", {}).get(context) or {}).get("token")
    if not token:
        raise RuntimeError("no API token in %s for context %s" % (path, context))
    return token


def host_for(region):
    """Analytics is per region, and only the account knows which.

    `cdctl auth status` reports it; guessing would query a host that either does
    not exist or holds someone else's region.
    """
    name = str(region or "").strip().lower()
    if name == "":
        raise RuntimeError("no region: pass --region as `cdctl auth status` reports it")
    return "%s.analytics.controld.com" % name


def window(hours, endpoint, now=None):
    """The query window every analytics call takes, ending now."""
    end = now or datetime.now(timezone.utc).replace(microsecond=0)
    span = max(1, min(hours, 24 * 30))
    return {
        "startTime": (end - timedelta(hours=span)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endTime": end.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "endpointId[]": endpoint,
    }


# The panel holds whatever these return inside a long-lived shell process, so
# a hostile or broken response must not be read without a bound. Real answers
# are a few hundred kilobytes at the largest page size.
MAX_BODY = 8 << 20
MAX_ERROR_BODY = 64 << 10


def _load_json(stream, limit, what):
    raw = stream.read(limit + 1)
    if len(raw) > limit:
        raise RuntimeError("%s is larger than %d bytes" % (what, limit))
    return json.loads(raw)


def get(host, path, params, token):
    request = urllib.request.Request(
        "https://%s%s?%s" % (host, path, urllib.parse.urlencode(params, doseq=True)),
        headers={"Authorization": "Bearer %s" % token, "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            payload = _load_json(response, MAX_BODY, "analytics response")
    except urllib.error.HTTPError as exc:
        detail = ""
        try:
            detail = (_load_json(exc, MAX_ERROR_BODY, "error body").get("error") or {}).get("message") or ""
        except (ValueError, AttributeError):
            pass
        raise RuntimeError("HTTP %s from analytics%s" % (exc.code, ": " + detail if detail else ""))
    except urllib.error.URLError as exc:
        raise RuntimeError("analytics unreachable: %s" % exc.reason)
    except (ValueError, TimeoutError) as exc:
        raise RuntimeError("bad analytics response: %s" % exc)
    if not payload.get("success"):
        raise RuntimeError((payload.get("error") or {}).get("message") or "analytics request failed")
    body = payload.get("body")
    # A success we cannot read is not an empty result: falling back to {} would
    # report zero queries, which is what a genuinely quiet endpoint looks like.
    if not isinstance(body, dict):
        raise RuntimeError("analytics returned no readable body for %s" % path)
    return body
