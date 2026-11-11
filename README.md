# MacpardyBuzzer

The phone buzzer for [Macpardy](https://github.com/liljimmyk99/Macpardy): the rules (`BuzzerCore`), the phone page
(`BuzzerWebPage`), and a **self-hosted server** that lets phones on other networks buzz in
over the internet (#99).

The app runs the buzzer itself by default (the built-in server, for phones on the same
Wi-Fi as the Mac). The self-hosted server is for everything else: players at home, on
mobile data, or on a network that blocks devices from seeing each other.

## How it fits together

```
 phones ──https/wss──▶ Caddy (HTTPS, Let's Encrypt) ──▶ macpardy-buzzer-server ◀──wss── Mac (host)
                       your-name.duckdns.org            rooms by Game PIN
```

- The Mac connects to `/host` with the **host token** and opens a room. The server makes
  the Game PIN and sends it to the Mac, which shows it with a QR code as usual.
- Phones open `https://<your domain>/?code=<PIN>` and join that room.
- One server runs several rooms. If the Mac drops, its room and phones are kept for the
  grace period (30–60 s) so it can reconnect; after that phones are told the game ended.

Protocol details: [`buzzer-protocol.md`](https://github.com/liljimmyk99/Macpardy/blob/master/docs/buzzer-protocol.md#self-hosted-server).

The full setup guide (DuckDNS, port forwarding, HTTPS, troubleshooting) is
[`docs/self-hosting.md`](docs/self-hosting.md). In short:

## Run it with Docker Compose

You need a machine reachable from the internet with Docker, ports 80 and 443 forwarded to
it, and a domain name pointing at it. A free [DuckDNS](https://www.duckdns.org) name works.

```sh
cd Macpardy-Buzzer-Server
cp .env.example .env                      # set MACPARDY_DOMAIN (and DuckDNS, if used)
openssl rand -hex 32 > deploy/host_token.txt
chmod 0444 deploy/host_token.txt          # the server runs as a non-root user
docker compose up -d                      # or: docker compose --profile duckdns up -d
```

Caddy gets a certificate for `MACPARDY_DOMAIN` on first start. Check it:

```sh
curl https://$MACPARDY_DOMAIN/healthz     # ok
docker compose logs -f buzzer
```

Then in Macpardy: **Settings > Buzzers**, turn on the external server, and enter
`https://<your domain>` and the token from `deploy/host_token.txt` (#104).

To try it on one machine first, set `MACPARDY_DOMAIN=localhost`: Caddy uses its own local
certificate instead of Let's Encrypt.

## Configuration

Flags win over environment variables. The token can only come from the environment or a
file, so it doesn't show in `ps`.

| Variable | Flag | Default | |
|---|---|---|---|
| `MACPARDY_HOST_TOKEN` | — | (required) | The host token, at least 16 characters |
| `MACPARDY_HOST_TOKEN_FILE` | `--host-token-file` | | Or a file holding it (Docker secret) |
| `MACPARDY_PORT` | `--port` | `8472` | |
| `MACPARDY_BIND` | `--bind` | `0.0.0.0` | |
| `MACPARDY_PUBLIC_URL` | `--public-url` | | Where phones reach the server; sent to the Mac for information |
| `MACPARDY_TRUST_FORWARDED_FOR` | `--trust-forwarded-for` | `false` | Use `X-Forwarded-For` for client addresses. Only behind a reverse proxy, with the server reachable through it alone |
| `MACPARDY_GRACE_PERIOD` | `--grace-period` | `45` | Seconds to keep a room after its Mac drops, 30–60 |
| `MACPARDY_MAX_ROOMS` | `--max-rooms` | `20` | |
| `MACPARDY_MAX_PHONES_PER_ROOM` | `--max-phones-per-room` | `24` | |
| `MACPARDY_MAX_PENDING_PHONES` | `--max-pending-phones` | `200` | Sockets that haven't joined a room yet |
| `MACPARDY_LOG_LEVEL` | `--log-level` | `info` | `debug`, `info`, `notice`, `warning`, `error` |

## Security

- **Host token.** Opening or resuming a room needs it. It's compared in constant time,
  only travels over `wss://` (through the proxy), and is never logged. More than 5 wrong
  tokens from one address in a minute locks that address out for 5 minutes.
- **Game PINs.** Wrong PINs are rate limited per address across the whole server (more than
  5 in 60 s locks the address out for 30 s). Behind Caddy, set
  `MACPARDY_TRUST_FORWARDED_FOR=true` (the compose file does) so the limit sees each phone,
  not the proxy. The server uses the last `X-Forwarded-For` entry, the one the proxy added.
- **Limits.** Rooms, phones per room, sockets waiting to join, message sizes (64 KB from
  phones, 1 MB from the Mac).
- **Content.** Final answers pass through the server. Its log follows the app's rules: no
  clue text, answer text, Final answers or host token. It does log phone IP addresses, team
  names and browser versions, to diagnose disconnects.
- The container runs as a non-root user with no published port of its own; only Caddy
  reaches it.

## Develop

```sh
swift test                                # all package tests (macOS or Linux)
MACPARDY_HOST_TOKEN=dev-token-0123456789 swift run macpardy-buzzer-server --log-level debug
node scripts/smoke-test.mjs http://127.0.0.1:8472 dev-token-0123456789
```

`scripts/smoke-test.mjs` plays a short game against a running server: a test host opens a
room, a phone joins and buzzes, the host drops and resumes, and the room is closed. Point
it at `https://…` to check a deployment end to end (Node 22+).

| Target | |
|---|---|
| `BuzzerCore` | One room's rules, no I/O. Used by the app and the server |
| `BuzzerWebPage` | `buzzer.html` |
| `BuzzerHostProtocol` | Mac ↔ server messages |
| `BuzzerHub` | Many rooms, host sessions, grace period, config. No I/O |
| `BuzzerServerNIO` | HTTP and WebSocket transport on SwiftNIO |
| `macpardy-buzzer-server` | The executable (`healthcheck` subcommand for Docker) |

## Using it from the app

The Macpardy app depends on this package (`BuzzerCore`, `BuzzerHostProtocol`, `BuzzerWebPage`)
through a pinned version, set in the app's `Project.swift`. Changing the phone protocol or the
host protocol here means releasing a new version and bumping the pin in the app, and updating
the protocol doc in the app repo.

## Releasing

Bump `VERSION` in its own PR, merge it, then run the **Release** workflow on `master`. It
tests, pushes the image to GHCR as `ghcr.io/liljimmyk99/macpardy-buzzer-server:<version>` and
`:latest`, and tags the commit `<version>` (the tag the app pins).
