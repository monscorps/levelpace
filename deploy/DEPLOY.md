# Putting the server on a public URL

This is what removes Tailscale, accounts and invites from your players' lives.
Once the server has a public address they need exactly two things: the addon,
and the companion. Nothing else.

## Why not just any free host

The server keeps its data in SQLite, which needs a **persistent disk**. Most
free tiers give you an ephemeral filesystem — Render's free plan and anything
Heroku-shaped will wipe `/app` on every deploy and restart, taking the whole
leaderboard with it. You would not notice until the day you redeploy and
everyone's history is gone.

So the requirement is: public HTTPS, and a real volume.

## Fly.io — recommended

Free-ish for something this small, gives you `levelpace.fly.dev` with no
domain to buy, and supports volumes.

```bash
brew install flyctl
fly auth signup          # or: fly auth login
```

Then, from the repo root:

```bash
fly launch --no-deploy --name levelpace
fly volumes create levelpace_data --size 1 --region lhr
fly secrets set LEVELPACE_TOKEN="$(cat .token)"
fly deploy
```

`--name` has to be globally unique. If `levelpace` is taken, pick another and
change `app =` in `fly.toml` to match.

Check it:

```bash
curl -s https://levelpace.fly.dev/api/stats
curl -s -o /dev/null -w "unauthenticated POST -> %{http_code}\n" \
     -X POST -d '[]' https://levelpace.fly.dev/api/submit
```

You want JSON from the first and **401** from the second. If the second
returns 200 the token is not being enforced — stop and fix that before
telling anyone the address.

### Then point the client at it

Edit `packaging/server.txt`, line 1:

```
https://levelpace.fly.dev
```

Rebuild and release so the download carries the right address:

```bash
./build.sh && ./release.sh 0.4.1
```

## Anything else with a volume

The Dockerfile is ordinary, so this runs unchanged on Railway, a $5 VPS,
Oracle's always-free VM, or your own box. The only two requirements:

- mount a persistent volume at **`/data`**
- set **`LEVELPACE_TOKEN`** in the environment

## About the sleeping machine

`auto_stop_machines` lets Fly stop the VM when idle and start it again on the
next request. A cold start adds a second or two — irrelevant for an upload
that happens after someone has logged out, and it keeps the cost near zero.

If you would rather it never sleeps, set `min_machines_running = 1`. That
costs more and buys you very little here.

## What this does and does not change

**Removed:** Tailscale, player accounts, invites, node sharing, your Mac
needing to be awake, and your home IP being involved at all.

**Unchanged:** everything about how the data is produced. It is still
client-supplied and still forgeable — see the "About cheating" section of the
main README. A public URL makes the submission token matter more, not less:
scanners will find the endpoint.

**Still fine to keep:** GitHub Pages. It costs nothing and means the board
survives the server being down. The companion reads rankings from Pages and
writes stats to Fly, and the two are independent by design.

## Publishing the board after a move

`publish-to-pages.command` reads a local database. With the server on Fly,
that database now lives on the Fly volume, so pull a copy first:

```bash
fly ssh sftp get /data/levelpace.db server/levelpace.db
./publish-to-pages.command
```

Or skip Pages entirely and let the Fly server serve the dashboard directly at
`https://levelpace.fly.dev/` — it already does. Pages is only worth keeping
for the resilience.
