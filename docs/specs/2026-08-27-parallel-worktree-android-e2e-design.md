# Parallel Worktree Android E2E Design

## Objective

Allow two linked Gamebox worktrees to run the complete Android E2E gate at the
same time. Each run owns two Android emulators, so the host runs four managed
emulators in total. A device, package state, emulator process, server, database,
build output, or E2E artifact must never be shared between the two active runs.

The ordinary command remains:

```bash
bash tool/worktree.sh e2e
```

The command automatically allocates an available emulator pair. Callers do not
select a slot or serial in the normal workflow.

## Scope

This change covers:

- automatic allocation of one of two managed emulator pairs;
- concurrent E2E execution by two worktrees from the same Git common directory;
- shared-versus-exclusive coordination with other repository Android mutators;
- ownership-aware startup, interruption, cleanup, status, and stale recovery;
- compact success output and actionable failure output;
- deterministic fixture tests and a real two-worktree/four-emulator acceptance
  run.

This change does not make arbitrary supplied devices concurrently usable, add
physical-device E2E, increase the pool beyond two pairs, or change user-facing
UI behavior.

## Managed Emulator Pool

The pool contains two fixed slots:

| Slot | A device | A serial | B device | B serial |
| --- | --- | --- | --- | --- |
| 0 | `Gamebox_A0_API_36` | `emulator-5560` | `Gamebox_B0_API_36` | `emulator-5562` |
| 1 | `Gamebox_A1_API_36` | `emulator-5564` | `Gamebox_B1_API_36` | `emulator-5566` |

Within each pair, A retains the large-phone/light-mode role and B retains the
narrow-phone/dark-mode role. Both pairs use the existing API 36 ARM64 image and
the existing viewport assertions.

Fixed slots make ownership and cleanup inspectable. Dynamic combinations of
individual devices are intentionally excluded because they introduce partial
allocation, recovery, and pairing states without improving the required
two-worktree capacity.

## Lease Architecture

The current single `gamebox-android.lease` becomes a lease pool under the
absolute Git common directory:

```text
gamebox-android-leases/
  allocator.lock/
  exclusive/
    owner
  slots/
    0/
      owner
    1/
      owner
```

`allocator.lock` is held only while inspecting or changing lease metadata. It
must use the existing safe directory-lock and dead-PID recovery principles.

An E2E run acquires exactly one slot. It may coexist with an owner of the other
slot. Allocation checks slots in stable numeric order while holding the
allocator lock, creates one complete owner record, then releases the allocator
lock. There is no externally visible state in which only one device in a pair
is owned.

Android mutators other than the managed E2E pool acquire `exclusive`. An
exclusive owner may exist only when both slots are idle, and a slot may be
allocated only when `exclusive` is idle. This retains the conservative behavior
of release smoke, host smoke, and other commands whose device scope is not a
managed pool slot.

An owner record contains:

- metadata version;
- random ownership token;
- owner PID;
- canonical worktree root;
- lease kind and slot number, when applicable;
- both AVD names and serials for a slot lease;
- acquisition timestamp.

Lease inheritance requires the same token, lease path, canonical worktree root,
and a live recorded parent PID. A child never releases its parent's lease.

If the legacy `gamebox-android.lease` directory exists, new lease acquisition
treats it as an active exclusive barrier. Existing owners therefore finish
safely during migration; no new implementation may silently delete or bypass
legacy metadata.

## Allocation and Waiting

`tool/e2e_android.sh` acquires a slot before inspecting, creating, starting, or
mutating an emulator. When both slots are busy, it prints one bounded waiting
message containing sanitized owner worktree, PID, slot, device pair, and
acquisition time, then waits.

The existing `GAMEBOX_ANDROID_LEASE_TIMEOUT_SECONDS` setting remains the wait
limit and defaults to 900 seconds. Timeout returns status 75 and reports both
current slot owners. A live or ambiguous owner is never stolen. A recorded
owner is reclaimable only when its PID is provably dead.

Explicit `GAMEBOX_E2E_SERIAL_A` and `GAMEBOX_E2E_SERIAL_B` remain supported for
compatibility. Because supplied serials may name arbitrary emulators or physical
devices, this mode acquires `exclusive` and does not participate in slot
concurrency.

## E2E Runtime Flow

The worktree wrapper continues to provide a stable, independently allocated
server port and worktree-local SQLite state. The E2E run proceeds as follows:

1. Acquire an available managed slot.
2. Persist slot/token ownership in the worktree-local Android runtime metadata.
3. Validate or create only the two AVDs assigned to that slot.
4. Start only missing slot emulators on their fixed ports, recording exact PIDs,
   AVD names, serials, and whether this run started each process.
5. Apply and record the A/B UI-mode and managed viewport settings.
6. Run semantics, build the worktree-local APKs and server tools, and package
   `GAMEBOX_API_BASE_URL=http://10.0.2.2:<worktree-port>`.
7. Install, drive, and inspect only the two leased serials.
8. Write sanitized artifacts only beneath that worktree's existing
   `artifacts/e2e/<run-id>/` directory.
9. Restore owned device settings, remove only E2E-owned packages, stop only
   emulators started by this run, and release the slot.

The same Android application ID is safe because concurrent runs use different
devices. Build directories are safe because each linked worktree has its own
checkout. Servers, databases, secrets, and artifacts retain their existing
worktree isolation.

AVD creation may need a short repository-wide setup lock because Android SDK AVD
metadata is host-global. That setup lock must not cover emulator runtime or E2E
execution. After all four managed AVDs exist, both slots can start and run
independently.

## Ownership and Cleanup

Cleanup is conservative and slot-scoped. Before changing a lease or emulator,
the cleanup path verifies the token, canonical root, slot, serial, AVD name, and
recorded PID where applicable.

Normal exit and signal traps restore only the selected devices and stop only
managed emulator processes started by that run. Pre-existing managed emulators
and explicitly supplied devices are not stopped. A mismatch leaves the
potentially foreign resource intact and makes cleanup fail visibly.

`bash tool/worktree.sh status` reports:

- this worktree's server and data state;
- this worktree's active slot, if any;
- both pool slots and sanitized owners;
- any exclusive or legacy owner.

`bash tool/worktree.sh down` may reclaim only a dead lease owned by the current
worktree. It uses the recorded slot to inspect and stop only that slot's orphaned
managed emulators. It refuses to affect a live owner or another worktree.

## Output and Failure Behavior

Successful default output remains compact: bounded device-phase progress is
allowed, followed by one top-level verdict and artifact location. Successful
subprocess output is captured. `GAMEBOX_TEST_OUTPUT=verbose` continues to stream
it.

On failure, the top-level runner preserves the original nonzero status and
prints the failed phase plus that phase's relevant sanitized stdout and stderr.
Warnings from nested captured steps are summarized. Cleanup failure converts an
otherwise passing run into failure without hiding the completed assertion
result.

Retained logs remain ignored, worktree-local, bounded, and sanitized. Lease
metadata and diagnostics must not contain credentials, invitations, tokens used
by the application, or user-specific device content.

## Implementation Boundaries

The expected implementation touches:

- `tool/lib/android_lease.sh` for shared/exclusive pool allocation, inheritance,
  release, description, and stale recovery;
- `tool/e2e_android.sh` for automatic slot selection and slot-specific AVD
  mappings;
- `tool/ensure_test_avds.sh` for four definitions and selected-pair setup;
- `tool/worktree.sh` for status, stale cleanup, and wrapper integration;
- Android mutator entry points so non-pool operations acquire `exclusive`;
- lease, output, and E2E self-test fixtures;
- `README.md` and `docs/worktree-development.md` for the operational contract.

Unrelated Android, application, game, server, or UI refactoring is outside the
change.

## Automated Verification

Lease fixtures must prove:

- slots 0 and 1 can be held simultaneously by different worktrees;
- a third slot request waits and times out with status 75;
- an exclusive request waits while either slot is active;
- slot requests wait while exclusive or legacy ownership is active;
- allocation never duplicates a slot or exposes partial pair ownership;
- valid child inheritance works and cannot release the parent lease;
- active and ambiguous owners cannot be reclaimed;
- dead owners can be reclaimed without changing the other slot;
- ownership mismatches preserve shared state;
- interrupt and cleanup preserve original exit status semantics.

E2E self-tests must prove:

- each slot maps to the expected AVD names, serials, and ports;
- supplied-serial mode requests exclusive ownership;
- runtime metadata records the selected slot and exact device identities;
- cleanup can address only its recorded slot;
- viewport roles and application API-base construction remain unchanged.

The existing compact-output fixtures must continue to cover compact success,
diagnostic failure, nested warning aggregation, verbose output, and exit-code
preservation. The repository gates are:

```bash
bash tool/test_android_lease.sh
bash tool/e2e_android.sh --self-test
bash tool/verify.sh
```

## Real Concurrency Acceptance

The implementation is not complete based only on fixtures. From one clean
baseline, create two temporary linked worktrees and initialize each normally.
Start `bash tool/worktree.sh e2e` in both worktrees concurrently.

Acceptance requires:

- all four fixed emulator serials are simultaneously healthy;
- the two runs report distinct slots and distinct worktree server ports;
- each run completes its full two-device E2E flow successfully;
- each `summary.json` identifies only its two serials and contains the expected
  commit and installed APK hashes;
- neither run observes, clears, stops, or restores the other slot's devices;
- both worktree-local databases and artifact trees remain distinct;
- final cleanup releases both slots and leaves no owned emulator or server
  process behind;
- a subsequent `bash tool/verify.sh` passes from the implementation worktree.

This is infrastructure behavior and does not change user-facing UI, so the UI
screenshot acceptance rule is not triggered. Any UI change discovered to be
necessary during implementation is a scope change and requires target-runtime
screenshot inspection before completion.
