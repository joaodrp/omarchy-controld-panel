# How it works

Detail behind the [README](../README.md): how the panel finds your endpoint, and how it reaches
the two halves of [Control D](https://controld.com).

## Endpoint detection

A Control D device publishes itself four ways -- a DoT hostname, a DoH URL, its own IPv6 address
and a legacy IPv4 one -- and all four carry the device id. The panel reads the DNS config on the
machine and looks for any of those forms in your device list.

Matching against the device list rather than a hostname pattern is what lets a plain IPv6 resolver
identify the endpoint with no proxy in between.

The configs it reads, and the resolver each one implies:

| Config | Resolver |
| --- | --- |
| `/etc/controld/ctrld.toml`, `/etc/ctrld.toml` | `ctrld` |
| `/etc/stubby/stubby.yml` | `stubby` |
| `/etc/dnscrypt-proxy/dnscrypt-proxy.toml` | `dnscrypt-proxy` |
| `/etc/unbound/unbound.conf`, `unbound.conf.d/*.conf` | `unbound` |
| `/etc/dnsmasq.conf`, `/etc/dnsmasq.d/*` | `dnsmasq` |
| `/etc/NetworkManager/NetworkManager.conf`, `conf.d/*.conf` | `NetworkManager` |
| `resolvectl status` | `systemd-resolved` |
| `/etc/resolv.conf` | `unknown` |

Treat your endpoint ID as a secret. It is the whole endpoint -- every resolver address is that ID
plus a fixed suffix -- so anyone who has it can resolve through your endpoint, spending your quota
and filling your activity log. This is why the screenshots in the README carry a placeholder.

The first config naming the endpoint wins, so a manager gets credit over whatever it generates
downstream. `ctrld` is confirmed with `systemctl is-active`, because the account keeps a `ctrld`
block on a device long after the daemon is gone.

An endpoint found only in `/etc/resolv.conf` means something outside this list set it: the resolver
row reads `unknown` and links to the issue tracker.


## The two origins

Control D answers on two hosts, and only one of them is the CLI's:

| Origin | Reached by | Carries |
| --- | --- | --- |
| `api.controld.com` | [`cdctl`](https://github.com/joaodrp/controld-cli) | auth, profiles, rules, folders, devices |
| `<region>.analytics.controld.com` | `scripts/*.py` | statistics, activity log |

`cdctl api` cannot reach the analytics origin. That is the whole reason the Python helpers exist;
everything else goes through `cdctl`.

The region comes from `cdctl auth status`. The helpers refuse to guess it, because a wrong region
is a host that either is missing or belongs to someone else.

### Your token

`scripts/controld_api.py` resolves the token exactly as `cdctl` does:

1. `CONTROLD_API_TOKEN`, if set.
2. Otherwise the token for the current context in `cdctl`'s own config, honouring
   `XDG_CONFIG_HOME`.

It is sent in an `Authorization` header and nowhere else. **Never in a process argument**:
`/proc/*/cmdline` is world readable, so an argument is visible to every user on the machine. It
never appears in output either.

Analytics has to be enabled for the endpoint. When it is off, the statistics section says so
rather than reporting zeros.

### The helpers

| Script | Returns |
| --- | --- |
| `scripts/controld_api.py` | Token resolution and HTTP; not run directly |
| `scripts/stats.py` | One (window, verdict) pair of statistics, nine requests folded into one document |
| `scripts/activity.py` | Recent lookups, one row per host with a repeat count, up to 20; the panel draws a slice and expands into the rest |

Both print a `{"ok": true, ...}` envelope, or `{"ok": false, "error": "..."}` with exit 1.

## Analytics verdicts

The codes the activity log and statistics use:

| Code | Means |
| --- | --- |
| `0` | Blocked |
| `1` | Bypassed |
| `2` | Redirected |
| `3` | Spoofed |
| `-1` | Matched nothing (timeseries only) |

Destinations exist only for traffic that was allowed, so a verdict filter governs domains and
filters but not destinations.
