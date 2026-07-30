# Image URL to use all building/pushing image targets
IMG ?= quay.io/konveyor/agentic-controller:latest
# YEAR defines the year value used for substituting the YEAR placeholder in the boilerplate header.
YEAR ?= $(shell date +%Y)

# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# CONTAINER_TOOL defines the container tool to be used for building images.
# Auto-detected, podman first, matching what the hack/ scripts have always done.
# Previously hardcoded to docker, which made every image target fail outright on
# a podman-only machine even though the scripts handled it correctly.
CONTAINER_TOOL ?= $(shell command -v podman >/dev/null 2>&1 && echo podman || echo docker)

# Setting SHELL to bash allows bash commands to be executed by recipes.
# Options are set to exit when a recipe line exits non-zero or a piped command fails.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

.PHONY: all
all: build

##@ General

# The help target prints out all targets with their descriptions organized
# beneath their categories. The categories are represented by '##@' and the
# target descriptions by '##'. The awk command is responsible for reading the
# entire set of makefiles included in this invocation, looking for lines of the
# file as xyz: ## something, and then pretty-format the target and help. Then,
# if there's a line with ##@ something, that gets pretty-printed as a category.
# More info on the usage of ANSI control characters for terminal formatting:
# https://en.wikipedia.org/wiki/ANSI_escape_code#SGR_parameters
# More info on the awk command:
# http://linuxcommand.org/lc3_adv_awk.php

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

##@ Development

.PHONY: manifests
manifests: controller-gen ## Generate WebhookConfiguration, ClusterRole and CustomResourceDefinition objects.
	"$(CONTROLLER_GEN)" rbac:roleName=manager-role crd webhook paths="./..." output:crd:artifacts:config=config/crd/bases

.PHONY: generate
generate: controller-gen ## Generate code containing DeepCopy, DeepCopyInto, and DeepCopyObject method implementations.
	"$(CONTROLLER_GEN)" object:headerFile="hack/boilerplate.go.txt",year=$(YEAR) paths="./..."

.PHONY: fmt
fmt: ## Run go fmt against code.
	go fmt ./...

.PHONY: vet
vet: ## Run go vet against code.
	go vet ./...

.PHONY: test
test: manifests generate fmt vet setup-envtest ## Run tests.
	KUBEBUILDER_ASSETS="$(shell "$(ENVTEST)" use $(ENVTEST_K8S_VERSION) --bin-dir "$(LOCALBIN)" -p path)" go test $$(go list ./... | grep -v /e2e) -coverprofile cover.out

KIND_CLUSTER ?= agentic-controller-e2e

.PHONY: e2e-setup
e2e-setup: ## Create a Kind cluster with Agent Sandbox and deploy the controller.
	hack/start-kind.sh
	hack/setup-e2e.sh

.PHONY: harness-test
harness-test: ## Build, load, and deploy the harness agent in Kind (requires e2e-setup).
	hack/harness-test/setup.sh

.PHONY: e2e-run
e2e-run: ## Run the e2e test (cluster must be set up with e2e-setup).
	hack/run-e2e.sh

.PHONY: e2e
e2e: e2e-setup e2e-run ## Full e2e: create cluster, deploy, test.

.PHONY: e2e-cleanup
e2e-cleanup: ## Tear down the Kind cluster used for e2e tests.
	kind delete cluster --name $(KIND_CLUSTER)

.PHONY: lint
lint: golangci-lint ## Run golangci-lint linter
	"$(GOLANGCI_LINT)" run

.PHONY: lint-fix
lint-fix: golangci-lint ## Run golangci-lint linter and perform fixes
	"$(GOLANGCI_LINT)" run --fix

.PHONY: lint-config
lint-config: golangci-lint ## Verify golangci-lint linter configuration
	"$(GOLANGCI_LINT)" config verify

##@ Build

CONTROLLER_AGENT_IMG ?= quay.io/konveyor/agentic-controller-agent:latest
AGENT_JAVA_GOOSE_IMG ?= quay.io/konveyor/agent-base-goose-java:latest

.PHONY: build
build: manifests generate fmt vet ## Build manager binary.
	go build -o bin/manager cmd/main.go

.PHONY: controller-agent-build
controller-agent-build: ## Build the controller's test/verification agent image.
	$(CONTAINER_TOOL) build -t $(CONTROLLER_AGENT_IMG) -f images/agentic-controller-agent/Containerfile images/agentic-controller-agent/

.PHONY: controller-agent-push
controller-agent-push: controller-agent-build ## Build and push the controller's test/verification agent image.
	$(CONTAINER_TOOL) push $(CONTROLLER_AGENT_IMG)

.PHONY: agent-java-goose-build
agent-java-goose-build: ## Build the Java migration agent image (Goose + JDK 21 + harness).
	$(CONTAINER_TOOL) build -t $(AGENT_JAVA_GOOSE_IMG) -f images/agent-base-goose-java/Containerfile .

.PHONY: agent-java-goose-push
agent-java-goose-push: agent-java-goose-build ## Build and push the Java migration agent image.
	$(CONTAINER_TOOL) push $(AGENT_JAVA_GOOSE_IMG)

.PHONY: run
run: manifests generate fmt vet ## Run a controller from your host.
	go run ./cmd/main.go

# If you wish to build the manager image targeting other platforms you can use the --platform flag.
# (i.e. docker build --platform linux/arm64). However, you must enable docker buildKit for it.
# More info: https://docs.docker.com/develop/develop-images/build_enhancements/
.PHONY: docker-build
docker-build: ## Build docker image with the manager.
	$(CONTAINER_TOOL) build -t ${IMG} .

.PHONY: docker-push
docker-push: ## Push docker image with the manager.
	$(CONTAINER_TOOL) push ${IMG}

# PLATFORMS defines the target platforms for the manager image be built to provide support to multiple
# architectures. (i.e. make docker-buildx IMG=myregistry/mypoperator:0.0.1). To use this option you need to:
# - be able to use docker buildx. More info: https://docs.docker.com/build/buildx/
# - have enabled BuildKit. More info: https://docs.docker.com/develop/develop-images/build_enhancements/
# - be able to push the image to your registry (i.e. if you do not set a valid value via IMG=<myregistry/image:<tag>> then the export will fail)
# To adequately provide solutions that are compatible with multiple platforms, you should consider using this option.
PLATFORMS ?= linux/arm64,linux/amd64,linux/s390x,linux/ppc64le
.PHONY: docker-buildx
docker-buildx: ## Build and push docker image for the manager for cross-platform support
	# copy existing Dockerfile and insert --platform=${BUILDPLATFORM} into Dockerfile.cross, and preserve the original Dockerfile
	sed -e '1 s/\(^FROM\)/FROM --platform=\$$\{BUILDPLATFORM\}/; t' -e ' 1,// s//FROM --platform=\$$\{BUILDPLATFORM\}/' Dockerfile > Dockerfile.cross
	- $(CONTAINER_TOOL) buildx create --name agentic-controller-builder
	$(CONTAINER_TOOL) buildx use agentic-controller-builder
	- $(CONTAINER_TOOL) buildx build --push --platform=$(PLATFORMS) --tag ${IMG} -f Dockerfile.cross .
	- $(CONTAINER_TOOL) buildx rm agentic-controller-builder
	rm Dockerfile.cross

.PHONY: build-installer
build-installer: manifests generate kustomize ## Generate a consolidated YAML with CRDs and deployment.
	mkdir -p dist
	cd config/manager && "$(KUSTOMIZE)" edit set image controller=${IMG}
	"$(KUSTOMIZE)" build config/default > dist/install.yaml

##@ Deployment

ifndef ignore-not-found
  ignore-not-found = false
endif

.PHONY: install
install: manifests kustomize ## Install CRDs into the K8s cluster specified in ~/.kube/config.
	@out="$$( "$(KUSTOMIZE)" build config/crd 2>/dev/null || true )"; \
	if [ -n "$$out" ]; then echo "$$out" | "$(KUBECTL)" apply -f -; else echo "No CRDs to install; skipping."; fi

.PHONY: uninstall
uninstall: manifests kustomize ## Uninstall CRDs from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	@out="$$( "$(KUSTOMIZE)" build config/crd 2>/dev/null || true )"; \
	if [ -n "$$out" ]; then echo "$$out" | "$(KUBECTL)" delete --ignore-not-found=$(ignore-not-found) -f -; else echo "No CRDs to delete; skipping."; fi

.PHONY: deploy
deploy: manifests kustomize ## Deploy controller to the K8s cluster specified in ~/.kube/config.
	cd config/manager && "$(KUSTOMIZE)" edit set image controller=${IMG}
	"$(KUSTOMIZE)" build config/default | "$(KUBECTL)" apply -f -

.PHONY: undeploy
undeploy: kustomize ## Undeploy controller from the K8s cluster specified in ~/.kube/config. Call with ignore-not-found=true to ignore resource not found errors during deletion.
	"$(KUSTOMIZE)" build config/default | "$(KUBECTL)" delete --ignore-not-found=$(ignore-not-found) -f -

##@ Local Development

# A local cluster for poking at the controller and the full AgentRun flow.
#
# minikube rather than kind because kind is containerd-only, and CRI-O (what
# OpenShift runs) handles image-volume mounts differently. The kind targets
# above are untouched and remain the CI regression path.
#
# All scripts export a repo-local KUBECONFIG, so none of this touches your
# current kubectl context.
CONTAINER_RUNTIME      ?= cri-o
MINIKUBE_PROFILE       ?= agentic-dev
MINIKUBE_DRIVER        ?= $(CONTAINER_TOOL)
MINIKUBE_K8S_VERSION   ?= v1.34.0
MINIKUBE_CPUS          ?= 4
MINIKUBE_MEMORY        ?= 6144
# ImageVolume is beta (default-on) from k8s 1.33. Set empty to omit the flags,
# which is required once the gate is GA'd and removed.
MINIKUBE_FEATURE_GATES ?= ImageVolume=true
DEV_IMG                ?= quay.io/konveyor/agentic-controller:e2e
DEV_AGENT_IMG          ?= quay.io/konveyor/agentic-controller-agent:e2e
DEV_KUBECONFIG         ?= $(CURDIR)/.dev/$(MINIKUBE_PROFILE).kubeconfig
DEV_RESULTS_DIR        ?= $(CURDIR)/.dev/results
# Extra flags for dev-apply, e.g. DEV_APPLY_ARGS=--emulator to skip the real key.
DEV_APPLY_ARGS         ?=
AGENT_RUN              ?= dev-run

DEV_ENV = CONTAINER_RUNTIME=$(CONTAINER_RUNTIME) \
          CONTAINER_TOOL=$(CONTAINER_TOOL) \
          MINIKUBE_PROFILE=$(MINIKUBE_PROFILE) \
          MINIKUBE_DRIVER=$(MINIKUBE_DRIVER) \
          MINIKUBE_K8S_VERSION=$(MINIKUBE_K8S_VERSION) \
          MINIKUBE_CPUS=$(MINIKUBE_CPUS) \
          MINIKUBE_MEMORY=$(MINIKUBE_MEMORY) \
          MINIKUBE_FEATURE_GATES=$(MINIKUBE_FEATURE_GATES) \
          DEV_IMG=$(DEV_IMG) \
          DEV_AGENT_IMG=$(DEV_AGENT_IMG) \
          DEV_KUBECONFIG=$(DEV_KUBECONFIG) \
          DEV_RESULTS_DIR=$(DEV_RESULTS_DIR) \
          AGENT_RUN=$(AGENT_RUN)

.PHONY: dev-doctor
dev-doctor: ## Preflight the local dev environment (tools, driver, arch, runtime, gate).
	$(DEV_ENV) hack/dev/doctor.sh

.PHONY: dev-cluster
dev-cluster: ## Create/start the local minikube cluster with Agent Sandbox.
	$(DEV_ENV) hack/dev/up.sh

.PHONY: dev-deploy
dev-deploy: ## Install CRDs and deploy the controller into the local cluster.
	$(DEV_ENV) hack/dev/deploy.sh

.PHONY: dev-load
dev-load: ## Rebuild + reload controller and agent images, then restart the controller.
	$(DEV_ENV) hack/dev/load.sh controller
	$(DEV_ENV) hack/dev/load.sh agent
	@# Only restart if the controller is already deployed: dev-load runs both
	@# before the first dev-deploy and for iteration afterwards.
	@if KUBECONFIG=$(DEV_KUBECONFIG) $(KUBECTL) get deployment/agentic-controller-controller-manager \
	      -n agentic-controller-system >/dev/null 2>&1; then \
	  KUBECONFIG=$(DEV_KUBECONFIG) $(KUBECTL) rollout restart \
	    deployment/agentic-controller-controller-manager -n agentic-controller-system ; \
	else \
	  printf 'Controller not deployed yet; skipping rollout restart.\n' ; \
	fi

.PHONY: dev-skills
dev-skills: ## Rebuild and reload the skill images into the local cluster.
	$(DEV_ENV) hack/dev/load.sh skills

.PHONY: dev-apply
dev-apply: ## Apply the dev CRs (needs ANTHROPIC_API_KEY; DEV_APPLY_ARGS=--emulator to skip).
	$(DEV_ENV) hack/dev/apply.sh $(DEV_APPLY_ARGS)

.PHONY: dev-reset
dev-reset: ## Delete and re-apply the dev CRs for a fresh run.
	$(DEV_ENV) hack/dev/apply.sh --reset $(DEV_APPLY_ARGS)

.PHONY: dev-up
dev-up: dev-cluster dev-load dev-skills dev-deploy ## Full local environment: cluster, images, controller.
	@printf '\nEnvironment ready. Next:\n'
	@printf '  eval "$$(make dev-kubeconfig)"   # point your shell at it\n'
	@printf '  make dev-apply                   # create the dev CRs\n'
	@printf '  make dev-probe                   # answer the exec question\n'

.PHONY: dev-hub
dev-hub: ## Deploy Tackle Hub into the local cluster and seed an Application.
	$(DEV_ENV) hack/dev/hub.sh

.PHONY: dev-hub-appid
dev-hub-appid: ## Print the seeded Hub application ID.
	@$(DEV_ENV) hack/dev/hub.sh --app-id

.PHONY: dev-probe
dev-probe: ## Probe whether agents can stage and execute scripts in this cluster.
	$(DEV_ENV) hack/probe/run-probe.sh

.PHONY: dev-status
dev-status: ## Show CRs, Sandboxes, and pods in the local cluster.
	$(DEV_ENV) hack/dev/status.sh

.PHONY: dev-logs
dev-logs: ## Follow controller-manager logs.
	KUBECONFIG=$(DEV_KUBECONFIG) $(KUBECTL) logs -f \
	  -n agentic-controller-system deployment/agentic-controller-controller-manager

.PHONY: dev-agent-logs
dev-agent-logs: ## Follow the sandbox pod logs for AGENT_RUN (default: dev-run).
	$(DEV_ENV) hack/dev/agent.sh logs

.PHONY: dev-shell
dev-shell: ## Open a shell in the sandbox pod for AGENT_RUN (default: dev-run).
	$(DEV_ENV) hack/dev/agent.sh shell

.PHONY: dev-kubeconfig
dev-kubeconfig: ## Print the export line for the local cluster kubeconfig.
	@printf 'export KUBECONFIG=%s\n' "$(DEV_KUBECONFIG)"

.PHONY: dev-stop
dev-stop: ## Stop the local cluster without deleting it.
	minikube stop -p $(MINIKUBE_PROFILE)

.PHONY: dev-down
dev-down: ## Delete the local cluster and its kubeconfig.
	$(DEV_ENV) hack/dev/down.sh

##@ Skills

SKILL_IMAGE ?= quay.io/konveyor/skills
SKILL_DIRS := $(wildcard skills/examples/*/skill.yaml)
SKILL_DIRS := $(dir $(SKILL_DIRS))
SKILLCTL_VERSION ?= v0.7.2

SKILLCTL ?= $(LOCALBIN)/skillctl

.PHONY: skillctl
skillctl: $(SKILLCTL) ## Download skillctl locally if necessary.
$(SKILLCTL): $(LOCALBIN)
	$(call go-install-tool,$(SKILLCTL),github.com/redhat-et/skillimage/cmd/skillctl,$(SKILLCTL_VERSION))

.PHONY: skill-build
skill-build: skillctl ## Build all example skills into the local OCI store.
	@for dir in $(SKILL_DIRS); do \
		echo "Building skill: $${dir}" ;\
		"$(SKILLCTL)" build "$${dir}" ;\
	done

.PHONY: skill-push
skill-push: skill-build ## Build and push all example skills to the registry.
	@for dir in $(SKILL_DIRS); do \
		name=$$(basename "$${dir}") ;\
		local_ref=$$($(SKILLCTL) list | grep -w "$${name}" | head -1 | awk '{print $$1 ":" $$2}') ;\
		if [ -z "$${local_ref}" ]; then echo "ERROR: skill '$${name}' not found in local store" >&2; exit 1; fi ;\
		echo "Tagging $${local_ref} -> $(SKILL_IMAGE):$${name}" ;\
		"$(SKILLCTL)" tag "$${local_ref}" "$(SKILL_IMAGE):$${name}" ;\
		echo "Pushing $(SKILL_IMAGE):$${name}" ;\
		"$(SKILLCTL)" push "$(SKILL_IMAGE):$${name}" ;\
	done

##@ Changelog

.PHONY: changelog-validate
changelog-validate: yq ## Validate changelog fragments are well-formed.
	YQ="$(YQ)" hack/changelog.sh validate

.PHONY: changelog-create
changelog-create: yq ## Create a changelog fragment. Usage: make changelog-create NAME=42-fix-auth KIND=bugfix
	YQ="$(YQ)" hack/changelog.sh create "$(NAME)" "$(KIND)"

.PHONY: changelog-assemble
changelog-assemble: yq ## Assemble changelog fragments into CHANGELOG.md. Usage: make changelog-assemble VERSION=v0.1.0
	YQ="$(YQ)" hack/changelog.sh assemble "$(VERSION)"

.PHONY: changelog-draft
changelog-draft: yq ## Assemble changelog fragments as "Unreleased" without deleting fragments.
	YQ="$(YQ)" hack/changelog.sh assemble --draft

##@ Dependencies

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p "$(LOCALBIN)"

## Tool Binaries
KUBECTL ?= kubectl
KIND ?= kind
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
ENVTEST ?= $(LOCALBIN)/setup-envtest
GOLANGCI_LINT = $(LOCALBIN)/golangci-lint
YQ ?= $(LOCALBIN)/yq

## Tool Versions
YQ_VERSION ?= v4.45.4
KUSTOMIZE_VERSION ?= v5.8.1
CONTROLLER_TOOLS_VERSION ?= v0.21.0

#ENVTEST_VERSION is the controller-runtime version to use for setup-envtest, derived from go.mod
ENVTEST_VERSION ?= $(shell v='$(call gomodver,sigs.k8s.io/controller-runtime)'; \
  [ -n "$$v" ] || { echo "Set ENVTEST_VERSION manually (controller-runtime replace has no tag)" >&2; exit 1; }; \
  printf '%s\n' "$$v")

#ENVTEST_K8S_VERSION is the version of Kubernetes to use for setting up ENVTEST binaries (i.e. 1.31)
ENVTEST_K8S_VERSION ?= $(shell v='$(call gomodver,k8s.io/api)'; \
  [ -n "$$v" ] || { echo "Set ENVTEST_K8S_VERSION manually (k8s.io/api replace has no tag)" >&2; exit 1; }; \
  printf '%s\n' "$$v" | sed -E 's/^v?[0-9]+\.([0-9]+).*/1.\1/')

GOLANGCI_LINT_VERSION ?= v2.12.2
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	$(call go-install-tool,$(KUSTOMIZE),sigs.k8s.io/kustomize/kustomize/v5,$(KUSTOMIZE_VERSION))

.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	$(call go-install-tool,$(CONTROLLER_GEN),sigs.k8s.io/controller-tools/cmd/controller-gen,$(CONTROLLER_TOOLS_VERSION))

.PHONY: setup-envtest
setup-envtest: envtest ## Download the binaries required for ENVTEST in the local bin directory.
	@echo "Setting up envtest binaries for Kubernetes version $(ENVTEST_K8S_VERSION)..."
	@"$(ENVTEST)" use $(ENVTEST_K8S_VERSION) --bin-dir "$(LOCALBIN)" -p path || { \
		echo "Error: Failed to set up envtest binaries for version $(ENVTEST_K8S_VERSION)."; \
		exit 1; \
	}

.PHONY: envtest
envtest: $(ENVTEST) ## Download setup-envtest locally if necessary.
$(ENVTEST): $(LOCALBIN)
	$(call go-install-tool,$(ENVTEST),sigs.k8s.io/controller-runtime/tools/setup-envtest,$(ENVTEST_VERSION))

.PHONY: yq
yq: $(YQ) ## Download yq locally if necessary.
$(YQ): $(LOCALBIN)
	$(call go-install-tool,$(YQ),github.com/mikefarah/yq/v4,$(YQ_VERSION))

.PHONY: golangci-lint
golangci-lint: $(GOLANGCI_LINT) ## Download golangci-lint locally if necessary.
$(GOLANGCI_LINT): $(LOCALBIN)
	$(call go-install-tool,$(GOLANGCI_LINT),github.com/golangci/golangci-lint/v2/cmd/golangci-lint,$(GOLANGCI_LINT_VERSION))
	@test -f .custom-gcl.yml && { \
		echo "Building custom golangci-lint with plugins..." && \
		$(GOLANGCI_LINT) custom --destination $(LOCALBIN) --name golangci-lint-custom && \
		mv -f $(LOCALBIN)/golangci-lint-custom $(GOLANGCI_LINT); \
	} || true

# go-install-tool will 'go install' any package with custom target and name of binary, if it doesn't exist
# $1 - target path with name of binary
# $2 - package url which can be installed
# $3 - specific version of package
define go-install-tool
@[ -f "$(1)-$(3)" ] && [ "$$(readlink -- "$(1)" 2>/dev/null)" = "$(1)-$(3)" ] || { \
set -e; \
package=$(2)@$(3) ;\
echo "Downloading $${package}" ;\
rm -f "$(1)" ;\
GOBIN="$(LOCALBIN)" go install $${package} ;\
mv "$(LOCALBIN)/$$(basename "$(1)")" "$(1)-$(3)" ;\
} ;\
ln -sf "$$(realpath "$(1)-$(3)")" "$(1)"
endef

define gomodver
$(shell go list -m -f '{{if .Replace}}{{.Replace.Version}}{{else}}{{.Version}}{{end}}' $(1) 2>/dev/null)
endef
