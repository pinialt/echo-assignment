# nginx:1.25-bookworm — drop-in replacement

Rebuild of `nginx:1.25-bookworm` from upstream source on `debian:bookworm-slim`,
with at least two CVEs eliminated (one via dependency/source version bump, one
via backported patch), shipped as a drop-in container image plus an automated
HTTP compatibility test against the upstream image.

## Requirements


## Layout

- [build/](build/) — Dockerfile/script that produces the `.deb` from upstream source
  - [build/patches/](build/patches/) — backport patches, each named after the CVE it fixes
- [Containerfile](Containerfile) — produces the final image from the `.deb`
- [test/](test/) — compatibility test (`make test`)
- [scans/](scans/) — Trivy + Grype reports (baseline and fixed)
- [Makefile](Makefile) — one-command reproduction

## Build instructions

TODO

## Image size

| | Size |
|---|---|
| `nginx:1.25-bookworm` (upstream) | TODO |
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
