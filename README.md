# nginx:1.25-bookworm — drop-in replacement

Rebuild of `nginx:1.25-bookworm` from upstream source on `debian:bookworm-slim`,
with at least two CVEs eliminated (one via dependency/source version bump, one
via backported patch), shipped as a drop-in container image plus an automated
HTTP compatibility test against the upstream image.

## Requirements

- Docker Desktop (or any Docker daemon that can run `linux/amd64` images)
- Trivy (tested with 0.70.0)
- grype (tested with 0.112.0)
- `make` and `python3` (≥ 3.10)
- `pytest` — needed by `make test`. Install into a project-local venv with `make setup` (one-shot):
  ```bash
  make setup                  # creates .venv and installs pytest
  # or do it by hand:
  python3 -m venv .venv
  .venv/bin/pip install -r requirements.txt
  ```
  `make test` auto-detects `.venv/bin/python` and uses it; alternatively `source .venv/bin/activate` first.

## Layout

- [build/](build/) — script that produces the `.deb` from upstream source
  - [build/patches/](build/patches/) — backport patches, each named after the CVE it fixes
  - [build/conf/](build/conf/) — Debian-packaging configs baked into the `.deb`, byte-identical to [`nginx/pkg-oss@1.25.5-1`](https://github.com/nginx/pkg-oss/tree/1.25.5-1/debian/debian):
    - `nginx.conf` ← [`debian/debian/nginx.conf`](https://github.com/nginx/pkg-oss/blob/1.25.5-1/debian/debian/nginx.conf)
    - `default.conf` ← [`debian/debian/nginx.default.conf`](https://github.com/nginx/pkg-oss/blob/1.25.5-1/debian/debian/nginx.default.conf) (installed as `/etc/nginx/conf.d/default.conf`)
- [entrypoint/](entrypoint/) — entrypoint scripts vendored from [`nginx/docker-nginx@1.25.5`](https://github.com/nginx/docker-nginx/tree/1.25.5/mainline/debian)
- [Containerfile](Containerfile) — produces the final image from the `.deb`
- [test/](test/) — compatibility test (`make test`) + drop-in parity audit (`make smoke`)
- [scans/](scans/) — Trivy + Grype reports (baseline and fixed)
- [vex/](vex/) — OpenVEX attestation declaring CVE-2026-42945 as `fixed` (so scanners drop it from the fixed scan)
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

Prereqs are listed in [Requirements](#requirements). All commands run from the repo root.

### First run — do these three, in order:

```bash
make setup       # ① one-time:  creates .venv and installs pytest (for `make test`)
make baseline    # ② one-time:  pulls nginx:1.25-bookworm, captures reference
                 #              data under baseline/ + scans/baseline-*.{txt,json}
make all         # ③ build → image → test  (the actual deliverable loop)
```

That's the whole happy path. Steps ① and ② only need to run once per clone — after that, `make all` (or any of its sub-targets) is enough.

### Individual targets

| Target | What |
|---|---|
| `make build` | Compiles nginx 1.25.5 from source on `debian:bookworm-slim`, applies `build/patches/*`, produces `build/out/nginx_1.25.5-paul1_<arch>.deb` |
| `make image` | Installs that `.deb` + the `nginx-module-*` packages onto a fresh `debian:bookworm-slim`, tags as `echo-nginx:local` |
| `make smoke` | Boots ours alongside upstream, diffs 12 axes (filesystem layout, manifest, config files) — informational audit |
| `make test` | pytest HTTP compatibility test against upstream + ours (non-zero exit on any mismatch — the assignment's deliverable) |
| `make scan` | Re-scans the built image with Trivy + Grype; prints how many CVEs the rebuild resolved vs baseline |
| `make all` | `build → image → test` |
| `make clean` | Removes generated artifacts: `build/out/`, `baseline/`, `scans/{baseline,fixed}-*`, pytest caches, and the `echo-nginx:local` image. Leaves `.venv` intact |

**Tunables** (override via env or `make VAR=value`):

| Variable | Default | What |
|---|---|---|
| `NGINX_VERSION` | `1.25.5` | upstream nginx source version to fetch from `nginx.org/download/` |
| `DEB_REVISION` | `paul1` | revision suffix on our `.deb` (e.g. `1.25.5-paul1`) |
| `BUILDER_IMAGE` | `debian:bookworm-slim` | base image for the build sandbox |
| `IMAGE` | `echo-nginx:local` | tag for the final container image |
| `UPSTREAM` | `nginx:1.25-bookworm` | reference image for baseline + tests |
| `PYTHON` | auto-detects `.venv/bin/python`, else `python3` | python interpreter used by `make test` |

## Image size

| | Size |
|---|---|
| `nginx:1.25-bookworm` (upstream) | 278MB |
| this image | 273MB |

We're ~5MB under, mostly because upstream ships `nginx-debug` (a second nginx binary built with `--with-debug`) and we don't — see [Residual risk](#residual-risk). The 4 nginx-module-* packages (`xslt`, `geoip`, `image-filter`, `njs`) and their transitive deps (`libicu72`, `libgd3`, `libgeoip1`, `libxslt1.1`, …) ARE installed in our image to match upstream's filesystem layout.

The remaining sub-MB delta is bookworm point-release drift (e.g. `libssl3` `3.0.11` → `3.0.20`, `libc6` `+deb12u7` → `+deb12u13`, dozens of other tiny bumps) — pinned exact parity would require `snapshot.debian.org`.

## Triage

I found out that the scans are different because the scanners work differently. The version-bump candidates are the dependencies - ideally the higher-risk and broader-chance ones (`libssl3`). Many of those were natively fixed by simply using a more updated bookworm image as a base image, so those were the update candidates, like **CVE-2024-6119**. In fact **122 CVEs from the baseline scan dropped out of our fixed scan** purely from the bookworm point-release drift (`make scan` prints the full diff) - many of them high-severity (`CVE-2024-5535` Critical in libssl3, `CVE-2023-50387` in libsystemd0, `CVE-2024-37371` Critical in libkrb5, etc.).

One specific CVE caught my attention: **CVE-2026-42945**. It's very recent, appears in nginx itself in one of the scans (Grype only). It was marked as "won't fix", and after a little research it won't be fixed specifically in bookworm. The fix does exist upstream at [`nginx/nginx@524977e7c5`](https://github.com/nginx/nginx/commit/524977e7c534e87e5b55739fa74601c9f1102686), and I wanted to append it to the older version since it's one line.

## CVEs fixed

| CVE | Severity | Component | Fix method | Evidence |
|---|---|---|---|---|
| [CVE-2024-6119](https://security-tracker.debian.org/tracker/CVE-2024-6119) | High | `libssl3` (OpenSSL X.509 name-check DoS) | **dependency version bump** — `libssl3 3.0.11 → 3.0.20` via newer bookworm base | both scanners drop it from the fixed scan; counted in [`make scan`](#build-instructions)'s summary |
| [CVE-2026-42945](https://github.com/nginx/nginx/commit/524977e7c534e87e5b55739fa74601c9f1102686) | Critical | `nginx` (Rift — rewrite-engine double-free on `+`-heavy URI paths) | **backport patch** — [`build/patches/CVE-2026-42945.patch`](build/patches/CVE-2026-42945.patch), lifted from upstream commit [`524977e7c5`](https://github.com/nginx/nginx/commit/524977e7c534e87e5b55739fa74601c9f1102686) | `test_cve_2026_42945_rift_no_crash` in [test/compat_test.py](test/compat_test.py) asserts upstream crashes and ours doesn't on the 200-`+` payload. Scanner-side: declared `fixed` in [vex/echo-nginx.openvex.json](vex/echo-nginx.openvex.json), so Grype drops it via `--vex` (Trivy never flagged it in baseline, so VEX is moot there) |
| (+121 others) | mixed (incl. Critical `CVE-2024-5535` in `libssl3`, `CVE-2024-37371` in `libkrb5`, High `CVE-2023-50387` in `libsystemd0`, etc.) | various bookworm packages | dependency version bump (automatic via newer bookworm point releases) | [`make scan`](#build-instructions) reports **122 CVEs resolved via bookworm drift** (per both Grype and Trivy); diff `scans/baseline-grype.txt` vs `scans/fixed-grype.txt` for the full list |

## Residual risk

- **No GPG signature verification on the `nginx.org` apt repo**: our `Containerfile` uses `[trusted=yes]` in the apt source line, where upstream's image build does the full key-fetch dance (`gpg1 --recv-keys … && gpg1 --export … > /usr/share/keyrings/nginx-archive-keyring.gpg`, then `[signed-by=…]`). We skipped it because nginx.org's signing key rotated between the 1.25.5 release and now, so the single key pinned in the 1.25.5 Dockerfile template no longer matches the current `InRelease` signature, and rebuilding without changes failed verification. In production we'd fetch the current key (`8540A6F18833A80E9C1653A42FD21310B49F6B46` at time of writing) and pin it via `signed-by=`. A MITM with control over the build network during `make image` could otherwise swap the `nginx-module-*` packages we install.
- **The 4 `nginx-module-*` packages are nginx.org's prebuilt binaries**, not source-built by us. We install `nginx-module-{xslt,geoip,image-filter,njs}` via apt to match upstream's filesystem layout. CVEs in those modules can't be patched by our pipeline — we'd be waiting on nginx.org to publish fixed module .debs at the matching version pin (`1.25.5-1~bookworm`), which they're unlikely to do since 1.25 is no longer their mainline. They also drag in ~100MB of transitive deps (`libicu72`, `libgd3`, …) — extra attack surface.
- **Source tarball not verified**: `build/build.sh` downloads `nginx-${NGINX_VERSION}.tar.gz` over HTTPS without pinning a SHA256 or verifying nginx.org's detached GPG signature (`.tar.gz.asc`). TLS catches passive MITM, but doesn't help against a compromised CDN edge. There's a `TODO` in the script. Upstream's image build sidesteps this because they install the .deb (which is GPG-signed via the apt repo) rather than downloading source.
- **Nginx CVEs that Grype still flags against our build**: even after the CVE-2026-42945 backport, Grype keeps several flagged against the `nginx 1.25.5` package because the version string didn't change: CVE-2023-44487 (HTTP/2 Rapid Reset — high EPSS, broadly exploited), CVE-2026-27651, CVE-2026-27654, CVE-2026-32647, and a handful of CVE-2026-* mediums. We attach an OpenVEX attestation ([vex/echo-nginx.openvex.json](vex/echo-nginx.openvex.json)) that declares **CVE-2026-42945** as `fixed` — VEX-aware scanners (`trivy --vex`, `grype --vex`, both wired in [`make scan`](#build-instructions)) drop it from the report. The remaining unpatched nginx CVEs (CVE-2023-44487 et al.) stay `affected` until either backported or honestly analyzed per-CVE for a `not_affected` justification.

## Notes

**What AI tooling was used for, and where it helped / hurt:**

I used claude code & claude app. I initially uploaded the assignment requirements, and began researching the entire topic as I didn't have prior knowledge of CVE, patches, backports, etc.

Before implementing this repo, I made a POC excluding the entire pipeline created here. My main goal was to find a CVE that is demonstratable, because most of them are niche and hard to reproduce. Using the help of Claude, I found CVE-2026-42945 (after feeding both scan results). The description was actually fitting my agenda and looked like the reproduction would be easy.

Though the scan didn't show the fix is available, after a little of research to simply replicate I found out it was actually a 1 line fix, that was simple "will not fix" in bookworm. Claude definitely helped me to reach to this CVE.

Furthermore, some of the test plans, beautification, todo and verification was done with the help of Claude (under my supervision of course).

Claude was not fully aware of the repo's structure, and the fact there are many repos that relate to each other, and actually pointed me to the newest templates instead of the specific version tag - which got me very confused due to large difference in image sizes.

**Surprises / insights:**

- nginx is generous and gives us the -V command, giving the exact configuration it was built with. Other packages might have a different command, or none - and then you would actually need to reverse engineer using `--version`/`dpkg -s` + `debian/rules` from the source package + `ldd` on the binary.
- `nginx:1.25-bookworm` is a floating tag, and currently tied to version 1.25.5 of nginx. In production we should pin the digest key to make sure no breaks occur on updated tags.
- I lost time looking at `nginx/docker-nginx` at the latest commit (`c90491de`) instead of at the `1.25.5` tag that actually built our image. The latest-commit template had drift — 3 GPG keys vs 1, a newer `15-local-resolvers.envsh` with extra whitespace-trim lines, a subtle regex change in `10-listen-on-ipv6-by-default.sh` — none of which is in the upstream image. The right anchor for reproducing an image is the tag that matches the image's release.
- Our nginx binary was 8.45 MB until I added `strip` to `build.sh` — nginx source's `--with-cc-opt='-g …'` keeps debug symbols, and nginx.org's `debian/rules` strips before packaging (their shipped binary is 1.56 MB). Without `strip`, our image was ~286 MB and I was guessing at the cause; with it, the delta resolved to ~5 MB (mostly `nginx-debug` we don't ship). Always strip shipped binaries.
- Many CVEs are stale and irrelevant because they are in very niche use cases. Under basic usage, the chance of encountering them is very rare. Either way, they need to be patched/fixed :)
- `debian:bookworm` isn't tagged to a specific version, so simply rebuilding it solved MANY CVEs.

This is definitely the most teaching home assignment I got till now, and there's still so much to learn! During the implementation I was wondering how you solve the triage issues (with AI? or in some other way?), and the fact that each package differs and requires so much attention is very surprising. Here it was rather comfortable (and still time consuming) but I had the dockerfile template, config I could take, etc. Other libraries might not have it (or will have it in other way of access). Curious to understand how you solve this at Echo.

Thanks!
