SHELL := /bin/bash

.PHONY: help fast test extended release structure lint format clean build-simulator build-device prune-scratch sim-stage sim-log sim-state sim-layout sim-probe sim-perf

help:
	@echo "Targets:"
	@echo "  fast             ProjectStructure, Swift packages and offline iOS probes (what CI runs)"
	@echo "  test             Alias of fast"
	@echo "  extended         fast + native harnesses + Debug simulator/device builds"
	@echo "  release          extended + installed RimeKit check + Release builds (output under CI_OUTPUT_ROOT, default .local/ci)"
	@echo "  structure        ProjectStructure tests only"
	@echo "  lint             swift-format --strict, shellcheck and ruff on tracked sources"
	@echo "  format           Rewrite Swift sources with swift-format and apply ruff fixes"
	@echo "  clean            Remove Swift package .build directories and .local/ci"
	@echo "  build-simulator  Unsigned Debug generic simulator COMPILE CHECK only (no entitlements; not runnable, use sim-stage)"
	@echo "  build-device     Unsigned Debug generic device build"
	@echo "  sim-stage        Build Debug (ad-hoc signed, App Group entitlements), install on dedicated Songyan-Dev simulator"
	@echo "  sim-log          Stream extension/app logs from the dev simulator (LAST=2m to dump)"
	@echo "  sim-state        Print Debug state snapshots (phase/layout/latency/memory) as JSON"
	@echo "  sim-layout       Force keyboard layout on the dev simulator: make sim-layout LAYOUT=merged14|merged18|phone9|qwerty26|clear"
	@echo "  sim-probe        Toggle a Debug keyboard probe: make sim-probe PROBE=touch STATE=on|off"
	@echo "  sim-perf         Profile the keyboard extension: make sim-perf [MODE=typing|cold] [ARG=label|runs] (DEBUG.md)"
	@echo "  prune-scratch    Remove .scratch entries older than 7 days"

fast:
	Tools/CI/ci.sh fast

test: fast

extended:
	Tools/CI/ci.sh extended

release:
	Tools/CI/ci.sh release

structure:
	python3 -m unittest discover -s Tests/ProjectStructure -p 'test_*.py' -v

lint:
	Tools/CI/ci.sh lint

format:
	Tools/CI/ci.sh format

# Build caches only; engine prefixes and other .local inputs are kept.
clean:
	rm -rf Packages/*/.build .local/ci

prune-scratch:
	Tools/CI/scripts/prune-scratch.sh

build-simulator:
	Tools/CI/scripts/build-app.sh Debug simulator

build-device:
	Tools/CI/scripts/build-app.sh Debug device

sim-stage:
	Tools/CI/scripts/sim-stage.sh

sim-log:
	Tools/CI/scripts/sim-log.sh $(if $(LAST),--last $(LAST)) $(CATEGORY)

sim-state:
	Tools/CI/scripts/sim-state.sh

sim-layout:
	@test -n "$(LAYOUT)" || { echo "LAYOUT is required" >&2; exit 64; }
	Tools/CI/scripts/sim-layout.sh $(LAYOUT)

sim-probe:
	@test -n "$(PROBE)" || { echo "PROBE is required (touch)" >&2; exit 64; }
	Tools/CI/scripts/sim-probe.sh $(PROBE) $(or $(STATE),on)

sim-perf:
	Tools/CI/scripts/sim-perf.sh $(or $(MODE),typing) $(ARG)
