REGISTRY ?= higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/
IMAGE_NAME ?= all-in-one
IMAGE_VERSION ?= ""
BUILD_TIME := $(shell date "+%Y%m%d-%H%M%S")
COMMIT_ID := $(shell git rev-parse --short HEAD 2>/dev/null)
IMAGE_TAG = $(if $(strip $(IMAGE_VERSION)),${IMAGE_VERSION},${BUILD_TIME}-${COMMIT_ID})
IMG ?= ${REGISTRY}${IMAGE_NAME}:${IMAGE_TAG}
O11Y_BASE_IMG ?= ${IMG}
O11Y_IMG ?= ${IMG}-o11y

.DEFAULT:
docker-build:
	docker build \
			-t ${IMG} \
			.
	@echo ""
	@echo "Image:            ${IMG}"

docker-buildx-push:
	docker buildx build --no-cache \
			--platform linux/amd64,linux/arm64 \
			-t ${IMG} \
			--push \
			.
	@echo ""
	@echo "Image:            ${IMG}"

docker-build-o11y:
	docker build \
			-t ${IMG} \
			-f Dockerfile_o11y \
			.
	@echo ""
	@echo "Image:            ${IMG}"

docker-buildx-o11y-push:
	docker buildx build --no-cache \
			--platform linux/amd64,linux/arm64 \
			--build-arg BASE_IMAGE=${O11Y_BASE_IMG} \
			-t ${O11Y_IMG} \
			-f Dockerfile_o11y \
			--push \
			.
	@echo ""
	@echo "Image:            ${O11Y_IMG}"