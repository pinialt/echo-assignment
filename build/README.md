# build/

Produces the nginx `.deb` from upstream source on a clean
`debian:bookworm-slim` base. No pre-baked binaries.

Steps the build script must perform:

1. Fetch upstream source for the target nginx version.
2. Apply patches: version bump(s) for dependencies + backport(s) from
   [patches/](patches/).
3. Build the `.deb` and place it under `build/out/`.

Entry point: `make build` from the repo root.
