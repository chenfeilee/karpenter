# This is the format of an AWS ECR Public Repo as an example.
export KWOK_REPO ?= ${ACCOUNT_ID}.dkr.ecr.${DEFAULT_REGION}.amazonaws.com
export SYSTEM_NAMESPACE=kube-system

HELM_OPTS ?= --set logLevel=debug \
			--set controller.resources.requests.cpu=1 \
			--set controller.resources.requests.memory=1Gi \
			--set controller.resources.limits.cpu=1 \
			--set controller.resources.limits.memory=1Gi 

help: ## Display help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

presubmit: verify test licenses vulncheck ## Run all steps required for code to be checked in

install-kwok: ## Install kwok provider
	UNINSTALL_KWOK=false ./hack/install-kwok.sh
uninstall-kwok: ## Install kwok provider
	UNINSTALL_KWOK=true ./hack/install-kwok.sh

build: ## Build the Karpenter KWOK controller images using ko build
	$(eval CONTROLLER_IMG=$(shell $(WITH_GOFLAGS) KO_DOCKER_REPO="$(KWOK_REPO)" ko build -B sigs.k8s.io/karpenter/kwok))
	$(eval IMG_REPOSITORY=$(shell echo $(CONTROLLER_IMG) | cut -d "@" -f 1 | cut -d ":" -f 1))
	$(eval IMG_TAG=$(shell echo $(CONTROLLER_IMG) | cut -d "@" -f 1 | cut -d ":" -f 2 -s))
	$(eval IMG_DIGEST=$(shell echo $(CONTROLLER_IMG) | cut -d "@" -f 2))
	

# Run make install-kwok to install the kwok controller in your cluster first
# Webhooks are currently not supported in the kwok provider.
apply: verify build ## Deploy the kwok controller from the current state of your git repository into your ~/.kube/config cluster
	hack/validation/kwok-requirements.sh
	kubectl apply -f pkg/apis/crds
	helm upgrade --install karpenter kwok/charts --namespace kube-system --skip-crds \
		$(HELM_OPTS) \
		--set controller.image.repository=$(IMG_REPOSITORY) \
		--set controller.image.tag=$(IMG_TAG) \
		--set controller.image.digest=$(IMG_DIGEST) \
		--set-string controller.env[0].name=ENABLE_PROFILING \
		--set-string controller.env[0].value=true

delete: ## Delete the controller from your ~/.kube/config cluster
	helm uninstall karpenter --namespace ${KARPENTER_NAMESPACE}
	
test: ## Run tests
	go test ./... \
		-race \
		-timeout 10m \
		--ginkgo.focus="${FOCUS}" \
		--ginkgo.timeout=10m \
		--ginkgo.v \
		-cover -coverprofile=coverage.out -outputdir=. -coverpkg=./...

deflake: ## Run randomized, racing tests until the test fails to catch flakes
	ginkgo \
		--race \
		--focus="${FOCUS}" \
		--timeout=10m \
		--randomize-all \
		--until-it-fails \
		-v \
		./pkg/...

vulncheck: ## Verify code vulnerabilities
	@govulncheck ./pkg/...

licenses: download ## Verifies dependency licenses
	! go-licenses csv ./... | grep -v -e 'MIT' -e 'Apache-2.0' -e 'BSD-3-Clause' -e 'BSD-2-Clause' -e 'ISC' -e 'MPL-2.0'

verify: ## Verify code. Includes codegen, dependencies, linting, formatting, etc
	go mod tidy
	go generate ./...
	hack/validation/kubelet.sh
	hack/validation/taint.sh
	hack/validation/requirements.sh
	hack/validation/labels.sh
	hack/dependabot.sh
	@# Use perl instead of sed due to https://stackoverflow.com/questions/4247068/sed-command-with-i-option-failing-on-mac-but-works-on-linux
	@# We need to do this "sed replace" until controller-tools fixes this parameterized types issue: https://github.com/kubernetes-sigs/controller-tools/issues/756
	@perl -i -pe 's/sets.Set/sets.Set[string]/g' pkg/scheduling/zz_generated.deepcopy.go
	hack/boilerplate.sh
	go vet ./...
	golangci-lint run
	@git diff --quiet ||\
		{ echo "New file modification detected in the Git working tree. Please check in before commit."; git --no-pager diff --name-only | uniq | awk '{print "  - " $$0}'; \
		if [ "${CI}" = true ]; then\
			exit 1;\
		fi;}
	actionlint -oneline

download: ## Recursively "go mod download" on all directories where go.mod exists
	$(foreach dir,$(MOD_DIRS),cd $(dir) && go mod download $(newline))

toolchain: ## Install developer toolchain
	./hack/toolchain.sh

.PHONY: help presubmit dev test verify toolchain
