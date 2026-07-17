# helper/Makefile — cross-compile the lens helper for every shipped target.
#
#   make build      four per-arch binaries under dist/<os>/<arch>/
#   make universal  + the lipo'd two-slice mac binary under dist/darwin-universal/
#   make test       unit suite (race detector on)
#   make itest      integration suite (needs Chrome; LENS_CHROME to point at one)
#
# No UPX anywhere, deliberately: UPX has had Mach-O packing disabled since
# 4.2.0 and never supported Windows-ARM64 PE — and packed binaries trip AV
# heuristics on the one platform it could serve (win-x64). Stripped Go is
# already ~6 MB vs the ~200 MB Node runtime this replaced.
#
# `lipo` on macOS; `llvm-lipo` elsewhere (ubuntu CI: apt install llvm) — same
# fat-binary output either way.

TARGETS = darwin/arm64 darwin/amd64 windows/amd64 windows/arm64
GOFLAGS = -trimpath -ldflags='-s -w'
LIPO := $(shell command -v lipo 2>/dev/null || command -v llvm-lipo 2>/dev/null || ls /usr/bin/llvm-lipo-* 2>/dev/null | head -1)

.PHONY: build universal test itest clean

build:
	@set -e; for t in $(TARGETS); do \
		GOOS=$${t%/*} GOARCH=$${t#*/} CGO_ENABLED=0 \
		go build $(GOFLAGS) -o dist/$$t/lens-helper$$([ "$${t%/*}" = "windows" ] && echo .exe) . ; \
		echo "built dist/$$t"; \
	done

universal: build
	@test -n "$(LIPO)" || { echo "need lipo or llvm-lipo (apt install llvm)" >&2; exit 1; }
	@mkdir -p dist/darwin-universal
	$(LIPO) -create dist/darwin/arm64/lens-helper dist/darwin/amd64/lens-helper \
		-output dist/darwin-universal/lens-helper
	@chmod +x dist/darwin-universal/lens-helper
	@echo "built dist/darwin-universal (arm64 + x86_64)"

test:
	go test -race ./...

itest:
	go test -tags integration -race -count=1 ./lens/

clean:
	rm -rf dist
