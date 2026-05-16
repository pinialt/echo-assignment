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

My notes:
- nginx is generous and gives us the -V command, giving the exact configuration it was built with. Other packages might have a different command, or none - and then you would actually need to reverse engineer using `--version`/`dpkg -s` + `debian/rules` from the source package + `ldd` on the binary.
- `nginx:1.25-bookworm` is a floating tag, and currently tied to version 1.25.5 of nginx. in production we should pin the digest key to make sure no breaks occure on updated tags.
