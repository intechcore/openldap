.PHONY: build test lint scan clean bump-openldap

# renovate: openldap
OPENLDAP_VERSION ?= 2.6.13
IMAGE_NAME       ?= openldap
IMAGE_TAG        ?= $(OPENLDAP_VERSION)

build:
	docker build \
		--build-arg OPENLDAP_VERSION=$(OPENLDAP_VERSION) \
		-t $(IMAGE_NAME):$(IMAGE_TAG) .

test: build
	./tests/integration/test-integration.sh $(IMAGE_NAME):$(IMAGE_TAG)

lint:
	shellcheck entrypoint.sh tests/integration/*.sh
	docker run --rm -i hadolint/hadolint < Dockerfile

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasecurity/trivy image --severity CRITICAL,HIGH --ignore-unfixed $(IMAGE_NAME):$(IMAGE_TAG)

clean:
	docker rmi $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true

# Bump the pinned OpenLDAP version and refresh the tarball checksum.
# Usage: make bump-openldap V=2.6.14
bump-openldap:
	@test -n "$(V)" || { echo "usage: make bump-openldap V=<version>"; exit 1; }
	@echo "Fetching openldap-$(V).tgz and computing sha256..."
	@SHA=$$(curl -fsSL "https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-$(V).tgz" | sha256sum | awk '{print $$1}') && \
		test -n "$$SHA" && \
		echo "sha256=$$SHA" && \
		sed -i.bak -E "s/^ARG OPENLDAP_VERSION=.*/ARG OPENLDAP_VERSION=$(V)/" Dockerfile && \
		sed -i.bak -E "s/^ARG OPENLDAP_SHA256=.*/ARG OPENLDAP_SHA256=$$SHA/" Dockerfile && \
		sed -i.bak -E "s/^OPENLDAP_VERSION \?= .*/OPENLDAP_VERSION ?= $(V)/" Makefile && \
		rm -f Dockerfile.bak Makefile.bak && \
		echo "Updated Dockerfile + Makefile to OpenLDAP $(V)"
