#!/usr/bin/env bash
set -e

echo "=> Upgrading llamacpp core flake..."
cd /home/claytonw/src/flakes/llamacpp-flake
nix flake update
git add flake.lock
git commit -m "update: bump llama-cpp to latest" || echo "Core already up to date."

echo "=> Upgrading launcher flake..."
cd /home/claytonw/src/flakes/llamacpp-launcher
nix flake update
git add flake.lock
git commit -m "update: bump launcher dependencies" || echo "Launcher already up to date."

echo "=> Applying upgrade to Nix profile..."
nix profile upgrade llamacpp-launcher

echo "=> Upgrade complete!"
