# Self-hosting the buzzer server

Macpardy's phone buzzers normally run inside the app (the **built-in server**). The
**self-hosted server** is the same buzzer, run as a Docker container, so that phones on other
networks can join over the internet: players at home, on mobile data, or on a network that
blocks devices from seeing each other (#99).

> **Phones on the same network as the Mac? Use the built-in server.** It needs no setup,
> and it's the default. Playing on the self-hosted server from the network it runs on
> (NAT loopback) isn't supported.

```
 phones ──https/wss──▶ Caddy (HTTPS, Let's Encrypt) ──▶ macpardy-buzzer-server ◀──wss── Mac (host)
                       your-name.duckdns.org            rooms by Game PIN
```

The Mac connects to the server's `/host` path with the **host token** and opens a room. The
server makes the Game PIN and sends it to the Mac, which shows it with a QR code as usual.
Phones open `https://<your domain>/?code=<PIN>`. One server runs several rooms.

## What you need

- A machine that stays on for the game, with Docker and Docker Compose.
- A domain name pointing at your network's public IP. A free [DuckDNS](https://www.duckdns.org)
  name works.
- Ports **80** and **443** forwarded from your router to that machine. Caddy needs 80 to get
  its certificate and 443 to serve phones.

## 1. Get the files

This repo holds the server and its Docker files. Either build from a checkout
or use a published image (below).

```sh
git clone https://github.com/liljimmyk99/Macpardy-Buzzer-Server.git
cd Macpardy-Buzzer-Server
```

To use the published image instead of building, set `image:` of the `buzzer` service in
`docker-compose.yml` to `ghcr.io/liljimmyk99/macpardy-buzzer-server:<version>` and remove its
`build: .` line. Images are tagged with the server's own version (`VERSION`),
which is separate from the Macpardy app's version.

## 2. Point a domain at your network

With DuckDNS: create a subdomain on duckdns.org and set it to your public IP. If your IP
changes, the compose file has an optional updater service; set `DUCKDNS_SUBDOMAIN` and
`DUCKDNS_TOKEN` in `.env` and start with `--profile duckdns` (step 4).

Then forward TCP ports 80 and 443 to the machine running Docker.

## 3. Configure

```sh
cp .env.example .env                      # set MACPARDY_DOMAIN=your-name.duckdns.org
openssl rand -hex 32 > deploy/host_token.txt
chmod 0444 deploy/host_token.txt          # the server runs as a non-root user
```

The **host token** is the password for opening a room. Keep it private: anyone who has it
can use your server. It must be at least 16 characters. Compose passes it to the container
as a Docker secret, so it doesn't show in `ps` or `docker inspect`.

## 4. Start it

```sh
docker compose up -d                      # or: docker compose --profile duckdns up -d
curl https://$MACPARDY_DOMAIN/healthz     # ok
docker compose logs -f buzzer
```

Caddy gets a certificate for `MACPARDY_DOMAIN` on first start (it needs ports 80 and 443
reachable). To try the setup on one machine first, set `MACPARDY_DOMAIN=localhost`; Caddy then
uses its own local certificate.

You can also check a deployment from end to end with the smoke test (Node 22+). It plays a short
game, so don't run it while a real game is using the server:

```sh
node scripts/smoke-test.mjs https://$MACPARDY_DOMAIN "$(cat deploy/host_token.txt)"
```

## 5. Connect Macpardy

**Settings > Buzzers**: choose **External server**, enter `https://<your domain>` and the host
token. The token is kept in the Keychain and is never shown again. It applies the next time a
game starts; the Game PIN and QR code then come from the server. It only travels over `wss://`
(or `ws://` to a loopback address, for testing).

## The reverse proxy and HTTPS

The server speaks plain HTTP and WebSocket. The reverse proxy handles HTTPS, and the compose
file uses [Caddy](https://caddyserver.com) (`deploy/Caddyfile`), which gets and renews a Let's
Encrypt certificate, upgrades WebSockets on its own, and sets `X-Forwarded-For` to the phone's
address.

You can use another proxy (nginx, Traefik) if it passes WebSocket upgrades, sets
`X-Forwarded-For`, and is the only way to reach the server. Then set
`MACPARDY_TRUST_FORWARDED_FOR=true`; never set it when the server is reachable directly, or
anyone could pick the address the rate limits see. The server uses the last `X-Forwarded-For`
entry, the one your proxy added.

## Limits and the grace period

| Variable | Default | |
|---|---|---|
| `MACPARDY_MAX_ROOMS` | `20` | Games at once |
| `MACPARDY_MAX_PHONES_PER_ROOM` | `24` | Beyond it a phone is refused (`roomFull`) |
| `MACPARDY_MAX_PENDING_PHONES` | `200` | Sockets that haven't joined a room yet |
| `MACPARDY_GRACE_PERIOD` | `45` | Seconds to keep a room after its Mac drops, 30–60 |

If the Mac's connection drops (Wi-Fi blip, laptop sleep), its room and phones are kept for the
grace period. Phones show the buzzers as unavailable, and when the Mac comes back it takes the
room back and the game carries on. After the grace period every phone is told the game ended
and the room is closed. Message sizes are limited too (64 KB from phones, 1 MB from the Mac).

All settings, with their flags, are in the table in
[the README](../README.md#configuration).

## Security and privacy

- Opening or resuming a room needs the host token. It's compared in constant time and never
  logged. More than 5 wrong tokens from one address in a minute lock that address out for 5
  minutes.
- Wrong Game PINs are rate limited per address across the whole server (more than 5 in 60 s
  locks the address out for 30 s).
- Final answers pass through the server. Its log never contains clue text, answer text, Final
  answers or the host token. It does log phone IP addresses, team names and browser versions,
  to diagnose disconnects.
- The container runs as a non-root user and publishes no port of its own; only Caddy reaches it.

## Updating and troubleshooting

```sh
git pull && docker compose up -d --build   # or: docker compose pull && docker compose up -d
```

Games running on the server end when it restarts. Update between games.

| Symptom | Check |
|---|---|
| Caddy can't get a certificate | Ports 80 and 443 reach the machine; the domain points at your public IP; `docker compose logs caddy` |
| Macpardy says it can't connect | The URL is `https://…` with no path; the token matches `deploy/host_token.txt`; `curl …/healthz` |
| Joins or the host are refused repeatedly | The wrong-token and wrong-PIN lockouts above; wait a few minutes |
| Everyone appears as the same address | `MACPARDY_TRUST_FORWARDED_FOR=true` is missing behind a proxy |
| Works from outside, not from home | NAT loopback isn't supported; use the built-in server on your own network |

Protocol details: [buzzer-protocol.md](https://github.com/liljimmyk99/Macpardy/blob/master/docs/buzzer-protocol.md#self-hosted-server).
