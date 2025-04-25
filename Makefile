# Copyright 2017 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Add the following 'help' target to your Makefile
# And add help text after each target name starting with '\#\#'

# set default shell
SHELL ?= /bin/bash -o pipefail -o errexit

# These may be overridden to change the release output from pushing to a registry to (for example) local tarballs.
RELEASE_OUTPUT ?= type=registry
RELEASE_OUTPUT_CONTROLLER ?= $(RELEASE_OUTPUT)
RELEASE_OUTPUT_CONTROLLER_CHROOT ?= $(RELEASE_OUTPUT)

# These may be overridden to change or filter, e.g. platforms built on release.
PLATFORMS ?= linux/amd64 linux/arm linux/arm64
PLATFORM ?= $(OS)/$(ARCH)
PLATFORMS_FLAG ?= $(and $(PLATFORMS),--platform=$(subst $(SPACE),$(COMMA),$(PLATFORMS)))
PLATFORM_FLAG ?= $(and $(PLATFORM),--platform=$(PLATFORM))

# N.B. not currently used anywhere except the unused `builder` target
BUILDER ?= ingress-nginx

# This functions as an override for the shell snippet to run the build. Set to empty builds the binaries locally.
BUILD_RUNNER ?= E2E_IMAGE=golang:$(GO_VERSION)-alpine3.21 USE_SHELL=/bin/sh build/run-in-docker.sh

# e2e settings
# Allow limiting the scope of the e2e tests. By default run everything
export FOCUS ?=
# number of parallel test
export E2E_NODES ?= 7
# run e2e test suite with tests that check for memory leaks? (default is false)
export E2E_CHECK_LEAKS ?=

export REPO_INFO ?= $(shell git config --get remote.origin.url)
export COMMIT_SHA ?= git-$(shell git rev-parse --short HEAD)
export BUILD_ID ?= "UNSET"
export PKG ?= k8s.io/ingress-nginx
export REGISTRY ?= us-central1-docker.pkg.dev/k8s-staging-images/ingress-nginx

EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
COMMA := ,
export ARCH := $(or $(ARCH),$(shell which go >/dev/null 2>&1 && go env GOARCH),$(error mandatory variable ARCH is empty, either set it when calling the command or make sure 'go env GOARCH' works))
export OS := $(or $(OS),$(shell which go >/dev/null 2>&1 && go env GOOS),linux)
export GOOS = $(OS)
export GOARCH = $(ARCH)
# Use the 0.0 tag for testing, it shouldn't clobber any release builds
export TAG := $(or $(TAG),$(shell cat TAG 2>/dev/null || true),0.0)
export BASE_IMAGE := $(or $(BASE_IMAGE),$(shell cat NGINX_BASE))
# The env below is called GO_VERSION and not GOLANG_VERSION because
# the gcb image we use to build already defines GOLANG_VERSION and is a
# really old version
export GO_VERSION := $(or $(GO_VERSION),$(shell cat GOLANG_VERSION))

.PHONY: help
help:  ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  $(or $(notdir $(MAKE)),make) \033[36m<target>\033[0m\n"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: h
h: help ## Alias for help.

.PHONY: image
image: clean-image ## Build image for a particular arch.
	echo "Building docker image ($(ARCH))..."
	docker build \
		$(PLATFORM_FLAG) \
		--no-cache \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg VERSION=$(TAG) \
		--build-arg TARGETARCH="$(ARCH)" \
		--build-arg COMMIT_SHA="$(COMMIT_SHA)" \
		--build-arg BUILD_ID="$(BUILD_ID)" \
		-t $(REGISTRY)/controller:$(TAG) rootfs

.PHONY: gosec
gosec:
	docker run --rm -it -w /source/ -v "$(pwd)"/:/source securego/gosec:2.11.0 -exclude=G109,G601,G104,G204,G304,G306,G307 -tests=false -exclude-dir=test -exclude-dir=images/  -exclude-dir=docs/ /source/...

.PHONY: image-chroot
image-chroot: clean-chroot-image ## Build image for a particular arch.
	echo "Building docker image ($(ARCH))..."
	docker build \
		--no-cache \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg VERSION=$(TAG) \
		--build-arg TARGETARCH="$(ARCH)" \
		--build-arg COMMIT_SHA="$(COMMIT_SHA)" \
		--build-arg BUILD_ID="$(BUILD_ID)" \
		-t $(REGISTRY)/controller-chroot:$(TAG) rootfs -f rootfs/Dockerfile-chroot

.PHONY: clean-image
clean-image: ## Removes local image
	echo "removing old image $(REGISTRY)/controller:$(TAG)"
	@docker rmi -f $(REGISTRY)/controller:$(TAG) || true

.PHONY: clean-chroot-image
clean-chroot-image: ## Removes local image
	echo "removing old image $(REGISTRY)/controller-chroot:$(TAG)"
	@docker rmi -f $(REGISTRY)/controller-chroot:$(TAG) || true

.PHONY: build
build:  ## Build ingress controller, debug tool and pre-stop hook.
	$(BUILD_RUNNER) \
		MAC_OS=$(MAC_OS) \
		PKG=$(PKG) \
		ARCH=$(ARCH) \
		OS=$(OS) \
		COMMIT_SHA=$(COMMIT_SHA) \
		REPO_INFO=$(REPO_INFO) \
		TAG=$(TAG) \
		build/build.sh

.PHONY: clean
clean: ## Remove .gocache directory.
	rm -rf bin/ .gocache/ .cache/

.PHONY: verify-docs
verify-docs: ## Verify doc generation
	hack/verify-annotation-docs.sh

.PHONY: static-check
static-check: ## Run verification script for boilerplate, codegen, gofmt, golint, lualint and chart-lint.
	@build/run-in-docker.sh \
	    MAC_OS=$(MAC_OS) \
		hack/verify-all.sh

.PHONY: golint-check
golint-check:
	@build/run-in-docker.sh \
	    MAC_OS=$(MAC_OS) \
		hack/verify-golint.sh

###############################
# Tests for ingress-nginx
###############################

.PHONY: test
test:  ## Run go unit tests.
	@build/run-in-docker.sh \
		PKG=$(PKG) \
		MAC_OS=$(MAC_OS) \
		ARCH=$(ARCH) \
		COMMIT_SHA=$(COMMIT_SHA) \
		REPO_INFO=$(REPO_INFO) \
		TAG=$(TAG) \
		GOFLAGS="-buildvcs=false" \
		test/test.sh

.PHONY: lua-test
lua-test: ## Run lua unit tests.
	@build/run-in-docker.sh \
		MAC_OS=$(MAC_OS) \
		test/test-lua.sh

.PHONY: e2e-test
e2e-test:  ## Run e2e tests (expects access to a working Kubernetes cluster).
	@test/e2e/run-e2e-suite.sh

.PHONY: kind-e2e-test
kind-e2e-test:  ## Run e2e tests using kind.
	@test/e2e/run-kind-e2e.sh

.PHONY: kind-e2e-chart-tests
kind-e2e-chart-tests: ## Run helm chart e2e tests
	@test/e2e/run-chart-test.sh

.PHONY: e2e-test-binary
e2e-test-binary:  ## Build binary for e2e tests.
	@build/run-in-docker.sh \
		MAC_OS=$(MAC_OS) \
		ginkgo build ./test/e2e

.PHONY: print-e2e-suite
print-e2e-suite: e2e-test-binary ## Prints information about the suite of e2e tests.
	@build/run-in-docker.sh \
		MAC_OS=$(MAC_OS) \
		hack/print-e2e-suite.sh

.PHONY: vet
vet:
	@go vet $(shell go list $(PKG)/internal/... | grep -v vendor)

.PHONY: check_dead_links
check_dead_links: ## Check if the documentation contains dead links.
	@docker run $(PLATFORM_FLAG) -t \
	  -w /tmp \
	  -v "$$PWD":/tmp dkhamsing/awesome_bot:1.20.0 \
	  --allow-dupe \
	  --allow-redirect $(shell find "$$PWD" -mindepth 1 -name vendor -prune -o -name .modcache -prune -o -iname Changelog.md -prune -o -name "*.md" | sed -e "s#$$PWD/##")

.PHONY: dev-env
dev-env:  ## Starts a local Kubernetes cluster using kind, building and deploying the ingress controller.
	@build/dev-env.sh

.PHONY: dev-env-stop
dev-env-stop: ## Deletes local Kubernetes cluster created by kind.
	@kind delete cluster --name ingress-nginx-dev

.PHONY: live-docs
live-docs: ## Build and launch a local copy of the documentation website in http://localhost:8000
	@docker build $(PLATFORM_FLAG) \
                  		--no-cache \
                  		 -t ingress-nginx-docs .github/actions/mkdocs
	@docker run $(PLATFORM_FLAG) --rm -it \
		-p 8000:8000 \
		-v "$$PWD":/docs \
		--entrypoint /bin/bash   \
		ingress-nginx-docs \
		-c "pip install -r /docs/docs/requirements.txt && mkdocs serve --dev-addr=0.0.0.0:8000"

.PHONY: misspell
misspell:  ## Check for spelling errors.
	@go install github.com/client9/misspell/cmd/misspell@latest
	misspell \
		-locale US \
		-error \
		cmd/* internal/* deploy/* docs/* design/* test/* README.md

.PHONY: run-ingress-controller
run-ingress-controller: ## Run the ingress controller locally using a kubectl proxy connection.
	@build/run-ingress-controller.sh

.PHONY: builder
builder:
	docker buildx create --name $(BUILDER) --bootstrap --use || :
	docker buildx inspect $(BUILDER)

.PHONY: show-version
show-version: ## Show the current version.
	@echo $(TAG)

.PHONY: show-platform
show-platform: ## Show the system platform.
	@echo $(PLATFORM)

.PHONY: show-platforms
show-platforms: # Show the release platforms.
	@echo $(PLATFORMS)

# TODO: integrate/merge with the builder target - diverged from upstream
.PHONY: ensure-buildx
ensure-buildx:
	./hack/init-buildx.sh $(PLATFORMS)

.PHONY: release # Build a multi-arch docker image
release: ensure-buildx clean
	@echo "Building binaries..."
	$(foreach PLATFORM,$(PLATFORMS),$(_release_TEMPLATE))
	@echo "Building and pushing ingress-nginx image for platform(s): $(PLATFORMS)"
ifneq ($(RELEASE_OUTPUT_CONTROLLER),)
	docker buildx build \
		--no-cache \
		$(MAC_DOCKER_FLAGS) \
		--output=$(RELEASE_OUTPUT_CONTROLLER) \
		--pull \
		--progress plain \
		$(PLATFORMS_FLAG) \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg VERSION=$(TAG) \
		--build-arg COMMIT_SHA="$(COMMIT_SHA)" \
		--build-arg BUILD_ID="$(BUILD_ID)" \
		-t $(REGISTRY)/controller:$(TAG) rootfs
endif
ifneq ($(RELEASE_OUTPUT_CONTROLLER_CHROOT),)
	docker buildx build \
		--no-cache \
		$(MAC_DOCKER_FLAGS) \
		--output=$(RELEASE_OUTPUT_CONTROLLER_CHROOT) \
		--pull \
		--progress plain \
		$(PLATFORMS_FLAG) \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg VERSION=$(TAG) \
		--build-arg COMMIT_SHA="$(COMMIT_SHA)" \
		--build-arg BUILD_ID="$(BUILD_ID)" \
		-t $(REGISTRY)/controller-chroot:$(TAG) rootfs -f rootfs/Dockerfile-chroot
endif
define _release_TEMPLATE =
OS=$(word 1,$(subst /,$(SPACE),$(PLATFORM))) \
ARCH=$(word 2,$(subst /,$(SPACE),$(PLATFORM))) \
	$(MAKE) build

endef

.PHONY: build-docs
build-docs:
	pip install -r docs/requirements.txt
	mkdocs build --config-file mkdocs.yml
