# Final image: install the .deb produced by build/ into a minimal Debian base.
# Must match upstream nginx:1.25-bookworm filesystem layout, user, workdir,
# ports, and entrypoint exactly (drop-in replacement, not a re-imagining).
#
# TODO: implement.

FROM debian:bookworm-slim
