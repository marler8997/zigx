#!/usr/bin/env sh
set -ex

zig run getserverfontnames.zig > fontnames.txt
font=$(head -n 1 fontnames.txt)
rm fontnames.txt

zig run testexample.zig
zig run graphics.zig
zig run queryfont.zig -- $font > /dev/null
zig run example.zig
zig run fontviewer.zig
zig run input.zig

echo Success
