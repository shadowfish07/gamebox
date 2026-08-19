# Gamebox

Gamebox is an Android game collection with a Flutter host, Godot game runtime,
and an authoritative Go server. The first playable game is two-player Gomoku.

## Run the local server

The server requires two independent secrets of at least 32 bytes. Its SQLite
file must live in an existing private directory that is not group- or
world-writable.

```bash
gamebox_data_dir=$(mktemp -d)
export GAMEBOX_DB_PATH="$gamebox_data_dir/gamebox.db"
export GAMEBOX_JWT_SECRET="$(openssl rand -base64 32)"
export GAMEBOX_TOKEN_PEPPER="$(openssl rand -base64 32)"
(cd server && go run ./cmd/gameboxd)
```

Optional configuration:

- `GAMEBOX_ADDR` defaults to `127.0.0.1:8080`.
- `GAMEBOX_DB_PATH` defaults to `server/data/gamebox.db` when the daemon is
  launched from the repository root. Create `server/data` with mode `0700`
  before relying on that default.

`GET /healthz` returns exactly `{"status":"ok"}` as JSON. The daemon writes
JSON-line operational logs to stderr. Request, WebSocket connection, and match
identifiers are logged when applicable; invitation and session credentials are
never logged. `SIGINT` and `SIGTERM` stop new HTTP work, allow a 10-second HTTP
grace period, close WebSockets and background workers, and then close SQLite.

## Create one-time invitation codes

`gameboxctl` reads `GAMEBOX_TOKEN_PEPPER`, prints plaintext invitations only in
its single success response, and persists only domain-separated hashes. A
batch is atomic: generation, collision, insertion, or commit failure produces
no success JSON and no partial batch.

```bash
(cd server && go run ./cmd/gameboxctl invite create \
  --count 2 --db "$GAMEBOX_DB_PATH" --json)
```

Success output has the stable shape:

```json
{"invites":["first-one-time-code","second-one-time-code"]}
```

`--count` must be between 1 and 1000. Keep this output out of ordinary logs and
committed artifacts.

## Inspect a match without changing application data

The E2E query reuses the authoritative match snapshot and Gomoku event replay;
it does not maintain a second board implementation.

```bash
(cd server && go run ./cmd/gameboxctl match show \
  --id 11111111-1111-4111-8111-111111111111 \
  --db "$GAMEBOX_DB_PATH" --json)
```

The JSON response contains the match ID, game ID, status, revision, result,
winner, both players with seat/color, board size, and all 225 board cells. The
query does not update users, presence, matches, events, or credentials; normal
SQLite open/read sidecar behavior may still occur. An unknown match exits
nonzero without echoing the supplied identifier.

For both management commands, exit code `0` means success/help, `1` means an
operational failure, and `2` means invalid command syntax. Flags are strict and
positional extras are rejected.

## Verification

```bash
(cd server && go test ./... -race -count=1 && go vet ./...)
bash tool/verify_fast.sh
```

Cloudflare Tunnel, machine boot auto-start, production log rotation, and SQLite
backup/restore belong to the documented follow-up specification **F2 公网部署与
可靠运行**. They are intentionally outside this local playable-loop phase.
