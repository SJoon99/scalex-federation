# scalex-release-template task runner (https://just.systems)
# `just` with no arguments lists available recipes.

chart    := "chart"
release  := "scalex-release"
registry := env_var_or_default("REGISTRY", "10.34.25.18/tower-ci/release-app")
tag      := env_var_or_default("TAG", "v0.1.0")

# List recipes
default:
    @just --list

# helm lint --strict + ruff + scaffold linters (go vet, cargo clippy)
lint:
    helm lint {{chart}} --strict
    cd services/hello && uv run --group dev ruff check .
    cd scaffolds/go-service && go vet ./...
    cd scaffolds/rust-service && cargo clippy --locked -- -D warnings

# Render the chart with default values (hello -> edgex)
template:
    helm template {{release}} {{chart}}

# Render with hello retargeted to twinx (placement demo)
template-twinx:
    helm template {{release}} {{chart}} --set apps.hello.targetCluster=twinx

# All test suites
test: test-chart test-python test-scaffolds

# helm-unittest specs (apps catalog + placement policies)
test-chart:
    helm unittest {{chart}}

test-python:
    cd services/hello && uv run --group dev pytest

# Keep the Go/Rust scaffolds compiling
test-scaffolds:
    cd scaffolds/go-service && go build ./...
    cd scaffolds/rust-service && cargo check --locked

# Build all app images (context = repo root, per tower-ci contract)
images:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in images/*/; do
        s=$(basename "$d")
        docker build -f "images/$s/Dockerfile" -t {{registry}}/$s:{{tag}} .
    done

# Run the hello app locally
run-local:
    cd services/hello && PORT=8080 MESSAGE="local dev" PYTHONPATH=src python3 -m hello
