#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
zig=${ZIG:-zig}
mkdir -p "$project/benchmark/bin" "$project/.build/zig-cache" "$project/.build/zig-global"
"$zig" build-exe "$project/benchmark/zig-full/main.zig" -lc -j1 -O small -fstrip \
  -fno-unwind-tables --cache-dir "$project/.build/zig-cache" \
  --global-cache-dir "$project/.build/zig-global" \
  -femit-bin="$project/.build/zzusage-zig-no-unwind"
/usr/bin/strip -u -r -o "$project/benchmark/bin/zzusage-zig-smallest" \
  "$project/.build/zzusage-zig-no-unwind"
/usr/bin/codesign --force --sign - --identifier zzusage \
  "$project/benchmark/bin/zzusage-zig-smallest"
/usr/bin/codesign --verify --strict "$project/benchmark/bin/zzusage-zig-smallest"
