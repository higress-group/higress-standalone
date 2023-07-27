REGISTRY ?= higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/
IMAGE_NAME ?= api-server
IMAGE_VERSION ?= 0.0.7
BUILD_TIME := $(shell date "+%Y%m%d-%H%M%S")
COMMIT_ID := $(shell git rev-parse --short HEAD 2>/dev/null)
IMAGE_TAG = $(if $(strip $(IMAGE_VERSION)),${IMAGE_VERSION},${BUILD_TIME}-${COMMIT_ID})
IMG ?= ${REGISTRY}${IMAGE_NAME}:${IMAGE_TAG}

.DEFAULT:
build:
	docker buildx build --no-cache \
			--platform linux/amd64,linux/arm64 \
			-t ${IMG} \
			--push \
			.
	@echo ""
	@echo "Image:            ${IMG}"
