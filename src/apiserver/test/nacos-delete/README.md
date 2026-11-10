# Nacos deletion propagation tests (higress-group/higress#4538)

This directory reproduces and verifies the deletion-propagation defect
reported in higress-group/higress#4538: when Higress standalone uses Nacos
storage, deleting an Ingress whose raw Nacos content had been overwritten with
invalid data (for example a single character `x`) left the derived route on
the gateway forever, because the API server re-decoded the stale cached
content at deletion time, failed, and silently skipped both the `Deleted`
watch event and the listener cancellation.

Two layers of verification live here:

| layer | entry point | scope |
| --- | --- | --- |
| unit-level state machine contract | `../../pkg/registry/nacos_rest_test.go` | fake Nacos client, real Kubernetes Ingress codec, drives the reconcile loop directly |
| real Nacos -> API watch chain | `./verify.sh` (chain mode) | isolated Nacos container + API server built from the current tree; publishes/updates/deletes through the real Nacos HTTP API, consumes the real Kubernetes watch stream |
| real standalone data plane | `./verify.sh gateway <variant>` | full 2.2.3 stack (controller, pilot, gateway) from the repository compose flow, with the API server swapped for a prebuilt variant image |

## Prerequisites

- Docker + docker compose v2
- bash, curl, openssl (on Windows use Git Bash; the script neutralizes MSYS
  path rewriting for `openssl -subj` itself)
- For the gateway mode: prebuilt API server images (see below)

Nothing in this directory publishes images; every compose project name and
volume is exclusive to this test (`higress-nacos-delete-4538*`).

## Chain mode (default)

```bash
cd src/apiserver/test/nacos-delete
./verify.sh            # add --keep to keep the stack running afterwards
```

The script:

1. generates throwaway TLS certificates for the API server (`./certs`),
2. builds the API server image from the current working tree and starts it
   together with an isolated Nacos v3.0.1 server (`./compose.yaml`),
3. creates the `higress-system` namespace through the Nacos v3 admin API,
4. runs the three sequences above, consuming
   `https://localhost:18443/.../ingresses?watch=true` throughout,
5. tears the stack down (unless `--keep`).

Every wait is bounded to 60 seconds; on timeout the container logs are
collected under `.runtime/logs/` and the script fails.

Note: the Nacos v1 write API (`/nacos/v1/cs/configs`) silently ignores
`namespaceId` on Nacos 3.x compat mode; the script therefore uses the v2
config API for publishing and deleting, so the writes really land in the
`higress-system` namespace the API server watches.

## Gateway mode

Build the two API server variants once:

```bash
# fix variant: the current working tree
docker build -t higress-4538/apiserver:fix ../../

# baseline variant: the tree before the fix (tests-only commit on this branch
# or any commit before "fix: retain last valid Nacos objects")
git worktree add /tmp/higress-4538-baseline <baseline-ref>
docker build -t higress-4538/apiserver:baseline /tmp/higress-4538-baseline/src/apiserver
```

Then run the acceptance for each variant:

```bash
./verify.sh gateway baseline >baseline.log 2>&1
./verify.sh gateway fix      >fix.log 2>&1
```

The gateway mode generates a task-specific slim copy of the repository
compose stack under `.runtime/t4/` (same `initializer -> precheck ->
apiserver -> prepare -> controller -> pilot -> gateway` flow and scripts as
`compose/docker-compose.yml`) with:

- controller/pilot/gateway pinned to the 2.2.3 combination from the issue
  report (digests recorded below),
- the API server replaced by `higress-4538/apiserver:<variant>`,
- a dedicated `canary-backend` (nginx) answering `issue-4538-ok`,
- a dedicated data directory under `.runtime/t4/volumes/`.

It then runs this matrix through the real API server REST surface and the
real gateway:

| # | scenario | assertions (all within 60s) |
| --- | --- | --- |
| 1 | clean delete of `ingresses.canary-test` | API GET 404, gateway HTTP 404, route gone from `config_dump` |
| 2 | re-publish, overwrite the raw Nacos content with `x`, wait at least one full refresh interval, delete | same as #1 |
| 3 | gateway restart after #2 | still no route in `config_dump`, gateway keeps returning 404 |
| 4 | re-publish under the same name, delete again | route returns (HTTP 200 `issue-4538-ok`), second deletion cleans up again |

Expected results:

- `baseline`: scenario 1 passes (the ticker had refreshed the cache with
  valid content), scenario 2 fails - the deletion is lost and the gateway
  keeps serving the route; this is the reported defect.
- `fix`: all scenarios pass.

## Acceptance results (2026-10-12, Higress 2.2.3 data plane)

Full-standalone runs of `verify.sh gateway <variant>` on this branch, with
the versions and digests listed above (raw logs under the repository
`reports/4538/` working directory of the contributor):

| scenario | baseline (`higress-4538/apiserver:baseline`) | fix (`higress-4538/apiserver:fix`) |
| --- | --- | --- |
| clean delete propagated | PASS | PASS |
| delete after `x` overwrite + full refresh | **FAIL - the gateway kept answering 200; the route disappeared from `config_dump` right after the delete and then resurrected (0 -> 4 occurrences) because the controller never received a `Deleted` event** | PASS |
| gateway restart keeps the route deleted | (not reached; route still serving) | PASS |
| recreate under the same name + second delete | (not reached) | PASS |
| unrelated keepalive route untouched | PASS until the stuck route blocked the run | PASS |

Evidence files (per variant, written under `.runtime/t4-logs/`):
`config-dump-before-clean-delete.json`, `config-dump-after-clean-delete.json`,
`config-dump-before-x-delete.json`, `config-dump-after-x-delete.json`,
`config-dump-final.json`, `api-watch.jsonl`, plus `docker compose logs -t`
for nacos/apiserver/controller/pilot/gateway. For the fix variant the dumps
show the `/canary-test` route removed permanently across every deletion and
the gateway restart; for the baseline variant the dumps show the route
resurrecting after an initial transient removal while the gateway kept
serving HTTP 200, matching the issue report.

The chain mode passed all three sequences with the fix
(`reports/4538/t3-verify-run.log`) and the unit-level contract suite is red
on the baseline and green on the fix (`reports/4538/baseline-test-red.log`).

## Evidence layout

Each run writes to `.runtime/` (and the keep-out directory `.runtime/t4/`):

- `.runtime/events.jsonl` / `.runtime/t4-logs/api-watch.jsonl` - raw API
  watch streams captured during the run,
- `.runtime/t4-logs/config-dump-{before,after}-*.json` - gateway
  `config_dump` snapshots around each deletion,
- `.runtime/logs/` or `.runtime/t4-logs/` - `docker compose logs -t` for
  nacos, apiserver, controller, pilot, gateway collected on failure and at
  the end of a failed run.

Recorded image identities used for the acceptance runs of this task:

| image | digest |
| --- | --- |
| `higress-4538/apiserver:fix` | sha256:4a5cb8e1e51705705ae90e7abf049d47af9cc56990178cdfa0b3b1eae7ba2672 (image id) |
| `higress-4538/apiserver:baseline` | sha256:a37940adb89d86634f4ea3597c4b9db539ee9415b04858e4539244e484f13ed8 (image id) |
| `higress:2.2.3` | sha256:11fb1244d35615210faaa6bda54cd187e6a445e09892da4cc2619896c34b0e11 |
| `pilot:2.2.3` | sha256:6e6520eff97e1404bbbfa116d913bdb1a764e484f7a6a1320ec5e62dd13b24fc |
| `gateway:2.2.3` | sha256:cf1fa0e100e79890b1de15c74f41a21fabba8f854b9d004d8f5b8ccb48a95c5d |
| `nacos-server:v3.0.1` | sha256:30a39cb0c54d081f002a27d83ee856bbb6762a899bafb44a7206b99a446f62f1 |
| `runner:0.0.3` | sha256:fff6e0f323f9ad6d9fd33df45a295256820663de9b07f363a9649c14b4ff328e |

## Run boundaries

- The gateway mode talks to a task-private Nacos on `localhost:18848` and a
  task-private API server on `localhost:18443`; never point it at a shared or
  production Nacos.
- The fixed refresh interval is the production default (10 seconds,
  `NACOS_LIST_REFRESH_INTERVAL_SECS`); nothing in the fix or the tests may
  shorten it, clear caches, or rely on restarts for deletions to propagate.
  The gateway-restart scenario only asserts that an already-propagated
  deletion survives a restart.
- A gateway mode run needs roughly 3-4 GB of free memory for the full stack.
- To reset all local state, remove `.runtime/` and `./certs/`; both are
  task-local artifacts and safe to delete.
