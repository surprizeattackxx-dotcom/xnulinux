#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# In the VM, after scripts/vm-xnu-rebuild.sh: the kit a user links Apple's kexts with on their own machine
# (scripts/apple-kc/link.sh), so that what is distributed holds nothing of Apple's:
#   KIT/kernel.macho     the hosted kernel, as vm-xnu-rebuild.sh linked it (its segment slots fit macOS 27.2's collection)
#   KIT/segaddrs.json    those slots, for macOS-DroidVM's kc-build27.py
#   KIT/kexts/NAME/      xnulinux's own kexts, the objects and the description kc-build links them from
#   KIT/kc-build.patch   the local changes to macOS-DroidVM's kc-build the collection is linked with, when there are any
#   KIT/kc-free.bin      the collection without Apple's kexts (scripts/free-kc/build.sh), when it was built
#   KIT/kit.json         what link.sh needs to make the same collection vm-xnu-rebuild.sh makes: the kernelcache it must
#                        be given (sha256), the Apple kexts to keep, the kexts of ours, macOS-DroidVM's revision, AMFI's
#                        platform version
#   scripts/apple-kc/package.sh [KIT]          (default ~/w/apple-kc-kit)
set -euo pipefail
POC=$(cd "$(dirname "$0")/../.." && pwd)
DVM=${DVM:-$HOME/w/dvm}; KIT=${1:-$HOME/w/apple-kc-kit}
[ -s $DVM/out/k27/natives.txt ] || { echo "$DVM/out/k27/natives.txt: run scripts/vm-xnu-rebuild.sh (with out/kc/kc27.bin) first" >&2; exit 1; }
rm -rf $KIT; mkdir -p $KIT/kexts
# link.sh fetches kc-build at macOS-DroidVM's revision; the local changes to it this collection was linked with go along
# (KIT/kc-build.patch, applied there)
KCB="scripts/kc-build.py scripts/kc_native.py scripts/fileset_kc.py scripts/kc_reloc.py k27/kc-build27.py"
git -C $DVM diff --binary HEAD -- $KCB > $KIT/kc-build.patch
[ -s $KIT/kc-build.patch ] || rm $KIT/kc-build.patch
cp $DVM/out/k27/kernel-k27.macho $KIT/kernel.macho
cp $DVM/k27/segaddrs.json $KIT/segaddrs.json
[ -e /lib/firmware/xnu/kc-free.bin ] && cp /lib/firmware/xnu/kc-free.bin $KIT/kc-free.bin
# Apple's kexts to keep: what k27/try.sh passes to kc-build27.py for vm-xnu-rebuild.sh (configs/kc-keep.txt, which
# vm-xnu-rebuild.sh extends with xnu-patches/kc-keep-extra.txt, and the DiskImages kexts)
DI=$(sed -n 's/^DI_KEXTS="\(.*\)"$/\1/p' $DVM/k27/try.sh)
[ -n "$DI" ] || { echo "$DVM/k27/try.sh: no DI_KEXTS" >&2; exit 1; }
python3 - $DVM $KIT "$(sha256sum $DVM/out/kc/kc27.bin | cut -d' ' -f1)" "$(git -C $DVM rev-parse HEAD)" \
	"$(git -C $POC rev-parse HEAD 2>/dev/null || echo unknown)" "${AMFI_PLATFORM:-26}" $(cat $DVM/out/k27/natives.txt) -- \
	$(grep -v '^#' $DVM/configs/kc-keep.txt) $DI <<'PY'
import json, os, shutil, sys
from pathlib import Path
dvm, kit, kc_sha, dvm_rev, poc_rev, amfi = sys.argv[1:7]
rest = sys.argv[7:]
natives, keep = rest[:rest.index('--')], rest[rest.index('--') + 1:]
kit = Path(kit)
specs = []
for path in natives:
    spec = json.loads(Path(path).read_text())
    name = spec['name']
    objects = Path(dvm, spec['objects'])     # relative to macOS-DroidVM's root, where kc-build runs
    d = kit / 'kexts' / name
    d.mkdir(parents=True)
    copied = []
    for o in json.loads(objects.read_text()):
        assert not (d / Path(o).name).exists(), (name, o)
        shutil.copy(o, d / Path(o).name)
        copied.append(f'kexts/{name}/{Path(o).name}')
    (d / 'objects.json').write_text(json.dumps(copied, indent=1) + '\n')
    spec['objects'] = f'kexts/{name}/objects.json'   # relative to the kit, where link.sh runs kc-build
    (d / f'{name}.json').write_text(json.dumps(spec, indent=2) + '\n')
    specs.append(f'kexts/{name}/{name}.json')
seen = set()
keep = [k for k in keep if k and not (k in seen or seen.add(k))]
(kit / 'kit.json').write_text(json.dumps({
    'kernelcache_sha256': kc_sha,
    'kernelcache': "macOS 27.2 (26B123) kernelcache.release.vma2, unpacked from its IM4P",
    'ipsw': json.loads(Path(dvm, 'configs/macos-27.2-26B123.json').read_text())['ipsw']['url'],
    'droidvm': {'url': 'https://github.com/Droid-VM/macOS-DroidVM', 'rev': dvm_rev},
    'xnulinux_rev': poc_rev,
    'amfi_platform': int(amfi),
    'keep': keep,
    'native': specs,
}, indent=1) + '\n')
print(f'{kit}: kernel, {len(specs)} kexts of ours, {len(keep)} Apple kexts to keep')
PY
du -sh $KIT
