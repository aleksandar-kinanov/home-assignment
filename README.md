# DevOps Home Assignment

Containerizes a small Node/Express/TypeScript app, builds and promotes its image
through GitHub Actions, deploys it to a local Kind cluster via Helm, and stands
up a Prometheus + Grafana monitoring stack for it — all from a single command.

## Quick start

Prerequisites (all must be on `PATH`):

- `docker` (with Docker Desktop, or an equivalent daemon, running)
- `kind`
- `kubectl`
- `helm`
- `curl`
- `jq`

```bash
./setup.sh
```

This creates a Kind cluster, builds the app image, loads it into the cluster,
deploys the app + monitoring stack via Helm, and verifies Prometheus is
actually scraping the app before printing:

```
App:        http://localhost:8080/          (metrics: http://localhost:8080/metrics)
Prometheus: http://localhost:9090/
Grafana:    http://localhost:3001/           (admin credentials: charts/app/values.yaml)
```

Safe to re-run — cluster creation, image build/load, and the Helm deploy are
all idempotent. To tear down just what this script created (the
`devops-assignment` Kind cluster and the local app image — not anything else
on the machine):

```bash
./setup.sh --cleanup
```

## What gets deployed

Everything lives in a single Helm chart (`charts/app/`) so `setup.sh` only
ever needs one `helm upgrade --install`:

- **The app** — Deployment + Service, liveness probe on `/health`, readiness
  probe on `/ready` (tuned to the app's `READY_DELAY_MS` startup delay).
- **Prometheus** — scrapes the app's `/metrics` on a static target (the app's
  in-cluster Service DNS name). Static rather than Kubernetes service
  discovery is a deliberate choice: `replicaCount` defaults to 1, so SD would
  resolve to the exact same pod at the cost of a ServiceAccount + RBAC for no
  practical benefit.
- **Grafana** — auto-provisioned with the Prometheus datasource and the "App
  Overview" dashboard (`charts/app/dashboards/app-dashboard.json`) on
  startup, no manual import.

All three are hardened the same way: non-root, read-only root filesystem,
all capabilities dropped, seccomp `RuntimeDefault`. All three are reachable
directly on `localhost` via NodePort Services + `kind-config.yaml`'s
`extraPortMappings` — no `kubectl port-forward` needed.

Toggle the whole monitoring stack off with `--set monitoring.enabled=false`
if you just want the app.

## Repo structure

```
app/                    Node/Express/TypeScript app (src/, Dockerfile, tests)
charts/app/              Single Helm chart: app + Prometheus + Grafana
charts/app/dashboards/    Exported Grafana dashboard JSON
kind-config.yaml          Kind cluster config (NodePort -> localhost mappings)
setup.sh                  One-command bootstrap (+ --cleanup)
.github/workflows/ci.yml  CI/CD pipeline (see below)
```

## CI/CD pipeline

Five jobs in `.github/workflows/ci.yml`:

1. **`Detect changes`** — PRs only. Checks the PR's changed files via the
   GitHub API once and outputs both an `app_changed` and a `charts_changed`
   flag, so the same detection logic isn't duplicated across jobs (`Promote`
   runs in a separate workflow run after merge and can't share job outputs
   with this one, so it re-checks independently — see below).
2. **`Test & Lint`** — depends only on `Detect changes`, skips unless
   `app_changed`. Runs `npm ci && npm run lint && npm test`.
3. **`Helm Lint`** — depends only on `Detect changes` (not on `Test & Lint`,
   so it runs in parallel with it), skips unless `charts_changed`. Runs
   `helm lint charts/app`.
4. **`Build & Push Image`** — skips entirely if the PR doesn't touch `app/`.
   Neither this nor `Test & Lint`/`Helm Lint` runs on push/merge either — the
   merge commit is the same code already tested and built on the PR,
   re-running would be redundant. Pushes the image to GHCR tagged with the
   PR's short commit SHA, generates a CycloneDX SBOM from the pushed image
   (via Syft), and attaches it as a build attestation on the image's digest —
   verifiable later with `gh attestation verify`.
5. **`Promote`** — runs on push to `main` (i.e. after a merge). Finds the PR
   that was just merged; if it touched `app/`, computes the next version (see
   below), pushes that as a git tag on the merge commit, and re-tags the
   already-built image with it via `docker buildx imagetools create` — a
   manifest-only operation, **no rebuild**. If the merged PR didn't touch
   `app/`, nothing is promoted.

The image that ends up tagged with a release version is always byte-for-byte
what was built, tested, and scanned on the PR — never a fresh rebuild that
could drift from what was reviewed. To make that literally true, every PR job
checks out the PR's **head SHA** rather than GitHub's default merge commit,
so tests, lint, and the image build all run against the identical commit.
(The trade-off: breakage caused by `main` moving underneath a long-lived PR
isn't caught until merge — enable "require branches to be up to date before
merging" in branch protection if that matters.)

`main` should have branch protection requiring PRs, plus these required
status checks:

- `Test & Lint`
- `Helm Lint`
- `Build & Push Image`

Direct pushes to `main` bypass this whole flow and `promote` will fail loudly
if there's no PR to attribute the merge to. All three required checks can
show as "skipped" rather than "success" on a PR that doesn't touch the
relevant path (that's `Detect changes` doing its job) — GitHub treats a
skipped required check as satisfying the requirement, so this doesn't block
merging.

### Versioning

Patch bumps are **automatic**. Every merge that touches `app/` makes
`promote` list all existing `vX.Y.Z` git tags, sort them version-aware, take
the highest, and bump the patch number (`v0.1.0` if none exist yet). CI never
tries to judge whether a change is a fix, feature, or breaking change — it
always assumes the smallest possible bump.

Minor/major bumps are **manual** — push the target tag yourself before
merging the PR that should land on it:

```bash
git tag v0.2.0 <sha>      # e.g. current main HEAD, for a minor bump
git push origin v0.2.0
```

The next `app/`-touching merge will see `v0.2.0` as the new highest tag and
compute `v0.2.1` from it. Note the manual tag itself doesn't get a matching
container image automatically — only `promote`'s own automatic bumps push an
image tag (via `imagetools create` from that merge's build). If you need an
image at the exact manual version, retag it yourself the same way:

```bash
docker buildx imagetools create \
  --tag ghcr.io/<repo>:v0.2.0 \
  ghcr.io/<repo>:<short-sha-of-image-to-promote>
```

No `latest` tag is ever used — deploys always pin an explicit `vX.Y.Z`.

## Validating monitoring locally

`setup.sh` already fails loudly if Prometheus isn't actually scraping the
app (`up{job="app"}` must read `1`), so a successful run is itself the proof.
To look deeper:

```bash
curl -s "http://localhost:9090/api/v1/targets" | jq .
curl -s -u admin:admin "http://localhost:3001/api/search"
```

The Grafana admin credentials are `charts/app/values.yaml`'s
`monitoring.grafana.adminUser`/`adminPassword` — fixed local credentials,
acceptable only because this is an ephemeral, non-externally-exposed Kind
cluster.
