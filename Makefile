.PHONY: all baseline build image test scan clean

IMAGE        ?= echo-nginx:local
UPSTREAM     ?= nginx:1.25-bookworm

all: build image test

# Pull upstream and capture baseline Trivy + Grype reports into scans/.
baseline:
	@echo "TODO: docker pull $(UPSTREAM); trivy/grype -> scans/baseline-*.txt"

# Build the nginx .deb from upstream source on debian:bookworm-slim.
build:
	@echo "TODO: invoke build/ pipeline -> build/out/*.deb"

# Install the .deb into a minimal base and produce the final image.
image:
	@echo "TODO: docker build -f Containerfile -t $(IMAGE) ."

# Run the HTTP compatibility test against upstream + our image.
test:
	@echo "TODO: run test/ harness against $(UPSTREAM) and $(IMAGE)"

# Re-scan the built image and diff against baseline.
scan:
	@echo "TODO: trivy/grype $(IMAGE) -> scans/fixed-*.txt; diff vs baseline"

clean:
	@echo "TODO: remove build/out, built images, scan artifacts"
