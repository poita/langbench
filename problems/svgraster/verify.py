#!/usr/bin/env python3
"""Compare rendered PPM images against the expected ones within tolerance.

Usage: verify.py <input dir> <actual dir> <expected dir>

The output directory must hold exactly the .ppm files render.txt asks for and
nothing else, anywhere beneath it.

A pixel counts as wrong when any of its three channels differs from the
expected value by more than MAX_CHANNEL_DIFF. An image passes when at most
MAX_BAD_FRACTION of its pixels are wrong and the mean absolute channel
difference is below MAX_MEAN_DIFF.
"""
import os
import sys

MAX_CHANNEL_DIFF = 8
MAX_BAD_FRACTION = 0.005
MAX_MEAN_DIFF = 1.0


def fail(message):
    print(message)
    raise SystemExit(1)


def expected_names(input_dir):
    """The .ppm file names render.txt asks for, in order."""
    path = os.path.join(input_dir, 'render.txt')
    names = []
    with open(path, 'r', encoding='utf-8') as fh:
        for line in fh.read().split('\n'):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            stem = line.split()[0]
            if stem.lower().endswith('.svg'):
                stem = stem[:-4]
            names.append(stem + '.ppm')
    return names


def read_ppm(path):
    """Return (width, height, pixel bytes) of a binary PPM, or raise ValueError."""
    with open(path, 'rb') as fh:
        data = fh.read()
    if not data.startswith(b'P6\n'):
        raise ValueError('bad magic (expected "P6\\n")')
    parts = data.split(b'\n', 3)
    if len(parts) < 4:
        raise ValueError('truncated header')
    dims = parts[1].split()
    if len(dims) != 2 or parts[2] != b'255':
        raise ValueError('bad header line %r / %r' % (parts[1], parts[2]))
    w, h = int(dims[0]), int(dims[1])
    body = parts[3]
    if len(body) != w * h * 3:
        raise ValueError('expected %d pixel bytes, found %d' % (w * h * 3, len(body)))
    return w, h, body


def compare(actual, expected, w, h):
    """Return (wrong pixel count, mean absolute channel difference)."""
    bad = 0
    total = 0
    step = 3072                      # a whole number of pixels per chunk
    for base in range(0, len(actual), step):
        ca = actual[base:base + step]
        ce = expected[base:base + step]
        if ca == ce:
            continue
        pixel_bad = False
        for i in range(len(ca)):
            d = ca[i] - ce[i]
            if d < 0:
                d = -d
            total += d
            if d > MAX_CHANNEL_DIFF:
                pixel_bad = True
            if i % 3 == 2:
                if pixel_bad:
                    bad += 1
                pixel_bad = False
    return bad, total / float(w * h * 3)


def main(argv):
    if len(argv) < 4:
        fail('usage: verify.py <input dir> <actual dir> <expected dir>')
    input_dir, actual_dir, expected_dir = argv[1], argv[2], argv[3]
    wanted = expected_names(input_dir)
    produced = []
    for dirpath, dirnames, filenames in os.walk(actual_dir):
        dirnames.sort()
        for filename in sorted(filenames):
            produced.append(os.path.relpath(os.path.join(dirpath, filename), actual_dir))
    extra = sorted(set(produced) - set(wanted))
    if extra:
        fail('unexpected files in the output directory: %s' % ', '.join(extra[:5]))
    for name in wanted:
        apath = os.path.join(actual_dir, name)
        epath = os.path.join(expected_dir, name)
        if not os.path.isfile(apath):
            fail('missing output file %s' % name)
        ew, eh, expected = read_ppm(epath)
        try:
            aw, ah, actual = read_ppm(apath)
        except (ValueError, OSError) as exc:
            fail('%s: %s' % (name, exc))
        if (aw, ah) != (ew, eh):
            fail('%s: expected %dx%d, got %dx%d' % (name, ew, eh, aw, ah))
        bad, mean = compare(actual, expected, aw, ah)
        allowed = max(1, int(aw * ah * MAX_BAD_FRACTION))
        if bad > allowed:
            fail('%s: %d of %d pixels differ by more than %d (at most %d allowed)'
                 % (name, bad, aw * ah, MAX_CHANNEL_DIFF, allowed))
        if not mean < MAX_MEAN_DIFF:
            fail('%s: mean absolute difference %.3f is not below %.1f'
                 % (name, mean, MAX_MEAN_DIFF))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
