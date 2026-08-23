"""Shared access to Control D's analytics origin for the panel's helpers.

Analytics lives on a different origin than the REST API (`<region>.analytics.
controld.com`), which `cdctl api` cannot reach, so the helpers come here. The
token is read from the environment or cdctl's own config and sent only in a
request header: it must never reach a process argument, which is world
readable on Linux.
"""

import json
import os
import tomllib
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

TIMEOUT = 15
CONFIG_ENV = "CDCTL_CONFIG"


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


def host_for(region):
    """Analytics is per region, and only the account knows which.

    `cdctl auth status` reports it; guessing would send the query to a host
    that either does not exist or holds someone else's region.
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
        except (ValueError, AttributeError):
            pass
        raise RuntimeError("HTTP %s from analytics%s" % (exc.code, ": " + detail if detail else ""))
    except urllib.error.URLError as exc:
        raise RuntimeError("analytics unreachable: %s" % exc.reason)
    except (ValueError, TimeoutError) as exc:
        raise RuntimeError("bad analytics response: %s" % exc)
    if not payload.get("success"):
        raise RuntimeError((payload.get("error") or {}).get("message") or "analytics request failed")
    # A success we cannot read is not an empty result. Falling back to {} here
    # reports zero queries and empty lists, which is exactly what a genuinely
    # quiet endpoint looks like, so a shape change would read as good news.
    body = payload.get("body")
    if not isinstance(body, dict):
        raise RuntimeError("analytics returned no readable body for %s" % path)
    return body
