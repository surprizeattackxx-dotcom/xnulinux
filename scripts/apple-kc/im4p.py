#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Unpack a kernelcache for scripts/apple-kc/link.sh, with python3 alone (and lzfse for an LZFSE payload):

    im4p.py INPUT OUTPUT [MEMBER]

INPUT is an IPSW (a zip: MEMBER, default kernelcache.release.vma2, is read from it), an IPSW's URL (Apple's own:
only the member is downloaded, with HTTP range requests), an IM4P, or an unpacked Mach-O (copied). An IM4P is DER: SEQUENCE { "IM4P", type, description, OCTET STRING payload, ... }; the payload is LZFSE
("bvx2...", decoded by the lzfse tool: apt install lzfse), LZSS ("complzss" with Apple's 0x180-byte header), or plain.
"""
import http.client
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile


class Remote:
    """A read-only, seekable file over HTTP range requests (what zipfile needs to read one member of a remote zip).
    Small reads (zip records) go through a cache of 256 KiB blocks; large ones (the member) are fetched as they are, in
    16 MiB pieces. A piece whose transfer breaks off is asked for again (a few times): a download over a long path does."""
    BLOCK, PIECE, TRIES = 1 << 18, 1 << 24, 6

    def __init__(self, url):
        self.url, self.pos, self.cache = url, 0, {}
        with urllib.request.urlopen(urllib.request.Request(url, method='HEAD'), timeout=60) as r:
            self.size = int(r.headers['Content-Length'])

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else self.pos + offset if whence == 1 else self.size + offset
        return self.pos

    def fetch(self, start, end):
        """Bytes start..end (inclusive)."""
        for attempt in range(self.TRIES):
            try:
                req = urllib.request.Request(self.url, headers={'Range': f'bytes={start}-{end}', 'Accept-Encoding': 'identity'})
                with urllib.request.urlopen(req, timeout=120) as r:
                    if r.status != 206:
                        raise SystemExit(f'{self.url}: the server does not serve byte ranges')
                    data = r.read()
                if len(data) == end - start + 1:
                    return data
                error = f'{len(data)} of {end - start + 1} bytes'
            except (OSError, http.client.HTTPException) as e:
                error = e
            print(f'bytes {start}-{end}: {error}; again', file=sys.stderr)
            time.sleep(2 ** attempt)
        raise SystemExit(f'{self.url}: bytes {start}-{end} could not be read')

    def read(self, n=-1):
        if n < 0:
            n = self.size - self.pos
        n = max(0, min(n, self.size - self.pos))
        out = bytearray()
        if n > self.BLOCK:
            while len(out) < n:
                k = min(self.PIECE, n - len(out))
                out += self.fetch(self.pos, self.pos + k - 1)
                self.pos += k
            return bytes(out)
        while len(out) < n:
            i = self.pos // self.BLOCK
            if i not in self.cache:
                self.cache[i] = self.fetch(i * self.BLOCK, min((i + 1) * self.BLOCK, self.size) - 1)
            k = self.pos % self.BLOCK
            piece = self.cache[i][k:k + n - len(out)]
            out += piece
            self.pos += len(piece)
        return bytes(out)


def der(data, at):
    """(tag, start of contents, end of contents) of the DER element at `at`."""
    tag, n = data[at], data[at + 1]
    at += 2
    if n & 0x80:
        k = n & 0x7f
        n = int.from_bytes(data[at:at + k], 'big')
        at += k
    return tag, at, at + n


def payload(data):
    tag, at, end = der(data, 0)
    if tag != 0x30:
        raise SystemExit('not an IM4P (no DER SEQUENCE)')
    items = []
    while at < end:
        t, s, e = der(data, at)
        items.append((t, s, e))
        at = e
    if len(items) < 4 or data[items[0][1]:items[0][2]] != b'IM4P' or items[3][0] != 0x04:
        raise SystemExit('not an IM4P')
    return data[items[3][1]:items[3][2]]


def lzss(src, size):
    """Apple's kernelcache LZSS (4096-byte window, 18-byte matches, threshold 2)."""
    N, F, T = 4096, 18, 2
    text = bytearray(b' ' * (N - F)) + bytearray(F)
    r, out, i, flags = N - F, bytearray(), 0, 0
    while i < len(src) and len(out) < size:
        flags >>= 1
        if not flags & 0x100:
            flags = src[i] | 0xff00
            i += 1
            if i >= len(src):
                break
        if flags & 1:
            c = src[i]
            i += 1
            out.append(c)
            text[r] = c
            r = (r + 1) & (N - 1)
        else:
            if i + 1 >= len(src):
                break
            p, q = src[i], src[i + 1]
            i += 2
            p |= (q & 0xf0) << 4
            for k in range((q & 0x0f) + T + 1):
                c = text[(p + k) & (N - 1)]
                out.append(c)
                text[r] = c
                r = (r + 1) & (N - 1)
    return bytes(out[:size])


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    member = sys.argv[3] if len(sys.argv) > 3 else 'kernelcache.release.vma2'
    if src.startswith(('https://', 'http://')):
        print(f'reading {member} from {src}', file=sys.stderr)
        with zipfile.ZipFile(Remote(src)) as z:
            data = z.read(member)
    elif zipfile.is_zipfile(src):
        with zipfile.ZipFile(src) as z:
            data = z.read(member)
    else:
        data = open(src, 'rb').read()
    if data[:4] == b'\xcf\xfa\xed\xfe':
        open(dst, 'wb').write(data)
        return
    body = payload(data)
    if body[:4] == b'bvx2':
        lz = shutil.which('lzfse')
        if not lz:
            raise SystemExit('the kernelcache is LZFSE-compressed: install lzfse (apt install lzfse)')
        with tempfile.NamedTemporaryFile() as f:
            f.write(body)
            f.flush()
            subprocess.run([lz, '-decode', '-i', f.name, '-o', dst], check=True)
    elif body[:8] == b'complzss':
        size, = struct.unpack('>I', body[12:16])
        open(dst, 'wb').write(lzss(body[0x180:], size))
    elif body[:4] == b'\xcf\xfa\xed\xfe':
        open(dst, 'wb').write(body)
    else:
        raise SystemExit(f'unknown IM4P payload ({body[:8]!r})')


main()
