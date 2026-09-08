# Putting the server on a Cloudflare Tunnel

You already have a domain on Cloudflare, so this is the clean option: a stable
HTTPS URL pointing at the server on your Mac, with **no port forwarding, no
static IP, and nothing exposed on your router**. `cloudflared` dials *out* to
Cloudflare and holds the connection open; nothing dials in.

Your players install nothing extra.

## Why not the quick tunnel

`cloudflared tunnel --url http://localhost:8080` works instantly and needs no
domain — but the `*.trycloudflare.com` URL it gives you **changes every time
it restarts**. That address is baked into every copy of `server.txt` you hand
out, so a changing URL means re-distributing the folder every reboot. Use a
named tunnel.

## One-time setup

```bash
brew install cloudflared
cloudflared tunnel login          # opens a browser, pick your domain
cloudflared tunnel create levelpace
```

`create` prints a tunnel **UUID** and writes credentials to
`~/.cloudflared/<UUID>.json`. Note the UUID.

Point a hostname at it:

```bash
cloudflared tunnel route dns levelpace levelpace.yourdomain.com
```

Then copy `config.example.yml` to `~/.cloudflared/config.yml` and fill in your
UUID and hostname.

## Running it

Test in the foreground first, with the server already running:

```bash
cloudflared tunnel run levelpace
```

Visit `https://levelpace.yourdomain.com/api/stats`. You should get JSON.

Once that works, install it as a service so it survives reboots:

```bash
sudo cloudflared service install
```

## The submission token

**Set one before you put this on a public URL.** Without it, anyone who finds
the address can write rows into your board — and a public hostname *will* be
found by scanners.

Generate one:

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(24))"
```

Start the server with it:

```bash
LEVELPACE_TOKEN='<the token>' python3 server/levelpace_server.py --port 8080
```

And put it on the **second line** of the `server.txt` you distribute:

```
https://levelpace.yourdomain.com
<the token>
```

Be clear-eyed about what this buys you: the token is inside the folder you
hand out, so **everyone you invite has it and can pass it on**. It is not a
security boundary against a person. It stops drive-by bots and makes casual
abuse require a deliberate act rather than an accident. Combined with the
submission validation (see the main README), that is a reasonable place to
land for a friendly scoreboard.

## What still goes where

```
uploads   ->  https://levelpace.yourdomain.com   (tunnel -> your Mac)
the board ->  https://monscorps.github.io/levelpace/   (GitHub Pages)
```

Reads come from Pages, so the board stays up when your Mac is off. Only the
upload direction needs the tunnel.

Since the in-game board reads a file the uploader writes, players who only
want to *see* the rankings do not need the website at all.
