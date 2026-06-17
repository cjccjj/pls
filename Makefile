APP     := pls
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
LDFLAGS := -s -w -X 'github.com/cjccjj/pls/internal/pls.Version=$(VERSION)'
GCFLAGS := -trimpath
GOFLAGS := CGO_ENABLED=0
GOOS    := linux

.PHONY: build build-upx release clean test

build:
	$(GOFLAGS) go build $(GCFLAGS) -ldflags="$(LDFLAGS)" -o $(APP) ./cmd/pls
	@ls -lh $(APP)

build-upx: build
	upx --best --lzma $(APP)
	@ls -lh $(APP)

release:
	@mkdir -p dist
	GOOS=linux GOARCH=amd64 $(GOFLAGS) go build $(GCFLAGS) -ldflags="$(LDFLAGS)" -o dist/$(APP)-linux-amd64 ./cmd/pls
	GOOS=linux GOARCH=arm64 $(GOFLAGS) go build $(GCFLAGS) -ldflags="$(LDFLAGS)" -o dist/$(APP)-linux-arm64 ./cmd/pls
	@ls -lh dist/

release-upx: release
	upx --best --lzma dist/$(APP)-linux-amd64
	upx --best --lzma dist/$(APP)-linux-arm64
	@ls -lh dist/

clean:
	rm -f $(APP)
	rm -rf dist/

test:
	go test ./...
