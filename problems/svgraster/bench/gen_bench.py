#!/usr/bin/env python3
"""Generate the svgraster performance benchmark inputs and expected outputs.

Writes bench/NNN_name/input/ (SVG files + render.txt) and bench/NNN_name/expected/
(one PPM per SVG, produced by reference/main.py), the same layout as tests/, so
`run_tests.py svgraster --tests-dir problems/svgraster/bench` works.

Everything is deterministic: the icon set is the sorted vendored corpus and the
generated drawings use gen_tests.Rng with fixed seeds.

Usage: gen_bench.py [--inputs-only] [--long] [name-filter]

--long writes the long tier to ../bench-long/ (see NOTES.md).
"""
import math
import multiprocessing
import os
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
import gen_tests as gt                                    # noqa: E402

HEAD = gt.HEAD
Rng = gt.Rng


# ---------------------------------------------------------------------------
# 001: every vendored icon, rendered as an icon sheet would be
# ---------------------------------------------------------------------------

ICON_FOLDERS = ('feather', 'simple-icons', 'tabler-filled', 'tabler-outline')
ICON_SIZE = 64


def icon_files(sizes=None):
    """Every icon at ICON_SIZE, or (long tier) at each of `sizes` as name-SIZE.svg."""
    files = []
    for folder in ICON_FOLDERS:
        path = os.path.join(gt.CORPUS, folder)
        for name in sorted(f for f in os.listdir(path) if f.endswith('.svg')):
            with open(os.path.join(path, name), 'r', encoding='utf-8') as fh:
                text = fh.read()
            if sizes is None:
                files.append(('%s-%s' % (folder, name), text, ICON_SIZE, ICON_SIZE))
                continue
            for size in sizes:
                files.append(('%s-%s-%d.svg' % (folder, name[:-4], size), text, size, size))
    return files


# ---------------------------------------------------------------------------
# 002: a dense topographic map (stroke outlining of long smooth curves)
# ---------------------------------------------------------------------------

def smooth_closed(points):
    """Closed Catmull-Rom spline through points, as cubic Bezier path data."""
    n = len(points)
    d = ['M%.3f %.3f' % points[0]]
    for i in range(n):
        p0 = points[(i - 1) % n]
        p1 = points[i]
        p2 = points[(i + 1) % n]
        p3 = points[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6.0, p1[1] + (p2[1] - p0[1]) / 6.0)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6.0, p2[1] - (p3[1] - p1[1]) / 6.0)
        d.append('C%.3f %.3f %.3f %.3f %.3f %.3f' % (c1 + c2 + p2))
    d.append('Z')
    return ' '.join(d)


def smooth_open(points):
    """Open Catmull-Rom spline through points, using relative 's' segments."""
    d = ['M%.3f %.3f' % points[0]]
    p0, p1 = points[0], points[1]
    c1 = (p0[0] + (p1[0] - p0[0]) / 3.0, p0[1] + (p1[1] - p0[1]) / 3.0)
    d.append('C%.3f %.3f %.3f %.3f %.3f %.3f' % (c1 + c1 + p1))
    for i in range(2, len(points)):
        prev, cur = points[i - 1], points[i]
        nxt = points[i + 1] if i + 1 < len(points) else cur
        c2 = (cur[0] - (nxt[0] - prev[0]) / 6.0, cur[1] - (nxt[1] - prev[1]) / 6.0)
        d.append('s%.3f %.3f %.3f %.3f' % (c2[0] - prev[0], c2[1] - prev[1],
                                           cur[0] - prev[0], cur[1] - prev[1]))
    return ' '.join(d)


def topo_svg(n_peaks=9):
    rng = Rng(4242017)
    size = 600
    out = [HEAD + 'viewBox="0 0 %d %d" width="%d" height="%d">' % (size, size, size, size),
           '<defs>',
           '<g id="peak"><path d="M0 -5 L4.5 3.5 L-4.5 3.5 Z" fill="#3e2723"/>'
           '<circle cx="0" cy="0" r="1.2" fill="#ffffff"/></g>',
           '<circle id="spot" r="2.2" fill="#ffffff" stroke="#1b5e20" stroke-width="1"/>',
           '</defs>',
           '<rect width="%d" height="%d" fill="#f4f1e1"/>' % (size, size)]
    # graticule
    out.append('<g stroke="#b0bec5" stroke-width="0.5" fill="none" opacity="0.7">')
    for i in range(1, 12):
        out.append('<line x1="%d" y1="0" x2="%d" y2="%d"/>' % (i * 50, i * 50, size))
        out.append('<line x1="0" y1="%d" x2="%d" y2="%d"/>' % (i * 50, size, i * 50))
    out.append('</g>')
    palette = ['#c5e1a5', '#dcedc8', '#fff59d', '#ffe082', '#ffcc80', '#bcaaa4']
    peaks = []
    for _ in range(n_peaks):
        cx = rng.between(60, 540)
        cy = rng.between(60, 540)
        radius = rng.between(110, 200)
        rings = 18 + rng.below(12)
        peaks.append((cx, cy, radius, rings))
    for p, (cx, cy, radius, rings) in enumerate(peaks):
        harmonics = [(k, rng.between(0.02, 0.09) / k ** 0.5, rng.between(0, 2 * math.pi))
                     for k in range(2, 9)]
        twist = rng.between(-0.6, 0.6)
        out.append('<g fill-rule="nonzero" stroke-linejoin="round">')
        for r in range(rings):
            t = 1.0 - r / float(rings)
            rr = radius * t + 2.0
            pts = []
            samples = 56
            for s in range(samples):
                a = 2 * math.pi * s / samples
                wob = 1.0 + sum(amp * (0.6 + 0.8 * t) * math.sin(k * a + ph + twist * r * 0.15)
                                for k, amp, ph in harmonics)
                pts.append((cx + rr * wob * math.cos(a), cy + rr * 0.85 * wob * math.sin(a)))
            major = r % 5 == 0
            out.append('<path d="%s" fill="%s" fill-opacity="0.22" stroke="%s" '
                       'stroke-width="%.2f"/>'
                       % (smooth_closed(pts), palette[(r + p) % len(palette)],
                          '#795548' if major else '#a1887f', 1.3 if major else 0.55))
        out.append('</g>')
    # rivers: long open curves with round caps
    for i in range(5):
        pts = []
        x = rng.between(0, size)
        y = 0.0
        while y <= size:
            pts.append((x, y))
            x += rng.between(-22, 22)
            y += rng.between(8, 18)
        out.append('<path d="%s" fill="none" stroke="#4fc3f7" stroke-width="%.2f" '
                   'stroke-linecap="round" stroke-linejoin="round"/>'
                   % (smooth_open(pts), rng.between(1.5, 3.5)))
    # roads: polylines with a casing (wide dark stroke, narrow light stroke on top)
    for i in range(8):
        pts = []
        x = rng.between(0, size)
        y = rng.between(0, size)
        heading = rng.between(0, 2 * math.pi)
        for _ in range(140):
            pts.append((x, y))
            heading += rng.between(-0.35, 0.35)
            step = rng.between(3, 7)
            x += step * math.cos(heading)
            y += step * math.sin(heading)
        pl = ' '.join('%.2f,%.2f' % q for q in pts)
        join = ('round', 'miter', 'bevel')[i % 3]
        out.append('<polyline points="%s" fill="none" stroke="#5d4037" stroke-width="4" '
                   'stroke-linejoin="%s" stroke-linecap="round"/>' % (pl, join))
        out.append('<polyline points="%s" fill="none" stroke="#ffecb3" stroke-width="2.2" '
                   'stroke-linejoin="%s" stroke-linecap="round"/>' % (pl, join))
    # trail: dashed look built from many short line segments
    for i in range(160):
        a = i * 0.09
        x = 300 + (40 + i * 1.5) * math.cos(a)
        y = 300 + (40 + i * 1.5) * math.sin(a)
        out.append('<line x1="%.2f" y1="%.2f" x2="%.2f" y2="%.2f" stroke="#d84315" '
                   'stroke-width="1.4" stroke-linecap="square"/>'
                   % (x, y, x + 3 * math.cos(a + 1.6), y + 3 * math.sin(a + 1.6)))
    for cx, cy, _radius, _rings in peaks:
        out.append('<use href="#peak" x="%.2f" y="%.2f"/>' % (cx, cy))
    for i in range(40):
        out.append('<use href="#spot" x="%.2f" y="%.2f"/>'
                   % (rng.between(10, 590), rng.between(10, 590)))
    out.append('<rect x="8" y="8" width="584" height="584" fill="none" stroke="#263238" '
               'stroke-width="3"/>')
    out.append('</svg>')
    return '\n'.join(out)


TOPO_PIXELS = 1200


# ---------------------------------------------------------------------------
# 003: illustrations at large sizes plus a composed poster
# ---------------------------------------------------------------------------

def body_of(svg_text):
    """The children of a generated document, without its <svg> wrapper."""
    lines = svg_text.split('\n')
    return '\n'.join(lines[1:-1])


def poster_svg(n_panels=0, seed=9090):
    """Several illustrations composed onto one page with transforms and group opacity."""
    rng = Rng(seed)
    out = [HEAD + 'viewBox="0 0 500 500" width="500" height="500">',
           '<rect width="500" height="500" fill="#263238"/>']
    out.append('<g transform="translate(10 10) scale(1.2)">%s</g>' % body_of(gt.skyline_svg()))
    out.append('<g transform="translate(300 20) scale(0.9)" opacity="0.85">%s</g>'
               % body_of(gt.gears_svg()))
    out.append('<g transform="translate(250 250) rotate(-8) scale(1.15) translate(-100 -10)" '
               'opacity="0.9">%s</g>' % body_of(gt.mandala_svg()))
    out.append('<g transform="translate(14 228) scale(1.0 1.3) skewX(-6)">%s</g>'
               % body_of(gt.chart_svg()))
    out.append('<g opacity="0.35" fill="none" stroke="#ffffff" stroke-width="1.2" '
               'stroke-linecap="round">')
    for i in range(60):
        out.append('<ellipse cx="%.2f" cy="%.2f" rx="%.2f" ry="%.2f" '
                   'transform="rotate(%.2f %.2f %.2f)"/>'
                   % (250, 250, 30 + i * 3.6, 18 + i * 2.2, i * 3.0, 250, 250))
    out.append('</g>')
    for i in range(30):
        out.append('<rect x="%.2f" y="%.2f" width="%.2f" height="%.2f" rx="%.2f" '
                   'fill="%s" fill-opacity="%.2f" stroke="#ffffff" stroke-opacity="0.5"/>'
                   % (rng.between(0, 470), rng.between(0, 470), rng.between(8, 30),
                      rng.between(8, 30), rng.between(0, 6),
                      rng.pick(['#e91e63', '#ffc107', '#03a9f4', '#8bc34a']),
                      rng.between(0.3, 0.8)))
    # Extra translucent panels (long tier): each illustration again, placed and
    # rotated at random under its own group opacity.
    builders = [gt.skyline_svg, gt.gears_svg, gt.mandala_svg, gt.chart_svg]
    for i in range(n_panels):
        out.append('<g transform="translate(%.2f %.2f) rotate(%.2f) scale(%.2f)" opacity="%.2f">%s</g>'
                   % (rng.between(-60, 380), rng.between(-60, 380), rng.between(-30, 30),
                      rng.between(0.5, 1.3), rng.between(0.25, 0.75),
                      body_of(builders[i % len(builders)]())))
    out.append('</svg>')
    return '\n'.join(out)


def mixed_files(n_posters=0, n_panels=0):
    files = []
    for name, (builder, vbw, vbh) in sorted(gt.ILLUSTRATIONS.items()):
        w, h = vbw * 4, vbh * 4
        files.append(('%s_%dx%d.svg' % (name, w, h), builder(), w, h))
    files.append(('poster_1000x1000.svg', poster_svg(), 1000, 1000))
    # Long tier: a series of further posters, each with extra translucent panels.
    for i in range(n_posters):
        files.append(('poster_%02d_1000x1000.svg' % (i + 1), poster_svg(n_panels, 9091 + i), 1000, 1000))
    for key, w, h in (('path_arcs', 1000, 600), ('stroke_joins', 800, 450),
                      ('opacity', 800, 480), ('transforms', 720, 360)):
        files.append(('%s_%dx%d.svg' % (key, w, h), gt.HAND[key], w, h))
    return files


# Long tier (--long, written to ../bench-long).
LONG_ICON_SIZES = (16, 20, 24, 32, 48, 64)
LONG_TOPO_PEAKS = 230
LONG_POSTERS = 11
LONG_POSTER_PANELS = 60
LONG_DIR = os.path.join(PROBLEM, 'bench-long')


def long_benches():
    return [
        ('001_icon_corpus_64', icon_files(LONG_ICON_SIZES)),
        ('002_topo_map_1200', [('topo_%dx%d.svg' % (TOPO_PIXELS, TOPO_PIXELS),
                                topo_svg(LONG_TOPO_PEAKS), TOPO_PIXELS, TOPO_PIXELS)]),
        ('003_mixed_illustrations', mixed_files(LONG_POSTERS, LONG_POSTER_PANELS)),
    ]


def benches():
    return [
        ('001_icon_corpus_64', icon_files()),
        ('002_topo_map_1200', [('topo_%dx%d.svg' % (TOPO_PIXELS, TOPO_PIXELS), topo_svg(),
                                TOPO_PIXELS, TOPO_PIXELS)]),
        ('003_mixed_illustrations', mixed_files()),
    ]


def render_one(job):
    text, width, height, out_path = job
    with open(out_path, 'wb') as fh:
        fh.write(gt.reference_ppm(text, width, height))


def build(only=None, render=True, long_tier=False):
    jobs = []
    root = LONG_DIR if long_tier else HERE
    for name, files in (long_benches() if long_tier else benches()):
        if only and only not in name:
            continue
        case = os.path.join(root, name)
        if os.path.isdir(case):
            shutil.rmtree(case)
        in_dir = os.path.join(case, 'input')
        out_dir = os.path.join(case, 'expected')
        os.makedirs(in_dir)
        os.makedirs(out_dir)
        lines = []
        for fname, text, width, height in files:
            with open(os.path.join(in_dir, fname), 'w', encoding='utf-8') as fh:
                fh.write(text)
            lines.append('%s %d %d' % (fname, width, height))
            jobs.append((text, width, height, os.path.join(out_dir, fname[:-4] + '.ppm')))
        with open(os.path.join(in_dir, 'render.txt'), 'w', encoding='utf-8') as fh:
            fh.write('# <file> <width> <height>\n' + '\n'.join(lines) + '\n')
        print('%s: %d files' % (name, len(files)))
    if not render:
        return
    # Largest images first so the pool stays busy.
    jobs.sort(key=lambda j: -j[1] * j[2])
    # The long tier renders one image at a time to bound memory use.
    with multiprocessing.Pool(1 if long_tier else None) as pool:
        for i, _ in enumerate(pool.imap_unordered(render_one, jobs), 1):
            if i % 100 == 0 or i == len(jobs):
                print('  rendered %d/%d' % (i, len(jobs)))


if __name__ == '__main__':
    args = sys.argv[1:]
    render = '--inputs-only' not in args
    long_tier = '--long' in args
    args = [a for a in args if a not in ('--inputs-only', '--long')]
    build(args[0] if args else None, render, long_tier)
