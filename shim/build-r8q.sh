#!/bin/bash
# Build the r8q (Samsung SM-G781B, SM8250/kona) shim and XNU payload, then
# repack them into the header of the verified stock r8q boot image.
#
# The shim is platform-independent SM8250 code. The board-specific data is the
# r8q DTB, the stock Samsung boot header (addresses/page size), and the ADT's
# r8q identification. The XNU kernel itself is the Apollo artifact.
set -euo pipefail
cd "$(dirname "$0")"

TC=${TC:-/opt/miniconda3/envs/unixnu/bin}
KERNEL=${KERNEL:-../xnu/out/kernel.development.sweet}
DTB=${DTB:-../dtb/boot_unpacked/dtb}
TEMPLATE=${R8Q_BOOT_TEMPLATE:-$HOME/unixnu-r8q/backups/r8q-20261020-073427/boot.img}
OUT=${OUT:-out/r8q}
HIGHMEM=${HIGHMEM:-1}
TEMPLATE_SHA=6f262d5ce7479648e9692cd401a7938c249b68a312426124c8408c84c54beb3e
CMDLINE=${CMDLINE:-"debug=0xc serial=3 cpus=1 keepsyms=1 -enable_kprintf_spam -noprogress rd=ufsroot0 unentitled_ios_sim_launch=1 ignition_level=1 wdt_test=no_user_checkin ufsrw=1 rootrw=1 launchd_unsecure_cache=1 wdt=-1 sweetfb_noconsole=0 sweettouch=0 sweetkeys=0 sweetcpufreq=0"}

for f in "$TC/clang" "$TC/ld.lld" "$TC/llvm-objcopy" "$TC/llvm-nm" "$TC/llvm-readelf"; do
	[ -x "$f" ] || { echo "missing tool: $f" >&2; exit 1; }
done
for f in "$KERNEL" "$DTB" "$TEMPLATE"; do
	[ -f "$f" ] || { echo "missing input: $f" >&2; exit 1; }
done

got=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$TEMPLATE")
if [ "$got" != "$TEMPLATE_SHA" ]; then
	echo "error: r8q stock boot template hash mismatch" >&2
	echo "  expected $TEMPLATE_SHA" >&2
	echo "  got      $got" >&2
	exit 1
fi

mkdir -p "$OUT"

echo "== ADT (r8q, highmem)"
ADT_FLAGS=(--r8q)
if [ "$HIGHMEM" = 1 ]; then ADT_FLAGS+=(--highmem); fi
python3 ../tools/mkadt.py "$OUT/r8q.adt" "${ADT_FLAGS[@]}"

echo "== XNU payload"
python3 ../tools/mkpayload.py "$KERNEL" "$OUT/r8q.adt" "$OUT/payload.bin" --cmdline "$CMDLINE"

echo "== shim objects"
CFLAGS=(-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align
	-fno-stack-protector -Wall -Wextra --target=aarch64-linux-gnu)
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	"$TC/clang" "${CFLAGS[@]}" -c "$f" -o "$OUT/${f%.*}.o"
done

# The shim runs at 0x8000 without a relocation pass. Only the Linux Image
# header's image_size in start.o may be absolute; the C objects must be PIC
# in effect (PC-relative adrp/add only).
for o in shim console mmu fdt loader ufs; do
	n=$("$TC/llvm-readelf" -r "$OUT/$o.o" | grep -c ABS64 || true)
	if [ "$n" != 0 ]; then
		echo "error: $o.o has $n absolute relocations" >&2
		exit 1
	fi
done

echo "== shim link"
"$TC/ld.lld" -static -T shim.ld -N --build-id=none -o "$OUT/shim.elf" \
	"$OUT/start.o" "$OUT/shim.o" "$OUT/console.o" "$OUT/mmu.o" \
	"$OUT/fdt.o" "$OUT/loader.o" "$OUT/ufs.o"
"$TC/llvm-objcopy" -O binary "$OUT/shim.elf" "$OUT/Image"

size_hex=$("$TC/llvm-nm" "$OUT/shim.elf" | awk '$3=="_end"{print $1}')
[ -n "$size_hex" ] || { echo "error: no _end symbol" >&2; exit 1; }
size=$((16#$size_hex))
python3 - "$OUT/Image" "$size" <<'PY'
import sys
path, want = sys.argv[1], int(sys.argv[2])
data = open(path, 'rb').read()
if len(data) > want:
    raise SystemExit(f'{path}: binary {len(data)} > _end {want}')
open(path, 'ab').write(b'\0' * (want - len(data)))
print(f'shim flat image: {want} bytes (padded from {len(data)})')
PY

echo "== boot image (stock r8q header)"
python3 ../tools/repack_bootv2.py \
	--template "$TEMPLATE" \
	--kernel "$OUT/Image" \
	--ramdisk "$OUT/payload.bin" \
	--dtb "$DTB" \
	-o "$OUT/shim-boot-r8q.img"

echo "== result"
ls -l "$OUT/Image" "$OUT/payload.bin" "$OUT/shim-boot-r8q.img"
python3 -c 'import hashlib,sys; print("sha256", hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest(), sys.argv[1])' "$OUT/shim-boot-r8q.img"
