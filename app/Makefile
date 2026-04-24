TRIPLE := $(shell rustc -vV | sed -n 's/host: //p')
TRANSCRIBE_DIR := ../transcribe
TRANSCRIBE_BIN := $(TRANSCRIBE_DIR)/.build/release/transcribe
SIDECAR := src-tauri/binaries/transcribe-$(TRIPLE)

.PHONY: sidecar clean-sidecar dev build

sidecar:
	cd $(TRANSCRIBE_DIR) && swift build -c release
	mkdir -p $(dir $(SIDECAR))
	cp $(TRANSCRIBE_BIN) $(SIDECAR)

clean-sidecar:
	rm -f $(SIDECAR)

dev: sidecar
	bun run tauri dev

build: sidecar
	bun run tauri build
