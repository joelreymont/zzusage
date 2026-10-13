#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig=${ZIG:-zig}
mkdir -p "$project/benchmark/bin" "$project/.build/zig-cache" "$project/.build/zig-global"
"$zig" build-exe "$project/benchmark/zig-full/main.zig" -lc -j1 -O small -fstrip \
  --cache-dir "$project/.build/zig-cache" --global-cache-dir "$project/.build/zig-global" \
  -femit-bin="$project/benchmark/bin/zzusage-zig-full-small"
