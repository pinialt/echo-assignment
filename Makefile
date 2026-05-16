.PHONY: all baseline build image test scan clean

IMAGE          ?= echo-nginx:local
UPSTREAM       ?= nginx:1.25-bookworm
NGINX_VERSION  ?= 1.25.5
DEB_REVISION   ?= paul1
BUILDER_IMAGE  ?= debian:bookworm-slim

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
	docker images $(UPSTREAM) --format '{{.Size}}' | tee baseline/upstream-size.txt
	trivy image $(UPSTREAM) > scans/baseline-trivy.txt
	trivy image --format json $(UPSTREAM) > scans/baseline-trivy.json
	grype $(UPSTREAM) > scans/baseline-grype.txt
	grype $(UPSTREAM) -o json > scans/baseline-grype.json
	@echo "==> baseline captured: baseline/ + scans/baseline-*.{txt,json}"

# Build the nginx .deb from upstream source on a clean debian:bookworm-slim.
# The container is only a sandbox; the actual build is build/build.sh.
build:
	mkdir -p build/out
	docker run --rm \
	    -v $(PWD)/build:/build:ro \
	    -v $(PWD)/build/out:/out \
	    -e NGINX_VERSION=$(NGINX_VERSION) \
	    -e DEB_REVISION=$(DEB_REVISION) \
	    $(BUILDER_IMAGE) \
	    bash /build/build.sh
	@echo "==> built: build/out/nginx_$(NGINX_VERSION)-$(DEB_REVISION)_amd64.deb"

# Install the .deb into a minimal base and produce the final image.
# Expects build/out/*.deb to exist (run `make build` first).
image:
	@ls build/out/*.deb >/dev/null 2>&1 || { echo "No .deb in build/out/. Run 'make build' first." >&2; exit 1; }
	docker build -f Containerfile -t $(IMAGE) .
	@echo "==> built: $(IMAGE)"

# Run the HTTP compatibility test against upstream + our image.
test:
	@echo "TODO: run test/ harness against $(UPSTREAM) and $(IMAGE)"

# Re-scan the built image and diff against baseline.
scan:
	@echo "TODO: trivy/grype $(IMAGE) -> scans/fixed-*.txt; diff vs baseline"

clean:
	@echo "TODO: remove build/out, built images, scan artifacts"
