FROM golang:1.20.4 as builder

ARG GOPROXY
ENV GOPROXY=${GOPROXY}

WORKDIR /workspace

# Copy the go source
COPY . ./

# Build
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux go build -a -o apiserver main.go

# Use distroless as minimal base image to package the manager binary
# Refer to https://github.com/GoogleContainerTools/distroless for more details
FROM alpine/curl
WORKDIR /
COPY --from=builder /workspace/apiserver .
ENTRYPOINT ["/apiserver"]
