# nginx:1.25-bookworm — drop-in replacement

Rebuild of `nginx:1.25-bookworm` from upstream source on `debian:bookworm-slim`,
with at least two CVEs eliminated (one via dependency/source version bump, one
via backported patch), shipped as a drop-in container image plus an automated
HTTP compatibility test against the upstream image.

## Requirements

- Docker Desktop (or any Docker daemon that can run `linux/amd64` images)
- Trivy (tested with 0.70.0)
- grype (tested with 0.112.0)
- `make` and `python3` (the baseline target uses `python3 -m json.tool` to pretty-print upstream image config)

## Layout

- [build/](build/) — Dockerfile/script that produces the `.deb` from upstream source
  - [build/patches/](build/patches/) — backport patches, each named after the CVE it fixes
- [Containerfile](Containerfile) — produces the final image from the `.deb`
- [test/](test/) — compatibility test (`make test`)
- [scans/](scans/) — Trivy + Grype reports (baseline and fixed)
- [Makefile](Makefile) — one-command reproduction

## Baseline

`make baseline` pulls `nginx:1.25-bookworm` and captures the reference data we'll compare our drop-in build against. Outputs (not committed):

- `baseline/upstream-nginx-v.txt` — `nginx -v`
- `baseline/upstream-nginx-V.txt` — `nginx -V` (configure flags, modules, compile-time defaults)
- `baseline/upstream-id-nginx.txt` — `id nginx` (uid/gid of the runtime user)
- `baseline/upstream-config.json` — `docker inspect` of the image config (entrypoint, cmd, workdir, exposed ports, env, user)
- `baseline/upstream-size.txt` — on-disk image size (`docker images --format '{{.Size}}'`)
- `scans/baseline-trivy.{txt,json}` and `scans/baseline-grype.{txt,json}` — vulnerability scans

## Build instructions

TODO

## Image size

| | Size |
|---|---|
| `nginx:1.25-bookworm` (upstream) | 278MB |
| this image | TODO |

## CVEs fixed

| CVE | Severity | Component | Fix method | Evidence |
|---|---|---|---|---|
| TODO | | | bump / backport / remove | |
| TODO | | | bump / backport / remove | |

## Residual risk

TODO — what's still flagged, why, what we'd do next.

## Notes

- What AI tooling was used for, and where it helped / hurt: TODO
- Surprises / things I'd do differently with more time: TODO
