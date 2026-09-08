# Uploads over Tailscale

Tailscale gives your Mac a stable address that only devices you approve can
reach. No domain, no DNS, no port forwarding, and nothing exposed to the
public internet.

Reads are unaffected — the board comes from GitHub Pages either way. This is
only about getting players' stats *to* you.

## On your Mac (once)

```bash
brew install --cask tailscale
```

Open the app, sign in, and let it connect. Then find your address:

```bash
tailscale ip -4
```

You get something like `100.87.42.19`. That is stable — it survives reboots,
router changes and moving house.

Start the server as normal. It already binds `0.0.0.0`, so it answers on the
Tailscale address with no extra configuration:

```bash
LEVELPACE_TOKEN="$(sed -n '3p' dist/LevelPace-Leaderboard/server.txt)" \
  python3 server/levelpace_server.py --port 8080
```

Check it from the Mac itself first:

```bash
curl -s http://100.87.42.19:8080/api/stats
```

## In server.txt

Line 1 becomes your Tailscale address. Line 2 is the token. Line 3 stays as
the Pages URL, so the board still loads for people even when your Mac is off.

```
http://100.87.42.19:8080
<your token>
https://monscorps.github.io/levelpace/api/baseline.json
```

Rebuild so the distributed folder picks it up:

```bash
./build.sh
```

## What each player does (once)

1. Install Tailscale — <https://tailscale.com/download> — and make a free
   account.
2. Send you the email address they signed up with.
3. You share your Mac with them (below).
4. They accept the invite. Done. Tailscale then runs quietly in the
   background and they never think about it again.

## Sharing your Mac with them

In the Tailscale admin console → **Machines** → your Mac → the `...` menu →
**Share**. Enter their email; they get a link to accept.

Sharing a single machine is the right mechanism here: they get access to that
one device and nothing else on your network, and you can revoke any of them
individually without touching the others.

## ⚠ Check the plan limits before inviting ten people

Tailscale's free Personal plan has a **user limit** that is small — low
single digits at time of writing — and the exact numbers change. Shared
devices are counted differently from tailnet members, which is why sharing is
the approach above rather than adding everyone to your tailnet.

**Check <https://tailscale.com/pricing> against the number of people you
actually have before you promise anyone anything.** If ten people does not
fit the free tier, the honest comparison is:

| | Cost | Per-player effort |
|---|---|---|
| Tailscale | free up to the limit, then per-user | install + account + accept invite |
| Cloudflare Tunnel | ~£8/year for a domain | **nothing** |

At ten people a cheap domain and a tunnel is probably both cheaper and less
hassle than ten Tailscale accounts — the players do nothing at all, and you
already know how Cloudflare works. Tailscale wins on privacy (nothing public)
and on not needing a domain.

## If an upload fails

Nothing is lost. The uploader reports the failure and carries on to fetch the
board, so players still get current rankings; their own stats go up on the
next run. Your Mac being off is not a problem, only a delay.
