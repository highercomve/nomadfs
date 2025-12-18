# Makefile for NomadFS

APP_NAME = nomadfs
VERSION = 0.1.0
BUILD_DIR = build
DIST_DIR = dist
CONFIG_FILE = nomadfs.conf

# Targets
TARGETS = x86_64-linux aarch64-linux x86_64-macos aarch64-macos x86_64-windows

.PHONY: all clean help $(TARGETS) package

all: $(TARGETS)

help:
	@echo "NomadFS Build System"
	@echo "Available targets:"
	@echo "  all             Build for all supported platforms"
	@echo "  linux-x86_64    Build for Linux x86_64"
	@echo "  linux-aarch64   Build for Linux aarch64"
	@echo "  macos-x86_64    Build for macOS x86_64"
	@echo "  macos-aarch64   Build for macOS aarch64"
	@echo "  windows-x86_64  Build for Windows x86_64"
	@echo "  package         Build and package all targets"
	@echo "  gen-swarm-key   Generate a fresh 32-byte (64 hex chars) swarm key"
	@echo "  clean           Remove build and dist directories"

gen-swarm-key:
	@openssl rand -hex 32

$(TARGETS): 
	@echo "Building for $@..."
	@mkdir -p $(BUILD_DIR)/$@
	zig build -Dtarget=$@ --release=safe -Doptimize=ReleaseSafe --prefix $(BUILD_DIR)/$@

package: $(TARGETS)
	@mkdir -p $(DIST_DIR)
	@for target in $(TARGETS); do \
		echo "Packaging $$target..."; \
		PACKAGE_NAME=$(APP_NAME)-$(VERSION)-$$target; \
		TMP_DIR=$(DIST_DIR)/$$PACKAGE_NAME; \
		mkdir -p $$TMP_DIR; \
		if [ "$$target" = "x86_64-windows" ]; then \
			cp $(BUILD_DIR)/$$target/bin/$(APP_NAME).exe $$TMP_DIR/; \
			cp $(CONFIG_FILE) $$TMP_DIR/; \
			cd $(DIST_DIR) && zip -r $$PACKAGE_NAME.zip $$PACKAGE_NAME && cd ..; \
		else \
			cp $(BUILD_DIR)/$$target/bin/$(APP_NAME) $$TMP_DIR/; \
			cp $(CONFIG_FILE) $$TMP_DIR/; \
			tar -czf $(DIST_DIR)/$$PACKAGE_NAME.tar.gz -C $(DIST_DIR) $$PACKAGE_NAME; \
		fi; \
		rm -rf $$TMP_DIR; \
	done

clean:
	rm -rf $(BUILD_DIR) $(DIST_DIR) zig-out .zig-cache
