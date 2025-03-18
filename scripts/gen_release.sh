#!/usr/bin/env sh

# This script is meant to generate a release using zig's build system

# Arguments:
# 1. version (semver compatible)

set -xe

version="$1"

rm -rf zig-out
zig build -Duse_llvm -Dbuild_all -Dversion=$version -Doptimize=ReleaseSafe
mkdir -pv releases/$version
cp -v zig-out/bin/* releases/$version/
