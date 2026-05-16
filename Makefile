.PHONY: all setup baseline build image smoke test scan clean

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

# Drop-in parity audit: boots our image, runs HTTP + filesystem + manifest
# checks against the upstream baseline. Informational (prints diffs).
smoke:
	IMAGE=$(IMAGE) UPSTREAM=$(UPSTREAM) bash test/smoke.sh

# Auto-use the project venv at .venv/ when present; otherwise system python3.
PYTHON ?= $(if $(wildcard .venv/bin/python),.venv/bin/python,python3)

# Run the HTTP compatibility test against upstream + our image.
# Requires `pytest` — install via `make setup` (creates .venv with pytest).
test:
	IMAGE=$(IMAGE) UPSTREAM=$(UPSTREAM) $(PYTHON) -m pytest test/compat_test.py -v

# One-shot Python env setup: create .venv and install pytest.
setup:
	python3 -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install -r requirements.txt
	@echo "==> .venv ready. To use it directly: source .venv/bin/activate"

# Re-scan the built image and diff against the captured baseline.
# Expects `make baseline` to have run first (so scans/baseline-*.{txt,json} exist).
scan:
	mkdir -p scans
	trivy image $(IMAGE) > scans/fixed-trivy.txt
	trivy image --format json $(IMAGE) > scans/fixed-trivy.json
	grype $(IMAGE) > scans/fixed-grype.txt
	grype $(IMAGE) -o json > scans/fixed-grype.json
	@echo
	@echo "==> CVEs in baseline but NOT in fixed (resolved by our build):"
	@set -e; \
	grep -hoE 'CVE-[0-9]+-[0-9]+' scans/baseline-grype.txt | sort -u > scans/.cve_baseline.tmp; \
	grep -hoE 'CVE-[0-9]+-[0-9]+' scans/fixed-grype.txt    | sort -u > scans/.cve_fixed.tmp; \
	comm -23 scans/.cve_baseline.tmp scans/.cve_fixed.tmp | sed 's/^/    /'; \
	rm -f scans/.cve_baseline.tmp scans/.cve_fixed.tmp

clean:
	@echo "TODO: remove build/out, built images, scan artifacts"
