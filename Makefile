.PHONY: build test lint scan clean bump-openldap

# renovate: openldap
OPENLDAP_VERSION ?= 2.6.13
# Exact Symas apt package revision installed (pinned). Refresh with
# `make bump-openldap V=<version>`.
SYMAS_VERSION    ?= 2.6.13-3trixie1
IMAGE_NAME       ?= openldap
IMAGE_TAG        ?= $(OPENLDAP_VERSION)

build:
	docker build \
		--build-arg OPENLDAP_VERSION=$(OPENLDAP_VERSION) \
		--build-arg SYMAS_VERSION=$(SYMAS_VERSION) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

test: build
	./tests/integration/test-integration.sh $(IMAGE_NAME):$(IMAGE_TAG)

lint:
	shellcheck entrypoint.sh reload-tls.sh tests/integration/*.sh
	docker run --rm -i hadolint/hadolint < Dockerfile

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasecurity/trivy image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true

# Bump the pinned OpenLDAP version and resolve the matching Symas package
# revision from the LTS repo. Usage: make bump-openldap V=2.6.14
bump-openldap:
	@test -n "$(V)" || { echo "usage: make bump-openldap V=<version>"; exit 1; }
	@echo "Resolving Symas package version for OpenLDAP $(V)..."
	@PKGVER=$$(curl -fsSL "https://repo.symas.com/repo/deb/main/release26/dists/trixie/main/binary-amd64/Packages" \
		| awk '/^Package: symas-openldap-server$$/{f=1} f&&/^Version:/{print $$2; exit}') && \
		test -n "$$PKGVER" && \
		case "$$PKGVER" in "$(V)"*) ;; *) echo "ERROR: latest Symas package '$$PKGVER' does not match $(V)"; exit 1;; esac && \
		echo "Symas package version: $$PKGVER" && \
		sed -i.bak -E "s/^ARG OPENLDAP_VERSION=.*/ARG OPENLDAP_VERSION=$(V)/" Dockerfile && \
		sed -i.bak -E "s/^ARG SYMAS_VERSION=.*/ARG SYMAS_VERSION=$$PKGVER/" Dockerfile && \
		sed -i.bak -E "s/^OPENLDAP_VERSION \?= .*/OPENLDAP_VERSION ?= $(V)/" Makefile && \
		sed -i.bak -E "s/^SYMAS_VERSION    \?= .*/SYMAS_VERSION    ?= $$PKGVER/" Makefile && \
		rm -f Dockerfile.bak Makefile.bak && \
		echo "Updated Dockerfile + Makefile to OpenLDAP $(V) (Symas $$PKGVER)"
