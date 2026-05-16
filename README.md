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

- [build/](build/) — script that produces the `.deb` from upstream source
  - [build/patches/](build/patches/) — backport patches, each named after the CVE it fixes
  - [build/conf/](build/conf/) — Debian-packaging configs vendored from upstream (`nginx.conf`, `default.conf`) baked into the `.deb`
- [entrypoint/](entrypoint/) — entrypoint scripts vendored from upstream `nginx/docker-nginx`
- [Containerfile](Containerfile) — produces the final image from the `.deb`
- [test/](test/) — compatibility test (`make test`) + drop-in parity audit (`make smoke`)
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
| this image | 273MB |

We're ~5MB under, mostly because upstream ships `nginx-debug` (a second nginx binary built with `--with-debug`) and we don't — see [Residual risk](#residual-risk). The 4 nginx-module-* packages (`xslt`, `geoip`, `image-filter`, `njs`) and their transitive deps (`libicu72`, `libgd3`, `libgeoip1`, `libxslt1.1`, …) ARE installed in our image to match upstream's filesystem layout.

The remaining sub-MB delta is bookworm point-release drift (e.g. `libssl3` `3.0.11` → `3.0.20`, `libc6` `+deb12u7` → `+deb12u13`, dozens of other tiny bumps) — pinned exact parity would require `snapshot.debian.org`, not worth it.

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
- I lost time looking at `nginx/docker-nginx` at the latest commit (`c90491de`) instead of at the `1.25.5` tag that actually built our image. The latest-commit template had drift — 3 GPG keys vs 1, a newer `15-local-resolvers.envsh` with extra whitespace-trim lines, a subtle regex change in `10-listen-on-ipv6-by-default.sh` — none of which is in the upstream image. The right anchor for reproducing an image is the tag that matches the image's release.
- Our nginx binary was 8.45 MB until I added `strip` to `build.sh` — nginx source's `--with-cc-opt='-g …'` keeps debug symbols, and nginx.org's `debian/rules` strips before packaging (their shipped binary is 1.56 MB). Without `strip`, our image was ~286 MB and I was guessing at the cause; with it, the delta resolved to ~5 MB (mostly `nginx-debug` we don't ship). Always strip shipped binaries.
