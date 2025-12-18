# --- Build Stage ---
FROM --platform=$BUILDPLATFORM alpine:latest AS zig

# Build arguments for multi-platform support
ARG TARGETPLATFORM
ARG BUILDPLATFORM

# Install build dependencies
RUN apk add --no-cache \
	curl \
	xz \
	make \
	bash \
	build-base \
	ca-certificates

# Install Zig 0.15.2 autonomously based on BUILDPLATFORM
RUN case "${BUILDPLATFORM}" in \
	"linux/amd64")   ZIG_ARCH="x86_64" ;; \
	"linux/arm64")   ZIG_ARCH="aarch64" ;; \
	*)               ZIG_ARCH="x86_64" ;; \
	esac && \
	echo "Downloading Zig 0.15.2 for ${ZIG_ARCH}..." && \
	curl -fL https://ziglang.org/download/0.15.2/zig-${ZIG_ARCH}-linux-0.15.2.tar.xz -o zig.tar.xz && \
	tar -xJf zig.tar.xz --strip-components=1 -C /usr/local/bin && \
	rm zig.tar.xz

WORKDIR /app

# Map Docker TARGETPLATFORM to Zig target triples
RUN case "${TARGETPLATFORM}" in \
	"linux/amd64")   ZIG_TARGET="x86_64-linux" ;; \
	"linux/arm64")   ZIG_TARGET="aarch64-linux" ;; \
	"linux/arm/v7")  ZIG_TARGET="arm-linux" ;; \
	*)               ZIG_TARGET="x86_64-linux" ;; \
	esac && \
	echo "ZIG_TARGET=${ZIG_TARGET}" > /tmp/zig_target

FROM --platform=$BUILDPLATFORM zig AS builder

# Build arguments for multi-platform support
ARG TARGETPLATFORM
ARG BUILDPLATFORM
WORKDIR /app

# Copy project files
COPY . .

# Build using the Makefile and the mapped target
RUN . /tmp/zig_target && \
	make ${ZIG_TARGET} BUILD_DIR=/app/build

# --- Runtime Stage ---
FROM alpine:latest

# Build arguments to know which binary to copy
ARG TARGETPLATFORM

# Create necessary directories
RUN mkdir -p /etc/nomadfs /var/lib/nomadfs

WORKDIR /var/lib/nomadfs

# Copy the build artifacts and target info
COPY --from=builder /tmp/zig_target /tmp/zig_target
COPY --from=builder /app/build /tmp/build

# Install the correct binary based on the target
RUN . /tmp/zig_target && \
	cp /tmp/build/${ZIG_TARGET}/bin/nomadfs /usr/local/bin/nomadfs && \
	rm -rf /tmp/zig_target /tmp/build

# Expose the default DHT port
EXPOSE 9000

# Set entrypoint
ENTRYPOINT ["nomadfs"]
