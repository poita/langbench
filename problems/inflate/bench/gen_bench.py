#!/usr/bin/env python3
"""Generates the inflate performance benchmark inputs (bench/*.in, *.out).

Each input is a raw DEFLATE stream produced by zlib that decompresses to
exactly 1 MiB, the maximum output SPEC.md allows. Expected outputs come from
reference/main.py and are cross-checked against zlib.
"""
import math
import os
import random
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
sys.path.insert(0, os.path.join(PROBLEM, "reference"))
from gen_tests import synth_text, synth_binary, zlib_full_decode  # noqa: E402
from main import inflate  # noqa: E402

SIZE = 1 << 20
MAX_STREAM = 1_050_000  # keeps the hex input line within the spec's ~2.1 MiB

# Long tier (bench-long/): the same three streams at 16 MiB of output each.
# Every output byte is also stored as hex in the expected file, so the size
# is bounded by disk rather than by the time target (see NOTES.md).
LONG_SIZE = 16 << 20
LONG_MAX_STREAM = 16_800_000


def sensor_samples(rng, size):
    """Interleaved 16-bit little-endian multi-channel signal: slow sine waves
    plus noise, as in an uncompressed audio or telemetry capture. Low bytes
    are close to random, high bytes are skewed, so zlib emits mostly
    literals from a wide alphabet with occasional short matches."""
    out = bytearray()
    t = 0
    channels = 4
    phase = [rng.random() * 6.28 for _ in range(channels)]
    freq = [0.0007, 0.0013, 0.0031, 0.011]
    while len(out) < size:
        for c in range(channels):
            v = int(9000 * math.sin(phase[c] + freq[c] * t) + rng.gauss(0, 600))
            out += (v & 0xFFFF).to_bytes(2, "little")
        if rng.random() < 0.02:
            # Occasional record header, a realistic source of short matches.
            out += b"SMPL" + (t & 0xFFFF).to_bytes(2, "little")
        t += 1
    return bytes(out[:size])


def source_like(rng, size):
    """Program-source-like text: indented lines built from identifiers and
    keywords, giving many medium-length matches at varied distances."""
    kws = ["if", "for", "while", "return", "int", "const", "auto", "else",
           "struct", "void", "static", "break", "case", "switch"]
    idents = ["count", "buffer", "index", "result", "node", "value", "table",
              "offset", "length", "state", "decoder", "window", "symbol"]
    idents += ["%s_%d" % (rng.choice(idents), rng.randint(0, 999)) for _ in range(200)]
    lines = []
    total = 0
    depth = 0
    while total < size:
        r = rng.random()
        if r < 0.15 and depth < 6:
            line = "%s (%s < %s) {" % (rng.choice(kws[:3]), rng.choice(idents), rng.choice(idents))
            depth += 1
        elif r < 0.27 and depth > 0:
            depth -= 1
            line = "}"
        else:
            line = "%s %s = %s(%s, %d);" % (rng.choice(kws[4:7]), rng.choice(idents),
                                           rng.choice(idents), rng.choice(idents),
                                           rng.randint(0, 4096))
        line = "    " * depth + line + "\n"
        lines.append(line)
        total += len(line)
    return "".join(lines).encode()[:size]


def mixed_archive(rng, size):
    """A tar-like concatenation of differently shaped files: prose, source,
    binary records, a run-heavy bitmap, already-compressed (random) data and
    a duplicated file, so one stream alternates between literal-heavy,
    match-heavy, long-distance and stored stretches."""
    parts = []
    total = 0
    kinds = ["text", "source", "binary", "bitmap", "random", "dup"]
    while total < size:
        kind = rng.choice(kinds)
        n = rng.randint(8 * 1024, 64 * 1024)
        if kind == "text":
            d = synth_text(rng, n)
        elif kind == "source":
            d = source_like(rng, n)
        elif kind == "binary":
            d = synth_binary(rng, n)
        elif kind == "bitmap":
            row = bytes(rng.choice([0, 0, 0, 255, 128]) for _ in range(rng.randint(64, 512)))
            d = bytearray()
            while len(d) < n:
                d += row if rng.random() < 0.8 else bytes([rng.randint(0, 255)]) * len(row)
            d = bytes(d[:n])
        elif kind == "random":
            d = rng.randbytes(n)
        else:
            src = b"".join(parts)[-30000:] or synth_text(rng, n)
            d = src[: min(n, len(src))]
        header = ("FILE %-24s %08d\n" % (kind + str(len(parts)), len(d))).encode()
        parts.append(header + d)
        total += len(header) + len(d)
    return b"".join(parts)[:size]


def compress(data, level, memlevel=8, strategy=zlib.Z_DEFAULT_STRATEGY, flush_every=None):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, memlevel, strategy)
    if flush_every is None:
        return c.compress(data) + c.flush()
    out = bytearray()
    for i in range(0, len(data), flush_every):
        out += c.compress(data[i:i + flush_every])
        out += c.flush(zlib.Z_SYNC_FLUSH)
    out += c.flush()
    return bytes(out)


def build(size=SIZE):
    cases = []
    rng = random.Random(20261011)

    d = sensor_samples(rng, size)
    cases.append(("literal_heavy_sensor_1mb", compress(d, 6), d))

    t = bytearray()
    while len(t) < size:
        t += synth_text(rng, 8192) if rng.random() < 0.75 else source_like(rng, 8192)
    d = bytes(t[:size])
    cases.append(("many_dynamic_blocks_1mb", compress(d, 1, memlevel=1), d))

    d = mixed_archive(rng, size)
    cases.append(("mixed_archive_1mb", compress(d, 9, flush_every=256 * 1024), d))
    return cases


def main():
    out_dir, size, max_stream = HERE, SIZE, MAX_STREAM
    if "--long" in sys.argv[1:]:
        out_dir, size, max_stream = os.path.join(PROBLEM, "bench-long"), LONG_SIZE, LONG_MAX_STREAM
        os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(out_dir, f))
    for i, (name, stream, expected) in enumerate(build(size)):
        name = "%03d_%s" % (i + 1, name)
        assert len(expected) == size
        assert len(stream) <= max_stream, f"{name}: stream too large ({len(stream)})"
        zok, zout = zlib_full_decode(stream)
        assert zok and zout == expected, f"{name}: zlib disagrees"
        stats = {}
        got = inflate(stream, stats)
        assert got == expected, f"{name}: reference disagrees"
        blocks = stats.get("blocks", [])
        with open(os.path.join(out_dir, name + ".in"), "w") as f:
            f.write(stream.hex() + "\n")
        with open(os.path.join(out_dir, name + ".out"), "w") as f:
            f.write(got.hex() + "\n")
        kinds = {k: blocks.count(k) for k in sorted(set(blocks))}
        print(f"{name}: stream={len(stream)}B out={len(got)}B blocks={len(blocks)} by type={kinds} "
              f"maxdist={stats.get('max_distance')}")


if __name__ == "__main__":
    main()
