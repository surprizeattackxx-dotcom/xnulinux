#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# On the machine that runs xnu.ko (or any Linux or macOS with python3 and git): link Apple's kexts from the user's own
# copy of macOS's kernelcache with the kernel and kexts of a kit (scripts/apple-kc/package.sh) into a kernel collection
# to boot macOS with:
#   scripts/apple-kc/link.sh KIT [KERNELCACHE [OUTPUT]]     (OUTPUT: /lib/firmware/xnu/kc-apple.bin where that exists)
# then IMAGE=xnu/kc-apple.bin scripts/xnulinux-boot.sh. Nothing of Apple's is in the kit; the collection this makes is
# the one scripts/vm-xnu-rebuild.sh makes from the same kernelcache, byte for byte.
#
# KERNELCACHE is macOS 27.2's kernelcache.release.vma2 (Apple's virtual Mac): the 27.2 IPSW itself or its URL (by
# default Apple's, KIT/kit.json: only the kernelcache is downloaded), the IM4P from it, or that unpacked
# (scripts/apple-kc/im4p.py; an LZFSE payload needs the lzfse tool). The kit's kernel was linked to fit that
# collection, so any other one is refused (sha256 in KIT/kit.json).
set -euo pipefail
POC=$(cd "$(dirname "$0")/../.." && pwd)
[ $# -ge 1 ] || { sed -n '3,6p' "$0" >&2; exit 2; }
abs() { python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$1"; }
KIT=$(abs "$1"); OUT=$(abs "${3:-$KIT/kc-apple.bin}")
INSTALL=; [ $# -lt 3 ] && [ -d /lib/firmware/xnu ] && INSTALL=/lib/firmware/xnu/kc-apple.bin
W=${APPLE_KC_WORK:-$KIT/.work}; mkdir -p "$W"
kit() { python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): v=v[k]
print(" ".join(v) if isinstance(v, list) else v)' "$KIT/kit.json" "$1"; }
sha() { python3 -c 'import hashlib,sys; h=hashlib.sha256(); f=open(sys.argv[1],"rb")
for b in iter(lambda: f.read(1<<24), b""): h.update(b)
print(h.hexdigest())' "$1"; }
magic() { python3 -c 'import sys; print(open(sys.argv[1],"rb").read(4).hex())' "$1"; }

KC=${2:-$(kit ipsw)}; case "$KC" in http://*|https://*) ;; *) KC=$(abs "$KC") ;; esac
# the kernelcache, unpacked (a Mach-O starts cffaedfe; else an IPSW, its URL or an IM4P)
if [[ "$KC" == http* ]] || [ "$(magic "$KC")" != cffaedfe ]; then
	rm -f "$W/kernelcache"; python3 "$POC/scripts/apple-kc/im4p.py" "$KC" "$W/kernelcache"; KC=$W/kernelcache
fi
want=$(kit kernelcache_sha256); have=$(sha "$KC")
if [ "$want" != "$have" ]; then
	echo "this kit links $(kit kernelcache) (sha256 $want); ${2:-$(kit ipsw)} is another one ($have)" >&2; exit 1
fi

# macOS-DroidVM's kc-build at the kit's revision, with the kit's segment slots
D=$W/droidvm; REV=$(kit droidvm.rev)
if [ "$(git -C "$D" rev-parse HEAD 2>/dev/null)" != "$REV" ]; then
	rm -rf "$D"; git init -q "$D"
	git -C "$D" sparse-checkout init --no-cone; printf '%s\n' /scripts/ /k27/ | git -C "$D" sparse-checkout set --stdin
	git -C "$D" fetch -q --depth 1 "$(kit droidvm.url)" "$REV"; git -C "$D" checkout -q FETCH_HEAD
fi
git -C "$D" checkout -q -- scripts k27
[ -e "$KIT/kc-build.patch" ] && git -C "$D" apply "$KIT/kc-build.patch"
cp "$KIT/segaddrs.json" "$D/k27/segaddrs.json"

( cd "$KIT" && python3 "$D/k27/kc-build27.py" "$KC" kernel.macho "$OUT" --keep $(kit keep) --native $(kit native) > "$W/kc-build.log" 2>&1 ) ||
	{ grep -E "Unresolv|Error|not defined|lack|Traceback|conflict|no room" "$W/kc-build.log" | head -20; echo "kc-build failed: $W/kc-build.log" >&2; exit 1; }
grep -E "wrote" "$W/kc-build.log" || true
# AMFI of 27.2 expects platform version 27; the system disks the kit was made for carry 26 (scripts/kc-amfi-platform.py)
python3 "$POC/scripts/kc-amfi-platform.py" "$OUT" "${AMFI_PLATFORM:-$(kit amfi_platform)}"
if [ -n "$INSTALL" ]; then
	sudo install -m 644 "$OUT" "$INSTALL" && OUT=$INSTALL
fi
echo "kernel collection with Apple's kexts: $OUT (boot it: IMAGE=xnu/$(basename "$OUT") scripts/xnulinux-boot.sh)"
