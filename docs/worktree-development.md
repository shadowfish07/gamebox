# Worktree development

Gamebox treats the first checkout reported by `git worktree list --porcelain`
as the primary development checkout. It owns the canonical *local development*
snapshot only. The deployed macOS service, Keychain entries, Cloudflare Tunnel,
and `~/Library/Application Support/Gamebox/server` are outside this workflow and
are never read, stopped, copied, or replaced by worktree commands.

## Safety model

| State | Location | Worktree policy |
| --- | --- | --- |
| Tracked source and lockfiles | Git checkout | Supplied by Git; never copied by setup |
| Server secrets | `.gamebox-worktree/secrets.env` | Two independently generated development values, mode `0600`; copied only by explicit `data:pull`, never pushed |
| SQLite development data | `.gamebox-worktree/data/gamebox.db` | One writable database per checkout, mode `0600`; never symlinked |
| Backups | `.gamebox-worktree/backups/` | Per-target, mode `0700`, ignored by Git |
| Flutter/Gradle/Godot outputs | `app/.dart_tool`, build directories, `.gradle`, `game_runtime/.godot` | Disposable and worktree-local |
| Shared AI rules | `.ai` | Ignored local configuration; Orca shares it from the primary checkout through `orca.yaml`; never committed |
| E2E artifacts | `artifacts/` | Worktree-local, ignored, sanitized by the harness |
| Android app state | Emulator package data, SharedPreferences, secure storage, downloads | Device-local and shared by every checkout using that device/package; never synchronized |
| Port registry and Android lease | Absolute Git common directory | Shared coordination metadata, mode `0600`/`0700`; never committed |

Setup does not copy a deployed database, Keychain secret, `.env`, browser state,
app token, invite, artifact, build output, or log. A fresh worktree begins with an
empty isolated SQLite database and new development secrets.

## Commands

Run commands from the checkout they should own:

```bash
bash tool/worktree.sh setup
bash tool/worktree.sh status
bash tool/worktree.sh up
bash tool/worktree.sh down
bash tool/worktree.sh data:pull
bash tool/worktree.sh data:push
bash tool/worktree.sh e2e
```

`setup` is idempotent. It derives identity from the canonical checkout path and
Git common directory, allocates one stable free loopback port, generates secrets
only when absent, runs the build-only toolchain check, downloads Go modules, and
runs `flutter pub get --enforce-lockfile`. Repeated setup preserves the database,
secrets, port, and debugging state.

For Orca-managed worktrees, `orca.yaml` declares `.ai` under
`worktree.sharedDirectories`. Orca shares that ignored directory from the primary
checkout before setup runs. The source must exist as a directory in the primary
checkout and remain gitignored; otherwise Orca skips it. The checked-in
`orca.yaml` entry must also have reached the project's primary checkout before
creation; adding it only on the branch being used as the new worktree's base is
too late for that creation. A worktree created directly with Git must initialize
its local `.ai` configuration separately.

`up` builds `gameboxd` and runs it in the foreground. It binds strictly to the
allocated `127.0.0.1` port and uses only this checkout's database. It prints both
the host URL and the Android-emulator `10.0.2.2` URL. The PID file is advisory;
`down` checks the exact binary path and canonical working directory before it
signals a process, and refuses on a PID-ownership mismatch. Run `down` twice is a
safe no-op.

Worktree commands never point the app at `https://gamebox.zqydev.me` and never
perform remote service mutations. A release build/deployment remains an explicit
separate workflow. Build a debug client for the current worktree server with the
URL printed by `status`, for example:

```bash
(cd app && flutter build apk --debug \
  --dart-define=GAMEBOX_API_BASE_URL=http://10.0.2.2:<allocated-port>)
```

Do not run that APK concurrently from multiple worktrees on the same emulator:
the Android package name and its secure/local storage are shared.

## Directional data synchronization

`data:pull` is valid only in a linked worktree. It prints the source, target,
replacement allowlist, and exclusions; refuses while the target server is
active; snapshots the primary SQLite database through SQLite's online backup
API; verifies `PRAGMA integrity_check`; backs up target data and secrets; then
atomically installs the primary development database and its exact two matching
development secrets. This keeps invite/session hashes coherent. Backups are
written beneath `.gamebox-worktree/backups/pull-<UTC timestamp>.*`.

`data:push` deliberately exits with status 3. Gamebox stores gameplay, users,
invite hashes, sessions, and launch/resume credentials in one database, so no
narrow reverse-sync allowlist is currently safe. Source and schema changes
return through Git. Neither command touches the deployed database or Keychain.

To recover after a pull, stop the target, inspect the printed backup directory,
and copy its `gamebox.db` and `secrets.env` back into the corresponding private
state paths with modes `0600`. Preserve the failed state elsewhere first if it
is still useful for debugging.

## Android lease and cleanup

Repository Android mutators coordinate through a lease pool at:

```text
<absolute git common dir>/gamebox-android-leases/
```

`tool/e2e_android.sh` automatically leases one complete managed slot: slot 0 is
`Gamebox_A0_API_36`/`Gamebox_B0_API_36` on 5560/5562, and slot 1 is
`Gamebox_A1_API_36`/`Gamebox_B1_API_36` on 5564/5566. The slots may coexist.
`ensure_test_avds.sh`, `smoke_android_host.sh`, `smoke_android_release_apk.sh`,
and supplied-serial E2E use the exclusive lease and wait for both slots to be
idle. The legacy `gamebox-android.lease` is also treated as an exclusive
barrier during migration. Owner records contain a random token, canonical
worktree path, PID, lease kind/slot, device identities, and acquisition time,
but no credentials. `GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS` controls the wait
(default 900 seconds). A lease is reclaimed only when its recorded PID is
provably dead; an alive or ambiguous PID remains busy.

The two-AVD E2E may start only its leased pair. It records its slot and whether
it started each emulator. Normal cleanup and `worktree.sh down` may stop only
those owned instances after matching AVD/serial/PID evidence.
Provided or pre-existing devices are never stopped. Package installs, package
data, secure storage, and emulator userdata remain shared device state; the
lease serializes access rather than pretending they are worktree-local.

## Orca

The committed root `orca.yaml` runs setup for new Orca worktrees and `down` for
archive. The local repository should use `setupRunPolicy=run-by-default` and
`setupAgentStartupPolicy=wait-for-setup`; these are Orca-local settings, not YAML
fields. Orca removal skips archive hooks unless the hook-running option is used:

```bash
orca worktree rm --worktree <selector> --run-hooks --json
```

The hook files must already exist on the selected base ref. Manually created Git
worktrees use the same `bash tool/worktree.sh setup` command and do not depend on
Orca. No `.worktreeinclude` is used because there is no audited broad local file
or directory that should be copied implicitly.
