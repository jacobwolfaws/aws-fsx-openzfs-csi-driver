# Copyright 2023 The Kubernetes Authors.
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

VERSION?=0.1.0

PKG=github.com/kubernetes-sigs/aws-fsx-openzfs-csi-driver
GIT_COMMIT?=$(shell git rev-parse HEAD)
BUILD_DATE?=$(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

LDFLAGS?="-X ${PKG}/pkg/driver.driverVersion=${VERSION} -X ${PKG}/pkg/cloud.driverVersion=${VERSION} -X ${PKG}/pkg/driver.gitCommit=${GIT_COMMIT} -X ${PKG}/pkg/driver.buildDate=${BUILD_DATE} -s -w"

GO111MODULE=on
GOPROXY=direct
GOPATH=$(shell go env GOPATH)
GOOS=$(shell go env GOOS)
GOBIN=$(shell pwd)/bin

IMAGE?=public.ecr.aws/fsx-csi-driver/aws-fsx-openzfs-csi-driver
TAG?=$(GIT_COMMIT)

OUTPUT_TYPE?=docker

ARCH?=amd64
OS?=linux
OSVERSION?=amazon

ALL_OS?=linux
ALL_ARCH_linux?=amd64 arm64
ALL_OSVERSION_linux?=amazon
ALL_OS_ARCH_OSVERSION_linux=$(foreach arch, $(ALL_ARCH_linux), $(foreach osversion, ${ALL_OSVERSION_linux}, linux-$(arch)-${osversion}))

ALL_OS_ARCH_OSVERSION=$(foreach os, $(ALL_OS), ${ALL_OS_ARCH_OSVERSION_${os}})

PLATFORM?=linux/amd64,linux/arm64

# split words on hyphen, access by 1-index
word-hyphen = $(word $2,$(subst -, ,$1))

.EXPORT_ALL_VARIABLES:

.PHONY: linux/$(ARCH) bin/aws-fsx-openzfs-csi-driver
linux/$(ARCH): bin/aws-fsx-openzfs-csi-driver
bin/aws-fsx-openzfs-csi-driver: | bin
	CGO_ENABLED=0 GOOS=linux GOARCH=$(ARCH) go build -mod=mod -ldflags ${LDFLAGS} -o bin/aws-fsx-openzfs-csi-driver ./cmd/

# Builds all images
.PHONY: all
all: all-image-docker

# Builds all images and pushes them
.PHONY: all-push
all-push: create-manifest-and-images
	docker manifest push --purge $(IMAGE):$(TAG)

.PHONY: create-manifest-and-images
create-manifest-and-images: all-image-registry
# sed expression:
# LHS: match 0 or more not space characters
# RHS: replace with $(IMAGE):$(TAG)-& where & is what was matched on LHS
	docker manifest create --amend $(IMAGE):$(TAG) $(shell echo $(ALL_OS_ARCH_OSVERSION) | sed -e "s~[^ ]*~$(IMAGE):$(TAG)\-&~g")

.PHONY: all-image-docker
all-image-docker: $(addprefix sub-image-docker-,$(ALL_OS_ARCH_OSVERSION_linux))
.PHONY: all-image-registry
all-image-registry: $(addprefix sub-image-registry-,$(ALL_OS_ARCH_OSVERSION))

sub-image-%:
	$(MAKE) OUTPUT_TYPE=$(call word-hyphen,$*,1) OS=$(call word-hyphen,$*,2) ARCH=$(call word-hyphen,$*,3) OSVERSION=$(call word-hyphen,$*,4) image

.PHONY: image
image: .image-$(TAG)-$(OS)-$(ARCH)-$(OSVERSION)
.image-$(TAG)-$(OS)-$(ARCH)-$(OSVERSION):
	docker buildx build \
		--platform=$(OS)/$(ARCH) \
		--progress=plain \
		--target=$(OS)-$(OSVERSION) \
		--output=type=$(OUTPUT_TYPE) \
		-t=$(IMAGE):$(TAG)-$(OS)-$(ARCH)-$(OSVERSION) \
		--build-arg=GOPROXY=$(GOPROXY) \
		--build-arg=VERSION=$(VERSION) \
		`./hack/provenance` \
		.
	touch $@

.PHONY: test
test:
	go test -v -race ./cmd/... ./pkg/...

.PHONY: test-sanity
test-sanity:
	go test -v ./tests/sanity/...

.PHONY: clean
clean:
	rm -rf .*image-* bin/

bin /tmp/helm /tmp/kubeval:
	@mkdir -p $@

bin/helm: | /tmp/helm bin
	@curl -o /tmp/helm/helm.tar.gz -sSL https://get.helm.sh/helm-v3.11.2-${GOOS}-amd64.tar.gz
	@tar -zxf /tmp/helm/helm.tar.gz -C bin --strip-components=1
	@rm -rf /tmp/helm/*

.PHONY: verify-kustomize
verify: verify-kustomize
verify-kustomize:
	@ echo; echo "### $@:"
	@ ./hack/verify-kustomize

.PHONY: generate-kustomize
generate-kustomize: bin/helm
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/controller-deployment.yaml --api-versions 'snapshot.storage.k8s.io/v1' | sed -e "/namespace: /d" > ../../deploy/kubernetes/base/controller-deployment.yaml
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/csidriver.yaml > ../../deploy/kubernetes/base/csidriver.yaml
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/node-daemonset.yaml | sed -e "/namespace: /d" > ../../deploy/kubernetes/base/node-daemonset.yaml
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/poddisruptionbudget-controller.yaml --api-versions 'policy/v1/PodDisruptionBudget' | sed -e "/namespace: /d" > ../../deploy/kubernetes/base/poddisruptionbudget-controller.yaml
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/controller-serviceaccount.yaml | sed -e "/namespace: /d" > ../../deploy/kubernetes/base/controller-serviceaccount.yaml
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/node-serviceaccount.yaml | sed -e "/namespace: /d" > ../../deploy/kubernetes/base/node-serviceaccount.yaml
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/clusterrole-csi-node.yaml > ../../deploy/kubernetes/base/clusterrole-csi-node.yaml
	cd charts/aws-fsx-openzfs-csi-driver && ../../bin/helm template kustomize . -s templates/clusterrolebinding-csi-node.yaml > ../../deploy/kubernetes/base/clusterrolebinding-csi-node.yaml
