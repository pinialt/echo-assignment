.PHONY: all baseline build image test scan clean

IMAGE        ?= echo-nginx:local
UPSTREAM     ?= nginx:1.25-bookworm

all: build image test

# Pull upstream and capture baseline Trivy + Grype reports into scans/.
baseline:
	mkdir -p baseline scans
	docker pull $(UPSTREAM)
	docker run --rm $(UPSTREAM) nginx -v 2>&1 | tee baseline/upstream-nginx-v.txt
	docker run --rm $(UPSTREAM) nginx -V 2>&1 | tee baseline/upstream-nginx-V.txt
	docker run --rm $(UPSTREAM) id nginx | tee baseline/upstream-id-nginx.txt
	docker inspect $(UPSTREAM) --format '{{json .Config}}' \
	    | python3 -m json.tool > baseline/upstream-config.json
	trivy image $(UPSTREAM) > scans/baseline-trivy.txt
	trivy image --format json $(UPSTREAM) > scans/baseline-trivy.json
	grype $(UPSTREAM) > scans/baseline-grype.txt
	grype $(UPSTREAM) -o json > scans/baseline-grype.json
	@echo "==> baseline captured: baseline/ + scans/baseline-*.{txt,json}"

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
