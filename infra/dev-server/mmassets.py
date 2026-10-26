"""Deterministic test assets generated with the standard library only:
PNG (zlib), baseline JPEG (tiny encoder below), PDF, SVG, WAV, ZIP and text.
"""

import io
import math
import random
import struct
import wave
import zipfile
import zlib

# --------------------------------------------------------------------------
# Raster images (RGB bytearray, row-major)
# --------------------------------------------------------------------------


def _clamp(v):
    return 0 if v < 0 else (255 if v > 255 else int(v))


def scene_landscape(w, h, seed=1):
    """Sky gradient, sun, two mountain ranges, a lake."""
    rnd = random.Random(seed)
    sky_top = (rnd.randint(20, 60), rnd.randint(40, 90), rnd.randint(120, 180))
    sky_bot = (rnd.randint(230, 255), rnd.randint(140, 190), rnd.randint(80, 130))
    sun_x, sun_y, sun_r = w * rnd.uniform(0.55, 0.8), h * 0.42, min(w, h) * 0.09
    ph1, ph2 = rnd.uniform(0, 6), rnd.uniform(0, 6)
    ridge1 = [h * (0.55 + 0.08 * math.sin(x / w * 7 + ph1) + 0.03 * math.sin(x / w * 23 + ph2)) for x in range(w)]
    ridge2 = [h * (0.66 + 0.05 * math.sin(x / w * 11 + ph2) + 0.02 * math.sin(x / w * 37 + ph1)) for x in range(w)]
    lake = h * 0.80
    buf = bytearray(w * h * 3)
    i = 0
    for y in range(h):
        t = y / max(1, h - 1)
        sky = (sky_top[0] + (sky_bot[0] - sky_top[0]) * t,
               sky_top[1] + (sky_bot[1] - sky_top[1]) * t,
               sky_top[2] + (sky_bot[2] - sky_top[2]) * t)
        dy2 = (y - sun_y) ** 2
        for x in range(w):
            if y > lake:
                ripple = 12 * math.sin(y * 0.9 + x * 0.02)
                r, g, b = 40 + ripple, 70 + ripple, 110 + ripple + (y - lake) / h * 60
            elif y > ridge2[x]:
                r, g, b = 34, 60 + (y - ridge2[x]) * 0.2, 48
            elif y > ridge1[x]:
                r, g, b = 70, 82, 110
            else:
                d2 = (x - sun_x) ** 2 + dy2
                if d2 < sun_r * sun_r:
                    r, g, b = 255, 236, 170
                else:
                    glow = max(0.0, 1 - math.sqrt(d2) / (sun_r * 4))
                    r, g, b = sky[0] + 60 * glow, sky[1] + 40 * glow, sky[2] + 10 * glow
            buf[i] = _clamp(r)
            buf[i + 1] = _clamp(g)
            buf[i + 2] = _clamp(b)
            i += 3
    return buf


def scene_pattern(w, h, seed=2):
    """Concentric rings and a checker overlay: good for spotting scaling bugs."""
    rnd = random.Random(seed)
    c1 = (rnd.randint(0, 255), rnd.randint(0, 255), rnd.randint(0, 255))
    c2 = (255 - c1[0], 255 - c1[1], 255 - c1[2])
    cx, cy = w / 2, h / 2
    buf = bytearray(w * h * 3)
    i = 0
    cell = max(8, w // 16)
    for y in range(h):
        for x in range(w):
            d = math.sqrt((x - cx) ** 2 + (y - cy) ** 2)
            t = 0.5 + 0.5 * math.sin(d / 9.0)
            chk = ((x // cell) + (y // cell)) & 1
            k = 0.85 if chk else 1.0
            buf[i] = _clamp((c1[0] * t + c2[0] * (1 - t)) * k)
            buf[i + 1] = _clamp((c1[1] * t + c2[1] * (1 - t)) * k)
            buf[i + 2] = _clamp((c1[2] * t + c2[2] * (1 - t)) * k)
            i += 3
    return buf


def scene_screenshot(w, h, seed=3):
    """A fake phone screenshot: nav bar, list rows with avatars, composer."""
    rnd = random.Random(seed)
    buf = bytearray([246] * (w * h * 3))

    def rect(x0, y0, x1, y1, col):
        x0, y0, x1, y1 = max(0, int(x0)), max(0, int(y0)), min(w, int(x1)), min(h, int(y1))
        row = bytes(col) * (x1 - x0)
        for y in range(y0, y1):
            o = (y * w + x0) * 3
            buf[o:o + len(row)] = row

    def circle(cx, cy, r, col):
        for y in range(int(cy - r), int(cy + r) + 1):
            if 0 <= y < h:
                dx = int(math.sqrt(max(0, r * r - (y - cy) ** 2)))
                rect(cx - dx, y, cx + dx, y + 1, col)

    rect(0, 0, w, h * 0.11, (30, 50, 90))
    rect(w * 0.3, h * 0.065, w * 0.7, h * 0.08, (220, 225, 240))
    y = h * 0.13
    row_h = h * 0.085
    while y + row_h < h * 0.9:
        col = (rnd.randint(60, 230), rnd.randint(60, 230), rnd.randint(60, 230))
        circle(w * 0.1, y + row_h / 2, row_h * 0.32, col)
        rect(w * 0.2, y + row_h * 0.25, w * rnd.uniform(0.5, 0.85), y + row_h * 0.4, (40, 40, 48))
        rect(w * 0.2, y + row_h * 0.55, w * rnd.uniform(0.4, 0.9), y + row_h * 0.66, (150, 150, 160))
        rect(w * 0.2, y + row_h - 1, w, y + row_h, (225, 225, 230))
        y += row_h
    rect(0, h * 0.92, w, h, (255, 255, 255))
    rect(w * 0.05, h * 0.935, w * 0.82, h * 0.975, (235, 236, 240))
    circle(w * 0.9, h * 0.955, h * 0.02, (40, 120, 230))
    return buf


def avatar_identicon(name, size=256):
    """GitHub-style 5x5 symmetric identicon derived from the name."""
    h = zlib.crc32(name.encode()) & 0xFFFFFFFF
    rnd = random.Random(h)
    fg = (rnd.randint(40, 200), rnd.randint(40, 200), rnd.randint(40, 200))
    bg = (240, 240, 244)
    grid = [[False] * 5 for _ in range(5)]
    for r in range(5):
        for c in range(3):
            on = rnd.random() < 0.55
            grid[r][c] = grid[r][4 - c] = on
    buf = bytearray(size * size * 3)
    pad = size // 10
    cell = (size - 2 * pad) / 5.0
    i = 0
    for y in range(size):
        for x in range(size):
            gx, gy = int((x - pad) // cell), int((y - pad) // cell)
            on = 0 <= gx < 5 and 0 <= gy < 5 and grid[gy][gx]
            col = fg if on else bg
            buf[i:i + 3] = bytes(col)
            i += 3
    return buf


def emoji_image(kind, size=128):
    """RGBA icons for custom emoji. kind: shipit | lgtm | partyblob."""
    buf = bytearray(size * size * 4)
    c = size / 2.0
    i = 0
    for y in range(size):
        for x in range(size):
            dx, dy = x - c + 0.5, y - c + 0.5
            d = math.sqrt(dx * dx + dy * dy)
            r = g = b = a = 0
            if kind == "lgtm":
                if d < c - 2:
                    r, g, b, a = 46, 160, 67, 255
                    # check mark: distance to two segments
                    def seg(px, py, ax, ay, bx, by):
                        vx, vy = bx - ax, by - ay
                        t = max(0.0, min(1.0, ((px - ax) * vx + (py - ay) * vy) / (vx * vx + vy * vy)))
                        return math.hypot(px - ax - t * vx, py - ay - t * vy)
                    s = size
                    if min(seg(x, y, s * .25, s * .52, s * .43, s * .70),
                           seg(x, y, s * .43, s * .70, s * .76, s * .33)) < s * .07:
                        r, g, b = 255, 255, 255
            elif kind == "shipit":
                # a little rocket-ish squirrel-free "ship it" badge
                if d < c - 2:
                    r, g, b, a = 30, 41, 59, 255
                    if abs(dx) < size * 0.12 and -size * 0.32 < dy < size * 0.18:
                        r, g, b = 226, 232, 240
                    if dy < -size * 0.2 and abs(dx) < (dy + size * 0.38) * 0.7:
                        r, g, b = 239, 68, 68
                    if size * 0.18 <= dy < size * 0.32 and abs(dx) < size * 0.06:
                        r, g, b = 251, 191, 36
                    if 0 < dy < size * 0.2 and size * 0.12 <= abs(dx) < size * 0.22 and dy > abs(dx) - size * 0.05:
                        r, g, b = 148, 163, 184
            else:  # partyblob
                if d < c - 2:
                    hue = (math.atan2(dy, dx) / (2 * math.pi) + d / size) % 1.0
                    r, g, b = _hsv(hue, 0.75, 1.0)
                    a = 255
                    if (abs(dx + size * .15) < size * .05 or abs(dx - size * .15) < size * .05) and abs(dy + size * .08) < size * .08:
                        r, g, b = 20, 20, 20
            buf[i:i + 4] = bytes((_clamp(r), _clamp(g), _clamp(b), a))
            i += 4
    return buf


def _hsv(h, s, v):
    i = int(h * 6) % 6
    f = h * 6 - int(h * 6)
    p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
    r, g, b = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return r * 255, g * 255, b * 255


# --------------------------------------------------------------------------
# PNG
# --------------------------------------------------------------------------

def png(w, h, pixels, alpha=False):
    bpp = 4 if alpha else 3
    stride = w * bpp
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        c = struct.pack("!I", len(data)) + tag + data
        return c + struct.pack("!I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    ihdr = struct.pack("!IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# --------------------------------------------------------------------------
# Baseline JPEG encoder (YCbCr 4:2:0, standard Huffman tables)
# --------------------------------------------------------------------------

_ZZ = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
       41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22,
       15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55,
       62, 63]
_QL = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57,
       69, 56, 14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55,
       64, 81, 104, 113, 92, 49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100,
       103, 99]
_QC = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99,
       99, 99, 47, 66, 99, 99, 99, 99, 99, 99] + [99] * 32
_DC_L_BITS = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0]
_DC_C_BITS = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0]
_DC_VALS = list(range(12))
_AC_L_BITS = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d]
_AC_L_VALS = bytes.fromhex(
    "01020300041105122131410613516107227114328191a1082342b1c11552d1f0"
    "2433627282090a161718191a25262728292a3435363738393a43444546474849"
    "4a535455565758595a636465666768696a737475767778797a83848586878889"
    "8a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5"
    "c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8"
    "f9fa")
_AC_C_BITS = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77]
_AC_C_VALS = bytes.fromhex(
    "0001020311040521310612415107617113223281081442 91a1b1c109233352f0"
    "156272d10a162434e125f11718191a262728292a35363738393a434445464748"
    "494a535455565758595a636465666768696a737475767778797a828384858687"
    "88898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3"
    "c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8"
    "f9fa")
assert len(_AC_L_VALS) == 162 and len(_AC_C_VALS) == 162

_COS = [[(math.sqrt(0.5) if u == 0 else 1.0) / 2.0 * math.cos((2 * x + 1) * u * math.pi / 16)
         for x in range(8)] for u in range(8)]


def _huff_table(bits, vals):
    table, code, k = {}, 0, 0
    for length in range(1, 17):
        for _ in range(bits[length - 1]):
            table[vals[k]] = (code, length)
            code += 1
            k += 1
        code <<= 1
    return table


_HT = {
    "dcl": _huff_table(_DC_L_BITS, _DC_VALS), "dcc": _huff_table(_DC_C_BITS, _DC_VALS),
    "acl": _huff_table(_AC_L_BITS, _AC_L_VALS), "acc": _huff_table(_AC_C_BITS, _AC_C_VALS),
}


class _BitWriter:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def write(self, code, length):
        self.acc = (self.acc << length) | (code & ((1 << length) - 1))
        self.n += length
        while self.n >= 8:
            self.n -= 8
            byte = (self.acc >> self.n) & 0xFF
            self.out.append(byte)
            if byte == 0xFF:
                self.out.append(0)
        self.acc &= (1 << self.n) - 1

    def flush(self):
        if self.n:
            self.write((1 << (8 - self.n)) - 1, 8 - self.n)


def _fdct_quant(block, q):
    tmp = [[sum(a * c for a, c in zip(block[y * 8:y * 8 + 8], cu)) for cu in _COS] for y in range(8)]
    out = [0] * 64
    for u in range(8):
        col = [tmp[y][u] for y in range(8)]
        for v in range(8):
            val = sum(a * c for a, c in zip(col, _COS[v])) / q[v * 8 + u]
            out[v * 8 + u] = int(round(val))
    return out


def _encode_block(bw, coeffs, prev_dc, dct, act):
    dc = coeffs[0]
    diff = dc - prev_dc
    size = abs(diff).bit_length()
    code, ln = dct[size]
    bw.write(code, ln)
    if size:
        bw.write(diff if diff > 0 else diff + (1 << size) - 1, size)
    run = 0
    for k in range(1, 64):
        v = coeffs[_ZZ[k]]
        if v == 0:
            run += 1
            continue
        while run > 15:
            code, ln = act[0xF0]
            bw.write(code, ln)
            run -= 16
        size = abs(v).bit_length()
        code, ln = act[(run << 4) | size]
        bw.write(code, ln)
        bw.write(v if v > 0 else v + (1 << size) - 1, size)
        run = 0
    if run:
        code, ln = act[0x00]
        bw.write(code, ln)
    return dc


def jpeg(w, h, rgb, quality=85):
    s = 5000 / quality if quality < 50 else 200 - 2 * quality
    ql = [max(1, min(255, int((v * s + 50) // 100))) for v in _QL]
    qc = [max(1, min(255, int((v * s + 50) // 100))) for v in _QC]
    pw, ph = (w + 15) // 16 * 16, (h + 15) // 16 * 16
    Y = [0.0] * (pw * ph)
    Cb = [0.0] * (pw * ph)
    Cr = [0.0] * (pw * ph)
    for y in range(ph):
        sy = min(y, h - 1)
        for x in range(pw):
            sx = min(x, w - 1)
            o = (sy * w + sx) * 3
            r, g, b = rgb[o], rgb[o + 1], rgb[o + 2]
            k = y * pw + x
            Y[k] = 0.299 * r + 0.587 * g + 0.114 * b - 128
            Cb[k] = -0.168736 * r - 0.331264 * g + 0.5 * b
            Cr[k] = 0.5 * r - 0.418688 * g - 0.081312 * b
    bw = _BitWriter()
    py = pcb = pcr = 0
    for my in range(0, ph, 16):
        for mx in range(0, pw, 16):
            for by, bx in ((0, 0), (0, 8), (8, 0), (8, 8)):
                blk = [Y[(my + by + j) * pw + mx + bx + i] for j in range(8) for i in range(8)]
                py = _encode_block(bw, _fdct_quant(blk, ql), py, _HT["dcl"], _HT["acl"])
            for plane, which in ((Cb, "cb"), (Cr, "cr")):
                blk = []
                for j in range(8):
                    r0 = (my + 2 * j) * pw + mx
                    r1 = r0 + pw
                    for i in range(8):
                        blk.append((plane[r0 + 2 * i] + plane[r0 + 2 * i + 1]
                                    + plane[r1 + 2 * i] + plane[r1 + 2 * i + 1]) / 4.0)
                if which == "cb":
                    pcb = _encode_block(bw, _fdct_quant(blk, qc), pcb, _HT["dcc"], _HT["acc"])
                else:
                    pcr = _encode_block(bw, _fdct_quant(blk, qc), pcr, _HT["dcc"], _HT["acc"])
    bw.flush()

    def seg(marker, payload):
        return struct.pack("!BBH", 0xFF, marker, len(payload) + 2) + payload

    out = bytearray(b"\xff\xd8")
    out += seg(0xE0, b"JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00")
    out += seg(0xDB, bytes([0]) + bytes(ql[_ZZ[i]] for i in range(64))
               + bytes([1]) + bytes(qc[_ZZ[i]] for i in range(64)))
    out += seg(0xC0, struct.pack("!BHHB", 8, h, w, 3)
               + bytes([1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]))
    for cls_id, bits, vals in ((0x00, _DC_L_BITS, _DC_VALS), (0x10, _AC_L_BITS, _AC_L_VALS),
                               (0x01, _DC_C_BITS, _DC_VALS), (0x11, _AC_C_BITS, _AC_C_VALS)):
        out += seg(0xC4, bytes([cls_id]) + bytes(bits) + bytes(vals))
    out += seg(0xDA, bytes([3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]))
    out += bw.out
    out += b"\xff\xd9"
    return bytes(out)


# --------------------------------------------------------------------------
# Documents and other files
# --------------------------------------------------------------------------

def pdf(title, pages):
    """Minimal valid PDF. pages: list of lists of text lines."""
    objs = []

    def esc(s):
        return s.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")

    n_pages = len(pages)
    font_id = 3 + 2 * n_pages
    objs.append("<< /Type /Catalog /Pages 2 0 R >>")
    kids = " ".join("%d 0 R" % (3 + 2 * i) for i in range(n_pages))
    objs.append("<< /Type /Pages /Kids [%s] /Count %d >>" % (kids, n_pages))
    for i, lines in enumerate(pages):
        content = ["BT", "/F1 22 Tf", "72 760 Td", "(%s) Tj" % esc(title), "/F1 11 Tf", "0 -34 Td"]
        for line in lines:
            content.append("(%s) Tj" % esc(line))
            content.append("0 -16 Td")
        content += ["ET", "0.85 0.88 0.95 rg", "72 60 451 3 re f",
                    "BT /F1 9 Tf 72 44 Td (Page %d of %d) Tj ET" % (i + 1, n_pages)]
        stream = "\n".join(content)
        objs.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] "
                    "/Resources << /Font << /F1 %d 0 R >> >> /Contents %d 0 R >>" % (font_id, 4 + 2 * i))
        objs.append("<< /Length %d >>\nstream\n%s\nendstream" % (len(stream.encode("latin-1")), stream))
    objs.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, body in enumerate(objs):
        offsets.append(out.tell())
        out.write(("%d 0 obj\n%s\nendobj\n" % (i + 1, body)).encode("latin-1"))
    xref = out.tell()
    out.write(("xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)).encode())
    for off in offsets:
        out.write(("%010d 00000 n \n" % off).encode())
    out.write(("trailer\n<< /Size %d /Root 1 0 R /Info << /Title (%s) /Producer (mmdev seed) >> >>\n"
               "startxref\n%d\n%%%%EOF\n" % (len(objs) + 1, esc(title), xref)).encode("latin-1"))
    return out.getvalue()


def wav_tone(seconds=3.0, rate=22050):
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        frames = bytearray()
        for i in range(int(seconds * rate)):
            t = i / rate
            f = 440 if t < seconds / 3 else (554 if t < 2 * seconds / 3 else 659)
            env = min(1.0, t * 20, (seconds - t) * 20)
            frames += struct.pack("<h", int(12000 * env * math.sin(2 * math.pi * f * t)))
        w.writeframes(bytes(frames))
    return out.getvalue()


def svg_logo():
    return ("""<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256">
  <defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#2AABEE"/><stop offset="1" stop-color="#1E325C"/></linearGradient></defs>
  <circle cx="128" cy="128" r="120" fill="url(#g)"/>
  <path d="M60 130 L190 78 L168 186 L128 156 L106 178 L108 146 L170 96 L98 140 Z" fill="#fff"/>
</svg>
""").encode()


def zip_blob(size_bytes, seed=7):
    """A zip with one compressible log and one incompressible blob."""
    rnd = random.Random(seed)
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        log = "\n".join("2026-10-%02d 12:%02d:%02d.%03d [%s] MattermostSync: %s" % (
            1 + i % 25, i % 60, (i * 7) % 60, i % 1000, rnd.choice(["DEBUG", "INFO", "WARN"]),
            rnd.choice(["applied 12 events", "websocket reconnect", "hole filled 200 posts",
                        "catch-up since=1729900000000", "outgoing post queued"])) for i in range(20000))
        z.writestr("sync.log", log, compress_type=zipfile.ZIP_DEFLATED)
        z.writestr("blob.bin", bytes(rnd.getrandbits(8) for _ in range(size_bytes)),
                   compress_type=zipfile.ZIP_STORED)
    return out.getvalue()
