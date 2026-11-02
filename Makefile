CLANG := xcrun clang
FORMAT ?= $(shell command -v clang-format 2>/dev/null || echo /opt/homebrew/opt/llvm/bin/clang-format)
CFLAGS := -fobjc-arc -Wall -Wextra -Werror -Isrc/runtime
FRAMEWORKS := -framework Cocoa -framework QuartzCore
RUNTIME := TransitionBase GlobalRouting Duration Composition NativeWarp WindowLevel Crossfade InputRouting RestoreAcknowledgement
LIBRARIES := $(addprefix build/runtime/,$(addsuffix .dylib,$(RUNTIME)))
TESTS := $(patsubst tests/%.m,build/tests/%,$(wildcard tests/*.m))
SOURCES := $(wildcard src/runtime/*.m src/runtime/*.h src/app/*.m tests/*.m)

.PHONY: all app test analyze format check-format
all: app

build/runtime/%.dylib: src/runtime/%.m $(wildcard src/runtime/*.h)
	@mkdir -p $(@D)
	$(CLANG) $(CFLAGS) -arch arm64e -dynamiclib $< $(FRAMEWORKS) -o $@
	codesign --force --sign - $@

build/tests/%: tests/%.m $(wildcard src/runtime/* src/app/*.m)
	@mkdir -p $(@D)
	$(CLANG) $(CFLAGS) $< $(FRAMEWORKS) -o $@

test: $(TESTS)
	@set -e; for test in $(TESTS); do "$$test"; done
	python3 -m unittest discover -s tests -p 'test_*.py'

analyze:
	@mkdir -p build/analysis
	@set -e; for source in src/runtime/*.m src/app/*.m; do $(CLANG) $(CFLAGS) -arch arm64e --analyze -Xanalyzer -analyzer-output=text "$$source" -o /dev/null; done

format:
	$(FORMAT) -i $(SOURCES)

check-format:
	$(FORMAT) --dry-run --Werror $(SOURCES)

app: $(LIBRARIES) build/Dockboard
	python3 tools/package.py

build/Dockboard: src/app/Main.m
	@mkdir -p $(@D)
	$(CLANG) $(CFLAGS) $< $(FRAMEWORKS) -o $@
