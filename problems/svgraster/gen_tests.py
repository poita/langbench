#!/usr/bin/env python3
"""Regenerate problems/svgraster/tests/.

Each test directory gets an `input/` holding SVG files and a render.txt, and an
`expected/` holding the PPM that reference/main.py produces for each of them.
Every expected image is then cross-checked against resvg, which is the oracle
for this problem.

resvg (tiny-skia) anti-aliases with four sub-scanlines per pixel row, so its
edge pixels are quantised much more coarsely than the reference's analytic
coverage. A direct comparison therefore has to be loose. The tight check
renders both at four times the target size and box-filters back down, which
averages the quantisation away and leaves only genuine geometry differences; it
runs on every hand-written file and on a deterministic sample of the corpus.
"""
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, 'tests')
CORPUS = os.path.join(HERE, 'corpus')
RESVG = '/opt/homebrew/bin/resvg'

sys.path.insert(0, os.path.join(HERE, 'reference'))
import main as ref                                        # noqa: E402

# Tolerances for the oracle cross-check. "bad" pixels are ones where some
# channel differs by more than 8.
DIRECT_MAX_MEAN = 8.0
DIRECT_MAX_BAD_PCT = 30.0
DIRECT_MAX_DIFF = 140
HIRES_MAX_MEAN = 3.0
HIRES_MAX_BAD_PCT = 2.0
HIRES_MAX_DIFF = 40
HIRES_SCALE = 4
HIRES_MAX_PIXELS = 256 * 256


# ---------------------------------------------------------------------------
# PNG decoding (resvg writes 8-bit non-interlaced RGBA)
# ---------------------------------------------------------------------------

def decode_png(data):
    """Return (width, height, colour type, raw samples) of an 8-bit PNG."""
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError('not a PNG')
    i = 8
    idat = bytearray()
    w = h = ctype = None
    while i < len(data):
        length = struct.unpack('>I', data[i:i + 4])[0]
        kind = data[i + 4:i + 8]
        body = data[i + 8:i + 8 + length]
        if kind == b'IHDR':
            w, h, depth, ctype, _comp, _filt, interlace = struct.unpack('>IIBBBBB', body)
            if depth != 8 or interlace != 0:
                raise ValueError('unsupported PNG (depth %d, interlace %d)' % (depth, interlace))
        elif kind == b'IDAT':
            idat += body
        elif kind == b'IEND':
            break
        i += 12 + length
    raw = zlib.decompress(bytes(idat))
    nch = {0: 1, 2: 3, 4: 2, 6: 4}[ctype]
    stride = w * nch
    out = bytearray(stride * h)
    prev = bytearray(stride)
    pos = 0
    for y in range(h):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos:pos + stride])
        pos += stride
        if ftype == 1:
            for x in range(nch, stride):
                line[x] = (line[x] + line[x - nch]) & 0xff
        elif ftype == 2:
            for x in range(stride):
                line[x] = (line[x] + prev[x]) & 0xff
        elif ftype == 3:
            for x in range(stride):
                left = line[x - nch] if x >= nch else 0
                line[x] = (line[x] + ((left + prev[x]) >> 1)) & 0xff
        elif ftype == 4:
            for x in range(stride):
                a = line[x - nch] if x >= nch else 0
                b = prev[x]
                c = prev[x - nch] if x >= nch else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 0xff
        elif ftype != 0:
            raise ValueError('bad PNG filter %d' % ftype)
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return w, h, ctype, bytes(out)


def png_over_white(data):
    """Decode a PNG and composite it over opaque white, returning RGB bytes."""
    w, h, ctype, pix = decode_png(data)
    rgb = bytearray(w * h * 3)
    for i in range(w * h):
        if ctype == 6:
            r, g, b, a = pix[i * 4], pix[i * 4 + 1], pix[i * 4 + 2], pix[i * 4 + 3]
        elif ctype == 2:
            r, g, b, a = pix[i * 3], pix[i * 3 + 1], pix[i * 3 + 2], 255
        elif ctype == 4:
            r = g = b = pix[i * 2]
            a = pix[i * 2 + 1]
        else:
            r = g = b = pix[i]
            a = 255
        if a == 255:
            rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2] = r, g, b
        else:
            f = a / 255.0
            k = 255.0 * (1.0 - f)
            rgb[i * 3] = min(255, int(r * f + k + 0.5))
            rgb[i * 3 + 1] = min(255, int(g * f + k + 0.5))
            rgb[i * 3 + 2] = min(255, int(b * f + k + 0.5))
    return w, h, bytes(rgb)


# ---------------------------------------------------------------------------
# Rendering helpers
# ---------------------------------------------------------------------------

def reference_ppm(svg_text, width, height):
    """The reference's PPM bytes for an SVG source string."""
    return ref.render_svg(ref.parse_xml(svg_text), width, height).to_ppm()


def ppm_body(data):
    nl = 0
    i = 0
    while nl < 3:
        if data[i:i + 1] == b'\n':
            nl += 1
        i += 1
    return data[i:]


def resvg_rgb(svg_text, width, height):
    """Render with resvg and composite over white; returns RGB bytes."""
    svg_path = png_path = None
    try:
        fd, svg_path = tempfile.mkstemp(suffix='.svg')
        with os.fdopen(fd, 'w', encoding='utf-8') as fh:
            fh.write(svg_text)
        fd, png_path = tempfile.mkstemp(suffix='.png')
        os.close(fd)
        subprocess.run([RESVG, '-w', str(width), '-h', str(height), svg_path, png_path],
                       check=True, capture_output=True)
        with open(png_path, 'rb') as fh:
            gw, gh, rgb = png_over_white(fh.read())
        if (gw, gh) != (width, height):
            raise SystemExit('resvg produced %dx%d instead of %dx%d; the requested size '
                             'must match the view box aspect ratio' % (gw, gh, width, height))
        return rgb
    finally:
        for path in (svg_path, png_path):
            if path and os.path.exists(path):
                os.unlink(path)


def downsample(rgb, width, height, factor):
    """Box-filter an RGB image down by an integer factor."""
    ow, oh = width // factor, height // factor
    area = float(factor * factor)
    step = factor * 3
    out = bytearray(ow * oh * 3)
    for y in range(oh):
        channels = []
        for c in range(3):
            acc = [0] * ow
            for dy in range(factor):
                base = (y * factor + dy) * width * 3
                for dx in range(factor):
                    start = base + dx * 3 + c
                    acc = [a + b for a, b in zip(acc, rgb[start:start + step * ow:step])]
            channels.append(acc)
        row = y * ow * 3
        for x in range(ow):
            out[row + x * 3] = int(channels[0][x] / area + 0.5)
            out[row + x * 3 + 1] = int(channels[1][x] / area + 0.5)
            out[row + x * 3 + 2] = int(channels[2][x] / area + 0.5)
    return bytes(out)


def image_stats(a, b, pixels):
    """(mean absolute difference, percent of bad pixels, worst channel difference)."""
    total = 0
    bad = 0
    worst = 0
    for i in range(pixels):
        pbad = False
        for c in range(3):
            d = a[i * 3 + c] - b[i * 3 + c]
            if d < 0:
                d = -d
            total += d
            if d > worst:
                worst = d
            if d > 8:
                pbad = True
        if pbad:
            bad += 1
    return total / (pixels * 3.0), bad * 100.0 / pixels, worst


def cross_check(label, svg_text, oracle_text, width, height, expected_ppm, hires):
    """Compare the reference output with resvg, aborting on real disagreement."""
    ours = ppm_body(expected_ppm)
    theirs = resvg_rgb(oracle_text, width, height)
    mean, bad, worst = image_stats(ours, theirs, width * height)
    if mean > DIRECT_MAX_MEAN or bad > DIRECT_MAX_BAD_PCT or worst > DIRECT_MAX_DIFF:
        raise SystemExit('oracle mismatch (direct) for %s at %dx%d: '
                         'mean=%.3f bad=%.2f%% worst=%d'
                         % (label, width, height, mean, bad, worst))
    if not hires:
        return mean, bad, worst
    k = HIRES_SCALE
    big_ours = ppm_body(reference_ppm(svg_text, width * k, height * k))
    big_theirs = resvg_rgb(oracle_text, width * k, height * k)
    small_ours = downsample(big_ours, width * k, height * k, k)
    small_theirs = downsample(big_theirs, width * k, height * k, k)
    hmean, hbad, hworst = image_stats(small_ours, small_theirs, width * height)
    if hmean > HIRES_MAX_MEAN or hbad > HIRES_MAX_BAD_PCT or hworst > HIRES_MAX_DIFF:
        raise SystemExit('oracle mismatch (supersampled) for %s at %dx%d: '
                         'mean=%.3f bad=%.2f%% worst=%d'
                         % (label, width, height, hmean, hbad, hworst))
    return mean, bad, worst


# ---------------------------------------------------------------------------
# Hand-written cases
# ---------------------------------------------------------------------------

HEAD = ('<svg xmlns="http://www.w3.org/2000/svg" '
        'xmlns:xlink="http://www.w3.org/1999/xlink" ')

HAND = {}

HAND['flat_rect'] = HEAD + '''viewBox="0 0 8 4" width="8" height="4">
  <rect x="1" y="1" width="3.5" height="2" fill="#0000ff"/>
</svg>'''

HAND['crisp_frame'] = HEAD + '''viewBox="0 0 10 10" width="10" height="10">
  <g transform="scale(2)">
    <rect x="1" y="1" width="3" height="3" fill="none" stroke="black" stroke-width="1"/>
  </g>
</svg>'''

HAND['basic_shapes'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <rect x="5" y="5" width="40" height="30" fill="#2980b9"/>
  <circle cx="70" cy="20" r="15" fill="#c0392b"/>
  <ellipse cx="120" cy="20" rx="25" ry="12" fill="#27ae60"/>
  <line x1="155" y1="5" x2="195" y2="35" stroke="#8e44ad" stroke-width="4"/>
  <polyline points="5,55 25,90 45,55 65,90" fill="none" stroke="#d35400" stroke-width="3"/>
  <polygon points="90,55 115,60 110,90 80,85" fill="#16a085"/>
  <polygon points="130,55 155,60 150,90 125,85" fill="#f1c40f" stroke="#7f8c8d" stroke-width="2"/>
  <polyline points="165,55 195,60 190,90" fill="#95a5a6"/>
</svg>'''

HAND['rounded_rect'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <rect x="5" y="5" width="50" height="40" rx="10" ry="10" fill="#2c3e50"/>
  <rect x="65" y="5" width="50" height="40" rx="20" fill="#e74c3c"/>
  <rect x="125" y="5" width="50" height="40" ry="18" fill="#3498db"/>
  <rect x="5" y="55" width="50" height="40" rx="40" ry="8" fill="#27ae60"/>
  <rect x="65" y="55" width="50" height="40" rx="6" ry="60" fill="#9b59b6"/>
  <rect x="125" y="55" width="60" height="40" rx="14" ry="14" fill="none"
        stroke="#e67e22" stroke-width="6"/>
</svg>'''

HAND['path_lines'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <path d="M10,10 L60,10 L60,40 L10,40 Z" fill="#2980b9"/>
  <path d="m70 10 l50 0 l0 30 l-50 0 z" fill="#27ae60"/>
  <path d="M130 10 H190 V40 H130 Z" fill="#c0392b"/>
  <path d="M10 55 h30 v10 h20 v-10 h30 v30 h-80 z" fill="#8e44ad" fill-rule="evenodd"/>
  <path d="M110,55 130,55 130,95 Z M140,55 160,55 160,95 Z" fill="#e67e22"/>
  <path d="M170 55 L195 55 L195 95 L170 95" fill="#16a085" stroke="#2c3e50" stroke-width="3"/>
</svg>'''

HAND['path_curves'] = HEAD + '''viewBox="0 0 200 120" width="200" height="120">
  <path d="M10 60 C 30 10, 60 10, 80 60 S 130 110, 150 60" fill="none"
        stroke="#16a085" stroke-width="4"/>
  <path d="M10 100 Q 40 60 70 100 T 130 100 T 190 100" fill="none"
        stroke="#d35400" stroke-width="4"/>
  <path d="M120 10 C 150 10 190 30 190 55 C 190 40 160 20 120 30 Z" fill="#8e44ad"/>
  <path d="M20 15 q 15 -10 30 0 q 15 10 30 0 l 0 25 l -60 0 z" fill="#2980b9"/>
  <path d="M150,110c10,-20 30,-20 40,0z" fill="#c0392b"/>
  <path d="M95 15 S 115 5 115 35 Z" fill="#7f8c8d"/>
  <path d="M95 45 T 115 55 T 95 65 Z" fill="#34495e"/>
</svg>'''

HAND['path_arcs'] = HEAD + '''viewBox="0 0 200 120" width="200" height="120">
  <g fill="none" stroke="#1a7f37" stroke-width="3">
    <path d="M20 60 A 30 20 0 0 0 80 60"/>
    <path d="M20 60 A 30 20 0 0 1 80 60"/>
    <path d="M20 60 A 30 20 0 1 0 80 60"/>
    <path d="M20 60 A 30 20 0 1 1 80 60"/>
  </g>
  <path d="M110 30 a 25 15 30 1 1 50 20 z" fill="#f0a030" stroke="#804000" stroke-width="2"/>
  <path d="M110 90 A 0 0 0 0 1 160 100 L 160 110 Z" fill="#3050a0"/>
  <path d="M20 105 A 5 5 0 0 1 60 105" fill="none" stroke="#a03050" stroke-width="4"/>
  <path d="M170 20 A 4 8 -45 0 1 190 40 A 4 8 -45 0 1 170 20 Z" fill="#555"/>
  <path d="M90 15 A 1 1 0 0 1 90 15 L 100 15 Z" fill="#111"/>
</svg>'''

HAND['arc_flags'] = HEAD + '''viewBox="0 0 100 50" width="100" height="50">
  <path d="M10 25a10 10 0 0110 0a10 10 0 01-10 10z" fill="#2980b9"/>
  <path d="M45 10A15 15 0 1170 25L45 25Z" fill="#c0392b"/>
  <path d="M80 40a5 5 0 105-15" fill="none" stroke="#27ae60" stroke-width="2"/>
  <path d="M5 5a3 3 0 113 3a3 3 0 11-3-3z" fill="#8e44ad"/>
</svg>'''

HAND['fill_rule'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <path fill="#8e44ad" fill-rule="nonzero" d="M50 10 L78 90 L10 40 L90 40 L22 90 Z"/>
  <path fill="#16a085" fill-rule="evenodd" d="M150 10 L178 90 L110 40 L190 40 L122 90 Z"/>
  <path fill="#e67e22" fill-rule="evenodd" d="M10 95 h40 v-8 h-40 z M20 93 h20 v-4 h-20 z"/>
  <path fill="#2c3e50" d="M60 95 h40 v-8 h-40 z M70 93 h20 v-4 h-20 z"/>
  <path fill="#c0392b" fill-rule="evenodd"
        d="M110 95 h40 v-8 h-40 z M150 93 h-20 v-4 h20 z"/>
</svg>'''

HAND['colors'] = HEAD + '''viewBox="0 0 200 60" width="200" height="60">
  <rect x="0" y="0" width="25" height="60" fill="mediumpurple"/>
  <rect x="25" y="0" width="25" height="60" fill="#f39"/>
  <rect x="50" y="0" width="25" height="60" fill="#12AB78"/>
  <rect x="75" y="0" width="25" height="60" fill="rgb(10, 200, 30)"/>
  <rect x="100" y="0" width="25" height="60" fill="rgb(20%, 45%, 90%)"/>
  <rect x="125" y="0" width="25" height="60" fill="DarkSlateGray" fill-opacity="0.35"/>
  <rect x="150" y="0" width="25" height="60" fill="none" stroke="teal" stroke-width="6"/>
  <rect x="175" y="0" width="25" height="60" style="fill:tomato;fill-opacity:60%"/>
  <g color="#ff7f00">
    <rect x="10" y="20" width="15" height="20" fill="currentColor"/>
    <rect x="60" y="20" width="15" height="20" fill="none" stroke="currentColor"
          stroke-width="4"/>
  </g>
</svg>'''

HAND['opacity'] = HEAD + '''viewBox="0 0 200 120" width="200" height="120">
  <rect width="200" height="120" fill="#fdf3d0"/>
  <g opacity="0.5">
    <circle cx="50" cy="40" r="30" fill="#e74c3c"/>
    <circle cx="80" cy="40" r="30" fill="#2980b9"/>
  </g>
  <circle cx="140" cy="40" r="30" fill="#e74c3c" opacity="0.5"/>
  <circle cx="170" cy="40" r="30" fill="#2980b9" opacity="0.5"/>
  <rect x="10" y="80" width="80" height="15" fill="#111" fill-opacity="0.25"/>
  <rect x="110" y="80" width="80" height="15" fill="none" stroke="#111"
        stroke-width="8" stroke-opacity="0.4"/>
  <g opacity="0.6">
    <rect x="10" y="78" width="30" height="4" fill="#006400" stroke="#8b0000"
          stroke-width="4"/>
  </g>
  <rect x="120" y="78" width="30" height="4" fill="#006400" stroke="#8b0000"
        stroke-width="4" opacity="0.6"/>
  <rect x="8" y="100" width="30" height="16" fill="#2980b9" fill-opacity="bogus"/>
  <rect x="46" y="100" width="30" height="16" fill="#2980b9" opacity="nope"/>
  <rect x="84" y="100" width="30" height="16" fill="#2980b9" fill-opacity="50%"/>
  <rect x="122" y="100" width="30" height="16" fill="#2980b9" fill-opacity="1.5"/>
  <rect x="160" y="100" width="30" height="16" fill="#2980b9" fill-opacity="-0.2"/>
  <rect x="160" y="100" width="30" height="16" fill="none" stroke="#2980b9"
        stroke-width="3" stroke-opacity="not-a-number"/>
</svg>'''

HAND['transforms'] = HEAD + '''viewBox="0 0 240 120" width="240" height="120">
  <g transform="translate(10,10)">
    <rect width="40" height="30" fill="#2980b9"/>
    <rect width="40" height="30" fill="#27ae60" transform="translate(50 5) scale(1.5 0.8)"/>
    <rect width="40" height="30" fill="#c0392b" transform="rotate(25 30 20) translate(110 0)"/>
  </g>
  <g transform="matrix(1 0.15 -0.2 1 20 60)">
    <circle cx="30" cy="20" r="18" fill="#8e44ad" fill-opacity="0.7"/>
    <rect x="60" y="0" width="40" height="40" fill="none" stroke="#e67e22"
          stroke-width="5" transform="skewX(-20)"/>
    <polygon points="130,0 170,10 150,40" fill="#16a085" transform="skewY(12) rotate(-10)"/>
  </g>
  <g transform="scale(0.5)">
    <rect x="380" y="180" width="80" height="40" fill="#555" transform="rotate(45)"/>
  </g>
  <rect x="200" y="5" width="30" height="20" fill="#2c3e50"
        transform="translate(10,10),scale(0.8) rotate(-15)"/>
</svg>'''

HAND['viewbox'] = HEAD + '''viewBox="-10 -5 60 30" width="120" height="60">
  <rect x="-10" y="-5" width="60" height="30" fill="#eef3f7"/>
  <circle cx="0" cy="0" r="6" fill="#c0392b"/>
  <circle cx="50" cy="25" r="6" fill="#27ae60"/>
  <rect x="10" y="5" width="20" height="10" fill="none" stroke="#2c3e50" stroke-width="1.5"/>
  <path d="M35 0 L45 0 L40 10 Z" fill="#8e44ad"/>
</svg>'''

HAND['viewbox_numbers'] = HEAD + '''viewBox="0,0,20,20,1" width="40" height="40">
  <rect x="0" y="0" width="20" height="20" fill="#eef3f7"/>
  <circle cx="5" cy="5" r="4" fill="#c0392b"/>
  <rect x="11" y="11" width="7" height="7" fill="none" stroke="#2c3e50" stroke-width="1"/>
  <path d="M2 18 L10 9 L18 18 Z" fill="#27ae60" fill-opacity="0.7"/>
</svg>'''

HAND['intrinsic_size'] = HEAD + '''width="80" height="40">
  <rect width="80" height="40" fill="#fff8e1"/>
  <polygon points="0,40 20,5 40,40" fill="#ef6c00"/>
  <polygon points="40,40 60,15 80,40" fill="#6d4c41"/>
  <circle cx="68" cy="10" r="6" fill="#ffd54f"/>
</svg>'''

HAND['stroke_caps'] = HEAD + '''viewBox="0 0 120 80" width="120" height="80">
  <g stroke="#2266cc" stroke-width="12" fill="none">
    <path d="M20 15 L100 15" stroke-linecap="butt"/>
    <path d="M20 40 L100 40" stroke-linecap="round"/>
    <path d="M20 65 L100 65" stroke-linecap="square"/>
  </g>
  <path d="M10 10 L10 10" stroke="red" stroke-width="10" stroke-linecap="round" fill="none"/>
  <path d="M110 70 L110 70" stroke="green" stroke-width="10" stroke-linecap="square"
        fill="none"/>
  <path d="M60 70 L60 70" stroke="#000" stroke-width="10" stroke-linecap="butt" fill="none"/>
</svg>'''

HAND['stroke_joins'] = HEAD + '''viewBox="0 0 160 90" width="160" height="90">
  <g fill="none" stroke="#333" stroke-width="10">
    <polyline points="10,60 30,20 50,60" stroke-linejoin="miter"/>
    <polyline points="60,60 80,20 100,60" stroke-linejoin="round"/>
    <polyline points="110,60 130,20 150,60" stroke-linejoin="bevel"/>
  </g>
  <g fill="none" stroke="#c0392b" stroke-width="8" stroke-linejoin="miter">
    <polyline points="20,80 40,73 60,80" stroke-miterlimit="1.2"/>
    <polyline points="100,80 120,73 140,80" stroke-miterlimit="10"/>
  </g>
  <polygon points="15,15 45,15 30,35" fill="none" stroke="#27ae60" stroke-width="7"
           stroke-linejoin="miter"/>
  <path d="M100 10 L130 10 L115 30 Z" fill="none" stroke="#8e44ad" stroke-width="7"
        stroke-linejoin="round"/>
  <path d="M60 30 L80 30 L60 30" fill="none" stroke="#e67e22" stroke-width="9"
        stroke-linejoin="round" stroke-linecap="butt"/>
</svg>'''

HAND['stroke_shapes'] = HEAD + '''viewBox="0 0 200 120" width="200" height="120">
  <g transform="translate(10 10) scale(3 1)">
    <circle cx="10" cy="15" r="8" fill="none" stroke="#c0392b" stroke-width="3"/>
    <rect x="25" y="8" width="20" height="14" fill="#ecf0f1" stroke="#2c3e50" stroke-width="2"/>
  </g>
  <g transform="rotate(20 100 70)">
    <polygon points="70,55 130,55 130,85 70,85" fill="none" stroke="#8e44ad"
             stroke-width="9" stroke-linejoin="miter"/>
  </g>
  <line x1="10" y1="50" x2="190" y2="51" stroke="#111" stroke-width="0.4"/>
  <line x1="10" y1="55" x2="190" y2="55" stroke="#111" stroke-width="0.15"/>
  <path d="M10 100 C 40 60, 70 140, 100 100 S 160 60, 190 110" fill="none"
        stroke="#16a085" stroke-width="6" stroke-linecap="round"/>
  <ellipse cx="40" cy="80" rx="25" ry="10" fill="none" stroke="#e67e22" stroke-width="4"
           transform="rotate(-30 40 80)"/>
</svg>'''

HAND['inheritance'] = HEAD + '''viewBox="0 0 160 80" width="160" height="80"
     fill="#34495e" stroke="#e67e22" stroke-width="3">
  <g fill="#1abc9c" stroke-linejoin="round">
    <rect x="10" y="10" width="40" height="25"/>
    <g stroke-width="6" stroke="#8e44ad">
      <rect x="60" y="10" width="40" height="25"/>
      <rect x="110" y="10" width="40" height="25" fill="navy"
            style="fill:#f1c40f;stroke-width:1"/>
    </g>
  </g>
  <g style="fill:none;stroke:#2c3e50;stroke-width:4;stroke-linecap:round">
    <polyline points="15,50 45,70 75,50"/>
    <polyline points="90,50 120,70 150,50" style="stroke-linecap:butt"/>
  </g>
</svg>'''

HAND['style_attr'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <rect x="5" y="5" width="40" height="30" style="fill:#2980b9"/>
  <rect x="55" y="5" width="40" height="30" fill="#c0392b" style="fill : #27ae60 ; "/>
  <rect x="105" y="5" width="40" height="30" style="fill:#8e44ad;;opacity:0.4;"/>
  <rect x="155" y="5" width="40" height="30" fill="#16a085" opacity="0.9"
        style="opacity:0.3"/>
  <path d="M10 55 L90 55 L50 95 Z"
        style="fill:none;stroke:#d35400;stroke-width:6;stroke-linejoin:bevel"/>
  <path d="M110 55 L190 55 L150 95 Z" fill="#f1c40f" fill-opacity="1"
        style="fill-opacity:0.45;fill-rule:evenodd"/>
  <g style="stroke:#2c3e50;stroke-width:2">
    <circle cx="100" cy="75" r="12" style="fill:#ecf0f1"/>
  </g>
</svg>'''

HAND['defs_use'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <defs>
    <circle id="dot" cx="0" cy="0" r="8" fill="#d35400"/>
    <g id="pair">
      <rect x="-10" y="-6" width="20" height="12" fill="#2c3e50"/>
      <rect x="-4" y="-14" width="8" height="8" fill="#e74c3c"/>
    </g>
    <path id="tick" d="M-6 0 L-2 5 L6 -6" fill="none" stroke="#27ae60" stroke-width="3"
          stroke-linecap="round"/>
    <rect id="plain" x="-8" y="-8" width="16" height="16"/>
  </defs>
  <use href="#dot" x="20" y="20"/>
  <use href="#dot" x="50" y="20" fill="#3498db"/>
  <use xlink:href="#pair" x="100" y="30"/>
  <use href="#pair" x="160" y="30" transform="rotate(20 160 30)"/>
  <use href="#tick" x="40" y="70"/>
  <use href="#tick" x="120" y="70" transform="scale(2 2) translate(-30 0)"/>
  <use href="#plain" x="80" y="80" fill="#9b59b6"/>
  <use href="#missing" x="10" y="90"/>
</svg>'''

HAND['display'] = HEAD + '''viewBox="0 0 200 60" width="200" height="60">
  <rect width="200" height="60" fill="#f4f6f7"/>
  <g display="none"><rect x="0" y="0" width="60" height="60" fill="#f00"/></g>
  <rect x="10" y="10" width="30" height="40" fill="#2980b9" style="display:none"/>
  <rect x="50" y="10" width="30" height="40" fill="#27ae60"/>
  <rect x="90" y="10" width="20" height="40" fill="#f39c12" opacity="0"/>
  <g display="none"><g display="inline"><circle cx="20" cy="30" r="10" fill="#000"/></g></g>
  <rect x="120" y="10" width="30" height="40" fill="#8e44ad" display="none"
        style="display:inline"/>
  <rect x="160" y="10" width="30" height="40" fill="#c0392b" display="inline"
        style="display:none"/>
</svg>'''

HAND['path_edge_cases'] = HEAD + '''viewBox="0 0 200 112" width="200" height="112">
  <path d="" fill="#000"/>
  <path d="M10 10" fill="#000"/>
  <path d="M10,10 20,40 40,10z" fill="#2980b9"/>
  <path d="m50 10l20 30 20-30z" fill="#27ae60"/>
  <path d="M100 10 H140 V40 H100 Z" fill="#c0392b"/>
  <path d="M150 10 h40 v30 h-40 z" fill="#8e44ad" fill-opacity=".5"/>
  <path d="M10 60 S 30 45 50 60 T 90 60" fill="none" stroke="#16a085" stroke-width="3"/>
  <path d="M100,60C110,45 120,75 130,60S150,45 160,60" fill="none" stroke="#d35400"
        stroke-width="3"/>
  <path d="M.5 90 L 1e1 95 L 20.5.5e2 Z" fill="#555"/>
  <path d="M170 60 q 10 -20 20 0 t 10 20" fill="none" stroke="#7f8c8d" stroke-width="2"/>
  <path d="M40 80 L60 80 L60 95 Z M70 80 L90 80 L90 95 Z" fill="#e67e22"/>
  <path d="M110 80 L130 80 L130 95 Z L 140 95 Z" fill="#2c3e50"/>
  <path d="M150 80 L 170 80 L 170 95 L 150 95 bogus L 10 10" fill="#95a5a6"/>
  <path d="M5 102 L35 102 L35 110 Z 5 5" fill="#16a085"/>
  <path d="M45 102 L75 102 L75 110 z 12 4 L 95 110" fill="#8e44ad"/>
  <path d="M105 102 L135 102 L135 110 Z M145 102 L175 102 L175 110 Z" fill="#2c3e50"/>
</svg>'''

HAND['degenerate'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <rect x="10" y="10" width="0" height="30" fill="#000"/>
  <rect x="20" y="10" width="30" height="0" fill="#000"/>
  <circle cx="60" cy="25" r="0" fill="#000"/>
  <ellipse cx="80" cy="25" rx="0" ry="10" fill="#000"/>
  <line x1="100" y1="10" x2="100" y2="40" stroke="#000" stroke-width="0"/>
  <polyline points="" fill="#000"/>
  <polygon points="120,10" fill="#000"/>
  <rect x="-500" y="-500" width="100" height="100" fill="#f00"/>
  <rect x="150" y="10" width="30" height="30" fill="#3498db" transform="scale(0)"/>
  <rect x="10" y="60" width="40" height="30" rx="25" ry="40" fill="#9b59b6"/>
  <rect x="60" y="60" width="40" height="30" rx="8" fill="#2ecc71"/>
  <rect x="110" y="60" width="40" height="30" ry="8" fill="#e74c3c"/>
  <rect x="160" y="60" width="30" height="30" rx="-5" fill="#34495e"/>
  <polygon points="130,15 140,15 135,25 130,15 130,15" fill="#e67e22"/>
  <path d="M170 45 L 170 45 Z" fill="#000" stroke="#111" stroke-width="3"
        stroke-linecap="round"/>
</svg>'''

HAND['stroke_reversal'] = HEAD + '''viewBox="0 0 200 100" width="200" height="100">
  <path d="M12 85 L12 30 L12 85 L47 85 L47 30 L47 85 L82 85 L82 30 L82 85 L117 85 L117 30 L117 85 L152 85 L152 30 L152 85 L187 85 L187 30 L187 85" fill="none" stroke="#2980b9" stroke-width="11"
        stroke-linejoin="round" stroke-linecap="butt"/>
  <path d="M25.00 18.00 L39.50 24.76 L25.00 18.00" fill="none" stroke="#c0392b"
        stroke-width="9" stroke-linejoin="round" stroke-linecap="butt"/>
  <path d="M73.00 18.00 L78.47 33.04 L73.00 18.00" fill="none" stroke="#c0392b"
        stroke-width="9" stroke-linejoin="round" stroke-linecap="butt"/>
  <path d="M121.00 18.00 L114.24 32.50 L121.00 18.00" fill="none" stroke="#c0392b"
        stroke-width="9" stroke-linejoin="round" stroke-linecap="butt"/>
  <path d="M169.00 18.00 L153.96 23.47 L169.00 18.00" fill="none" stroke="#c0392b"
        stroke-width="9" stroke-linejoin="round" stroke-linecap="butt"/>
</svg>'''


HAND['arc_precision'] = HEAD + '''viewBox="0 0 256 256" width="256" height="256">
  <rect width="256" height="256" fill="#fbfbfb"/>
  <circle cx="128" cy="128" r="16" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="22" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="28" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="34" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="40" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="46" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="52" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="58" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="64" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="70" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="76" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="82" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="88" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="94" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="100" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="106" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="112" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="118" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <circle cx="128" cy="128" r="124" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <rect x="4" y="4" width="248" height="248" rx="124" ry="124" fill="none"
        stroke="#c0392b" stroke-width="1.5"/>
  <rect x="13" y="13" width="230" height="230" rx="115" ry="115" fill="none"
        stroke="#c0392b" stroke-width="1.5"/>
  <rect x="22" y="22" width="212" height="212" rx="106" ry="106" fill="none"
        stroke="#c0392b" stroke-width="1.5"/>
  <rect x="31" y="31" width="194" height="194" rx="97" ry="97" fill="none"
        stroke="#c0392b" stroke-width="1.5"/>
  <rect x="40" y="40" width="176" height="176" rx="88" ry="88" fill="none"
        stroke="#c0392b" stroke-width="1.5"/>
  <rect x="49" y="49" width="158" height="158" rx="79" ry="79" fill="none"
        stroke="#c0392b" stroke-width="1.5"/>
  <path d="M10 128 A 118 118 0 1 1 246 128" fill="none" stroke="#16a085"
        stroke-width="1.5"/>
  <path d="M32 128 A 96 96 0 1 1 224 128" fill="none" stroke="#16a085"
        stroke-width="1.5"/>
  <path d="M54 128 A 74 74 0 1 1 202 128" fill="none" stroke="#16a085"
        stroke-width="1.5"/>
  <path d="M76 128 A 52 52 0 1 1 180 128" fill="none" stroke="#16a085"
        stroke-width="1.5"/>
  <ellipse cx="128" cy="128" rx="122" ry="40" fill="none" stroke="#8e44ad"
        stroke-width="1.5"/>
  <ellipse cx="128" cy="128" rx="122" ry="64" fill="none" stroke="#8e44ad"
        stroke-width="1.5"/>
  <ellipse cx="128" cy="128" rx="122" ry="88" fill="none" stroke="#8e44ad"
        stroke-width="1.5"/>
</svg>'''


# The view box is stretched to the requested size, which here has a different
# aspect ratio. resvg always fits preserving the aspect ratio, so the oracle
# gets the equivalent document built by stretch_oracle().
STRETCH_BODY = '''<rect x="0" y="0" width="40" height="20" fill="#ecf0f1"/>
  <circle cx="10" cy="10" r="8" fill="#e74c3c"/>
  <rect x="24" y="4" width="12" height="12" fill="none" stroke="#2c3e50" stroke-width="2"/>
  <path d="M20 2 L28 18 L12 18 Z" fill="#27ae60" fill-opacity="0.6"/>'''

HAND['stretch'] = HEAD + 'viewBox="0 0 40 20" width="40" height="20">\n  ' \
    + STRETCH_BODY + '\n</svg>'


def stretch_oracle(width, height):
    """An aspect-preserving document that renders exactly like the stretched one."""
    sx = width / 40.0
    sy = height / 20.0
    return (HEAD + 'viewBox="0 0 %d %d" width="%d" height="%d">\n'
            '  <g transform="scale(%.12f %.12f)">%s</g>\n</svg>'
            % (width, height, width, height, sx, sy, STRETCH_BODY))


# ---------------------------------------------------------------------------
# Generated illustrations
# ---------------------------------------------------------------------------

class Rng:
    """A small deterministic linear congruential generator."""

    def __init__(self, seed):
        self.state = seed & 0xffffffff

    def next(self):
        self.state = (1103515245 * self.state + 12345) & 0x7fffffff
        return self.state

    def below(self, n):
        return self.next() % n

    def pick(self, items):
        return items[self.next() % len(items)]

    def between(self, lo, hi):
        return lo + (hi - lo) * (self.next() / 2147483647.0)


def mandala_svg():
    """Concentric rings of petals: arcs, rotations, even-odd annuli, strokes."""
    rng = Rng(20240117)
    out = [HEAD + 'viewBox="0 0 200 200" width="200" height="200">',
           '<rect width="200" height="200" fill="#fdf6e3"/>',
           '<circle cx="100" cy="100" r="96" fill="#fef9ec" stroke="#b58900" stroke-width="1.5"/>']
    rings = [(92, 36, '#268bd2', 7.5), (74, 24, '#2aa198', 9.0),
             (58, 18, '#d33682', 10.0), (42, 12, '#859900', 12.0)]
    for radius, count, colour, half in rings:
        for i in range(count):
            angle = 360.0 * i / count
            tip = radius
            base = radius - half * 1.7
            out.append(
                '<path transform="rotate(%.4f 100 100)" fill="%s" fill-opacity="%.2f" '
                'stroke="#073642" stroke-width="0.4" stroke-linejoin="round" '
                'd="M100 %.3f C %.3f %.3f %.3f %.3f 100 %.3f C %.3f %.3f %.3f %.3f 100 %.3f Z"/>'
                % (angle, colour, 0.55 + 0.35 * ((i % 3) / 2.0),
                   100 - tip, 100 + half, 100 - tip + half, 100 + half * 0.6,
                   100 - base, 100 - base,
                   100 - half * 0.6, 100 - base, 100 - half, 100 - tip + half, 100 - tip))
    # even-odd annuli
    for radius, width in ((36, 4), (28, 2.5), (20, 3)):
        out.append('<path fill="#cb4b16" fill-rule="evenodd" d="'
                   'M%.3f 100 A %.3f %.3f 0 1 0 %.3f 100 A %.3f %.3f 0 1 0 %.3f 100 Z '
                   'M%.3f 100 A %.3f %.3f 0 1 0 %.3f 100 A %.3f %.3f 0 1 0 %.3f 100 Z"/>'
                   % (100 - radius, radius, radius, 100 + radius, radius, radius, 100 - radius,
                      100 - radius + width, radius - width, radius - width,
                      100 + radius - width, radius - width, radius - width,
                      100 - radius + width))
    for i in range(24):
        angle = 360.0 * i / 24 + 7.5
        out.append('<line transform="rotate(%.4f 100 100)" x1="100" y1="40" x2="100" y2="16" '
                   'stroke="%s" stroke-width="%.2f" stroke-linecap="round"/>'
                   % (angle, rng.pick(['#b58900', '#6c71c4', '#dc322f']), rng.between(0.6, 2.2)))
    out.append('<circle cx="100" cy="100" r="12" fill="#073642"/>')
    out.append('<circle cx="100" cy="100" r="6" fill="#fdf6e3"/>')
    out.append('</svg>')
    return '\n'.join(out)


def skyline_svg():
    """A city at night: many small rectangles, a crescent, curved birds."""
    rng = Rng(777001)
    out = [HEAD + 'viewBox="0 0 240 160" width="240" height="160">',
           '<rect width="240" height="160" fill="#101a3a"/>',
           '<rect y="0" width="240" height="70" fill="#1b2a5e" fill-opacity="0.8"/>']
    for _ in range(90):
        x = rng.between(2, 238)
        y = rng.between(2, 96)
        r = rng.between(0.3, 1.1)
        out.append('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="#ffffff" fill-opacity="%.2f"/>'
                   % (x, y, r, rng.between(0.3, 1.0)))
    out.append('<path fill="#f7e9a0" fill-rule="evenodd" d="M196 26 m -16 0 '
               'a 16 16 0 1 0 32 0 a 16 16 0 1 0 -32 0 Z '
               'M190 18 m -14 0 a 14 14 0 1 0 28 0 a 14 14 0 1 0 -28 0 Z"/>')
    x = -6.0
    while x < 240:
        w = rng.between(14, 30)
        h = rng.between(34, 96)
        top = 148 - h
        shade = rng.pick(['#243157', '#2c3a66', '#1d2749', '#33416f'])
        out.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" fill="%s" '
                   'stroke="#0d1430" stroke-width="0.6"/>' % (x, top, w, h, shade))
        if rng.below(3) == 0:
            out.append('<polygon points="%.2f,%.2f %.2f,%.2f %.2f,%.2f" fill="%s"/>'
                       % (x, top, x + w / 2.0, top - rng.between(6, 16), x + w, top, shade))
        wy = top + 4
        while wy < 142:
            wx = x + 3
            while wx < x + w - 4:
                if rng.below(5) != 0:
                    lit = rng.below(3) != 0
                    out.append('<rect x="%.2f" y="%.2f" width="2.4" height="3.2" fill="%s" '
                               'fill-opacity="%.2f"/>'
                               % (wx, wy, '#ffe9a8' if lit else '#16203f',
                                  0.95 if lit else 0.8))
                wx += 4.6
            wy += 6.0
        x += w + rng.between(1, 5)
    out.append('<rect x="0" y="146" width="240" height="14" fill="#0a1028"/>')
    for i in range(7):
        bx = 12 + i * 33.0
        out.append('<path d="M%.1f 150 q 4 -7 8 0" fill="none" stroke="#3a4a80" '
                   'stroke-width="1.2" stroke-linecap="round"/>' % bx)
    for i in range(5):
        bx = 30 + i * 38.0
        by = 30 + (i % 3) * 11.0
        out.append('<path d="M%.1f %.1f q 4 -4 8 0 q 4 -4 8 0" fill="none" stroke="#cdd6f4" '
                   'stroke-width="1" stroke-linecap="round" stroke-linejoin="round"/>' % (bx, by))
    out.append('</svg>')
    return '\n'.join(out)


def gear(cx, cy, outer, inner, teeth, hole, colour, stroke, rotation):
    """One gear as an even-odd path plus spokes."""
    parts = []
    step = 2.0 * math.pi / teeth
    d = []
    for i in range(teeth):
        a0 = i * step
        a1 = a0 + step * 0.32
        a2 = a0 + step * 0.5
        a3 = a0 + step * 0.82
        pts = [(inner, a0), (outer, a1), (outer, a2), (inner, a3)]
        for j, (r, a) in enumerate(pts):
            x = cx + r * math.cos(a)
            y = cy + r * math.sin(a)
            d.append('%s%.3f %.3f' % ('M' if (i == 0 and j == 0) else 'L', x, y))
    d.append('Z')
    d.append('M%.3f %.3f A %.3f %.3f 0 1 0 %.3f %.3f A %.3f %.3f 0 1 0 %.3f %.3f Z'
             % (cx - hole, cy, hole, hole, cx + hole, cy, hole, hole, cx - hole, cy))
    parts.append('<path transform="rotate(%.4f %.2f %.2f)" fill="%s" fill-rule="evenodd" '
                 'stroke="%s" stroke-width="0.8" stroke-linejoin="round" d="%s"/>'
                 % (rotation, cx, cy, colour, stroke, ' '.join(d)))
    for i in range(6):
        a = math.radians(rotation + i * 60.0)
        parts.append('<line x1="%.3f" y1="%.3f" x2="%.3f" y2="%.3f" stroke="%s" '
                     'stroke-width="2.4" stroke-linecap="round"/>'
                     % (cx + hole * math.cos(a), cy + hole * math.sin(a),
                        cx + inner * 0.85 * math.cos(a), cy + inner * 0.85 * math.sin(a),
                        stroke))
    return parts


def gears_svg():
    """Interlocking gears: many teeth, even-odd holes, rotations, strokes."""
    out = [HEAD + 'viewBox="0 0 200 200" width="200" height="200">',
           '<rect width="200" height="200" fill="#eceff1"/>']
    out += gear(70, 78, 46, 38, 18, 13, '#607d8b', '#263238', 0.0)
    out += gear(138, 62, 30, 24, 12, 8, '#ef6c00', '#4e342e', 7.0)
    out += gear(126, 140, 38, 31, 15, 10, '#00897b', '#004d40', -4.0)
    out += gear(42, 158, 24, 19, 10, 6, '#8e24aa', '#4a148c', 11.0)
    out.append('<g fill="none" stroke="#37474f" stroke-width="1.2" stroke-linecap="round">')
    out.append('<path d="M10 190 C 60 150 150 190 190 150"/>')
    out.append('<path d="M10 10 Q 100 40 190 10"/>')
    out.append('</g>')
    out.append('<g opacity="0.45">')
    for i in range(10):
        out.append('<circle cx="%.1f" cy="%.1f" r="%.1f" fill="none" stroke="#b0bec5" '
                   'stroke-width="1.5"/>' % (20 + i * 18.0, 100 + 40 * math.sin(i * 0.7),
                                             4 + (i % 4) * 2.0))
    out.append('</g>')
    out.append('</svg>')
    return '\n'.join(out)


def chart_svg():
    """A dashboard panel: grids, areas, markers, reused glyphs, group opacity."""
    rng = Rng(31337)
    out = [HEAD + 'viewBox="0 0 240 150" width="240" height="150">',
           '<defs>',
           '<circle id="mark" cx="0" cy="0" r="2.6" fill="#ffffff" stroke="#263238"'
           ' stroke-width="1.2"/>',
           '<rect id="swatch" x="0" y="0" width="8" height="8" rx="2" ry="2"/>',
           '</defs>',
           '<rect width="240" height="150" fill="#fafafa"/>',
           '<rect x="24" y="12" width="200" height="100" fill="#ffffff" stroke="#cfd8dc"'
           ' stroke-width="1"/>']
    for i in range(11):
        y = 12 + i * 10.0
        out.append('<line x1="24" y1="%.1f" x2="224" y2="%.1f" stroke="#eceff1" '
                   'stroke-width="0.8"/>' % (y, y))
    for i in range(11):
        x = 24 + i * 20.0
        out.append('<line x1="%.1f" y1="12" x2="%.1f" y2="112" stroke="#eceff1" '
                   'stroke-width="0.8"/>' % (x, x))
    series = [('#1e88e5', 0), ('#43a047', 1), ('#e53935', 2)]
    for colour, index in series:
        pts = []
        value = 60.0 + index * 8
        for i in range(21):
            value += rng.between(-9, 9)
            value = max(20.0, min(105.0, value))
            pts.append((24 + i * 10.0, value))
        line = ' '.join('%.2f,%.2f' % p for p in pts)
        area = 'M%.2f 112 ' % pts[0][0] + ' '.join('L%.2f %.2f' % p for p in pts) \
               + ' L%.2f 112 Z' % pts[-1][0]
        out.append('<g opacity="0.25"><path d="%s" fill="%s"/></g>' % (area, colour))
        out.append('<polyline points="%s" fill="none" stroke="%s" stroke-width="2" '
                   'stroke-linejoin="round" stroke-linecap="round"/>' % (line, colour))
        for px, py in pts[::4]:
            out.append('<use href="#mark" x="%.2f" y="%.2f"/>' % (px, py))
    for i in range(12):
        h = 6 + (i * 7) % 26
        out.append('<rect x="%.1f" y="%.1f" width="12" height="%.1f" rx="3" ry="3" '
                   'fill="#7e57c2" fill-opacity="%.2f"/>'
                   % (26 + i * 16.5, 140 - h, h, 0.45 + 0.05 * (i % 6)))
    for i, (colour, _index) in enumerate(series):
        out.append('<use href="#swatch" x="%.1f" y="118" fill="%s"/>' % (24 + i * 40.0, colour))
        out.append('<rect x="%.1f" y="120" width="26" height="4" rx="2" fill="#90a4ae"/>'
                   % (35 + i * 40.0))
    out.append('<path d="M200 118 l 8 0 l -4 8 Z" fill="#455a64"/>')
    out.append('</svg>')
    return '\n'.join(out)


# name -> (builder, view box width, view box height); render sizes are whole
# multiples of the view box so the aspect ratio always matches.
ILLUSTRATIONS = {
    'mandala': (mandala_svg, 200, 200),
    'skyline': (skyline_svg, 240, 160),
    'gears': (gears_svg, 200, 200),
    'chart': (chart_svg, 240, 150),
}


# ---------------------------------------------------------------------------
# Test suite definition
# ---------------------------------------------------------------------------

def hand(test_name, *entries):
    """A test made of hand-written files; every file is checked at high resolution."""
    files = []
    for item in entries:
        key, width, height = item[0], item[1], item[2]
        oracle = item[3] if len(item) > 3 else None
        files.append(('%s_%dx%d.svg' % (key, width, height),
                      HAND[key], width, height, oracle))
    return {'name': test_name, 'files': files, 'hires_stride': 1}


def corpus(test_name, folder, size, start, stop, step, hires_stride, largest=False):
    """A test made of vendored icons: corpus/<folder> sliced deterministically.

    With `largest`, the pool is ordered by file size (biggest path data first)
    instead of by name.
    """
    folder_path = os.path.join(CORPUS, folder)
    names = sorted(f for f in os.listdir(folder_path) if f.endswith('.svg'))
    if largest:
        names.sort(key=lambda f: (-os.path.getsize(os.path.join(folder_path, f)), f))
    files = []
    for name in names[start:stop:step]:
        with open(os.path.join(CORPUS, folder, name), 'r', encoding='utf-8') as fh:
            text = fh.read()
        files.append((name, text, size, size, None))
    return {'name': test_name, 'files': files, 'hires_stride': hires_stride}


def suite():
    tests = [
        hand('001_flat_rect', ('flat_rect', 8, 4), ('crisp_frame', 40, 40)),
        hand('002_basic_shapes', ('basic_shapes', 200, 100), ('basic_shapes', 400, 200)),
        hand('003_rounded_rect', ('rounded_rect', 200, 100), ('rounded_rect', 600, 300)),
        hand('004_path_lines', ('path_lines', 200, 100), ('path_lines', 500, 250)),
        hand('005_path_curves', ('path_curves', 200, 120), ('path_curves', 500, 300)),
        hand('006_path_arcs', ('path_arcs', 200, 120), ('path_arcs', 600, 360)),
        hand('007_arc_flags', ('arc_flags', 300, 150)),
        hand('008_fill_rule', ('fill_rule', 200, 100), ('fill_rule', 480, 240)),
        hand('009_colors', ('colors', 200, 60), ('colors', 400, 120)),
        hand('010_opacity', ('opacity', 200, 120), ('opacity', 400, 240)),
        hand('011_transforms', ('transforms', 240, 120), ('transforms', 480, 240)),
        hand('012_viewbox', ('viewbox', 120, 60), ('viewbox', 360, 180),
             ('viewbox_numbers', 40, 40), ('viewbox_numbers', 120, 120)),
        hand('013_intrinsic_size', ('intrinsic_size', 80, 40), ('intrinsic_size', 320, 160)),
        hand('014_stroke_caps', ('stroke_caps', 120, 80), ('stroke_caps', 360, 240)),
        hand('015_stroke_joins', ('stroke_joins', 160, 90), ('stroke_joins', 480, 270)),
        hand('016_stroke_shapes', ('stroke_shapes', 200, 120), ('stroke_shapes', 400, 240)),
        hand('017_inheritance', ('inheritance', 160, 80), ('inheritance', 480, 240)),
        hand('018_style_attr', ('style_attr', 200, 100), ('style_attr', 400, 200)),
        hand('019_defs_use', ('defs_use', 200, 100), ('defs_use', 500, 250)),
        hand('020_display', ('display', 200, 60), ('display', 400, 120)),
        hand('021_path_edge_cases', ('path_edge_cases', 200, 112),
             ('path_edge_cases', 600, 336)),
        hand('022_degenerate', ('degenerate', 200, 100), ('degenerate', 400, 200)),
        hand('023_stretch',
             ('stretch', 160, 40, stretch_oracle(160, 40)),
             ('stretch', 80, 120, stretch_oracle(80, 120))),
    ]

    mixed = []
    for key, width, height in (('basic_shapes', 120, 60), ('opacity', 300, 180),
                               ('stroke_joins', 96, 54), ('defs_use', 160, 80),
                               ('viewbox', 240, 120), ('path_arcs', 100, 60)):
        mixed.append(('%s_%dx%d.svg' % (key, width, height), HAND[key], width, height, None))
    tests.append({'name': '024_multi_file', 'files': mixed, 'hires_stride': 1})

    tests.append(corpus('025_feather_icons_64', 'feather', 64, 0, 256, 1, 5))
    tests.append(corpus('026_feather_icons_256', 'feather', 256, 0, 256, 16, 4))
    tests.append(corpus('027_tabler_outline_64', 'tabler-outline', 64, 0, 192, 1, 5))
    tests.append(corpus('028_tabler_filled_64', 'tabler-filled', 64, 0, 96, 1, 5))
    tests.append(corpus('029_tabler_outline_128', 'tabler-outline', 128, 1, 192, 6, 4))
    tests.append(corpus('030_simple_icons_64', 'simple-icons', 64, 8, 152, 1, 5))
    tests.append(corpus('031_simple_icons_256', 'simple-icons', 256, 0, 8, 1, 2,
                        largest=True))

    art = []
    thumbs = []
    for name, (builder, vbw, vbh) in sorted(ILLUSTRATIONS.items()):
        text = builder()
        big_w, big_h = vbw * 2, vbh * 2
        small_w, small_h = vbw * 4 // 5, vbh * 4 // 5
        art.append(('%s_%dx%d.svg' % (name, big_w, big_h), text, big_w, big_h, None))
        thumbs.append(('%s_%dx%d.svg' % (name, small_w, small_h),
                       text, small_w, small_h, None))
    tests.append({'name': '032_illustration_thumbs', 'files': thumbs, 'hires_stride': 1})
    tests.append({'name': '033_illustrations', 'files': art, 'hires_stride': 1})
    # Round joins at an exact 180-degree reversal: the wedge has to land on the
    # side the two segments miss, and there are enough of them here that putting
    # it on the wrong side blows the pixel budget.
    tests.append(hand('034_stroke_reversal',
                      ('stroke_reversal', 200, 100), ('stroke_reversal', 400, 200)))
    # Large arcs: splitting them into 90-degree cubics instead of 45-degree ones
    # is accurate enough at icon sizes but not at this radius.
    tests.append(hand('035_arc_precision',
                      ('arc_precision', 256, 256), ('arc_precision', 512, 512)))
    return tests


# tests/ is handed out without corpus/, so it carries the licences of its
# third-party data.
TEST_NOTICE = 'corpus/tests-notice.md'
TEST_LICENCES = [
    ('corpus/feather/LICENSE', 'LICENSE-feather-MIT.txt'),
    ('corpus/tabler-outline/LICENSE', 'LICENSE-tabler-MIT.txt'),
    ('corpus/simple-icons/LICENSE.md', 'LICENSE-simple-icons-CC0.md'),
    ('corpus/SOURCES.md', 'SOURCES.md'),
]


def copy_licences():
    shutil.copyfile(os.path.join(HERE, TEST_NOTICE),
                    os.path.join(TESTS, 'THIRD_PARTY.md'))
    for src, name in TEST_LICENCES:
        shutil.copyfile(os.path.join(HERE, src), os.path.join(TESTS, name))


def build(only=None):
    if only is None and os.path.isdir(TESTS):
        shutil.rmtree(TESTS)
    os.makedirs(TESTS, exist_ok=True)
    copy_licences()

    checked = 0
    supersampled = 0
    for test in suite():
        if only and only not in test['name']:
            continue
        case = os.path.join(TESTS, test['name'])
        if os.path.isdir(case):
            shutil.rmtree(case)
        in_dir = os.path.join(case, 'input')
        out_dir = os.path.join(case, 'expected')
        os.makedirs(in_dir)
        os.makedirs(out_dir)
        lines = []
        worst = (0.0, 0.0, 0)
        for index, (name, text, width, height, oracle) in enumerate(test['files']):
            with open(os.path.join(in_dir, name), 'w', encoding='utf-8') as fh:
                fh.write(text)
            lines.append('%s %d %d' % (name, width, height))
            ppm = reference_ppm(text, width, height)
            with open(os.path.join(out_dir, name[:-4] + '.ppm'), 'wb') as fh:
                fh.write(ppm)
            stride = test['hires_stride']
            hires = (bool(stride) and index % stride == 0
                     and width * height <= HIRES_MAX_PIXELS)
            stats = cross_check('%s/%s' % (test['name'], name), text,
                                oracle if oracle is not None else text,
                                width, height, ppm, hires)
            checked += 1
            supersampled += 1 if hires else 0
            worst = tuple(max(a, b) for a, b in zip(worst, stats))
        with open(os.path.join(in_dir, 'render.txt'), 'w', encoding='utf-8') as fh:
            fh.write('# <file> <width> <height>\n' + '\n'.join(lines) + '\n')
        size = sum(os.path.getsize(os.path.join(dp, f))
                   for dp, _dn, fn in os.walk(case) for f in fn)
        print('%-26s %3d files  %6.1f kB  worst vs resvg: mean=%.2f bad=%.2f%% max=%d'
              % (test['name'], len(test['files']), size / 1024.0, worst[0], worst[1], worst[2]))
    print('%d images cross-checked against resvg, %d of them supersampled'
          % (checked, supersampled))


if __name__ == '__main__':
    build(sys.argv[1] if len(sys.argv) > 1 else None)
