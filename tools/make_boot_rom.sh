#!/bin/sh
# Build boot.rom for the MiSTer core: RES1 then RES2, 2048 bytes each.
# Main_MiSTer uploads boot.rom at ioctl_index 0 when the core starts; the
# core splits it on address bit 11.
#
#   tools/make_boot_rom.sh RES1.bin RES2.bin boot.rom
set -e
[ $# -eq 3 ] || { echo "usage: $0 <res1.bin> <res2.bin> <out>"; exit 1; }
for f in "$1" "$2"; do
  n=$(wc -c < "$f")
  [ "$n" -eq 2048 ] || { echo "error: $f is $n bytes, expected 2048"; exit 1; }
done
cat "$1" "$2" > "$3"
echo "wrote $3 ($(wc -c < "$3") bytes)"
