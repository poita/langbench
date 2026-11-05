#!/usr/bin/env python3
"""Generate the qrcode performance benchmark inputs and expected outputs.

Deterministic (fixed seeds). Uses the same layout as tests/ (NNN_name.in /
NNN_name.out) so `run_tests.py qrcode --tests-dir problems/qrcode/bench` works.
Expected outputs come from reference/main.py. Every input stays within the
spec's limit of 100 queries.
"""
import argparse
import os
import random
import sys

sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)
import gen_tests as gt  # noqa: E402
from gen_tests import ref  # noqa: E402

MAX_QUERIES = 100

# Long tier (bench-long/): the same three workloads with many more queries,
# sized so the fastest implementation needs >= 5 s where disk allows (see
# NOTES.md). SPEC.md allows up to 10000 queries per input.
LONG_QUERIES = {
    "001_auto_mask_v36_40": 2400,
    "002_fixed_mask_v40_full": 3000,
    "003_mixed_realistic": 7500,
}
LONG_MAX_QUERIES = 10000


def text_near_version(rng, version, ecl, mode):
    """Text whose length falls between the capacities of version-1 and version."""
    hi = gt.max_chars(version, ecl, mode)
    lo = gt.max_chars(version - 1, ecl, mode) + 1 if version > 1 else 1
    n = rng.randint(lo, hi)
    if mode == ref.MODE_NUMERIC:
        return gt.rnd_numeric(rng, n)
    if mode == ref.MODE_ALNUM:
        return gt.rnd_alnum(rng, n).ljust(n, "Q")
    return gt.rnd_ascii_byte(rng, n).ljust(n, "x")


def bench_auto_large(rng, n=MAX_QUERIES):
    """100 auto-mask queries at versions 36..40, all ECLs and modes."""
    qs = []
    for i in range(n):
        ecl = "LMQH"[i % 4]
        v = rng.randint(36, 40)
        kind = rng.choice(["num", "alnum", "byte", "utf8"])
        if kind == "utf8":
            hi = gt.max_chars(v, ecl, ref.MODE_BYTE)
            lo = gt.max_chars(v - 1, ecl, ref.MODE_BYTE) + 1
            t = gt.rnd_utf8(rng, rng.randint(lo, hi))
        else:
            mode = {"num": ref.MODE_NUMERIC, "alnum": ref.MODE_ALNUM, "byte": ref.MODE_BYTE}[kind]
            t = text_near_version(rng, v, ecl, mode)
        qs.append((ecl, "auto", t))
    return qs


def bench_fixed_mask_encode(rng, n=MAX_QUERIES):
    """100 fixed-mask queries, all version 40 filled to capacity: encoding, RS, placement, masking."""
    qs = []
    for i in range(n):
        ecl = "LMQH"[(i // 3) % 4]
        mode = [ref.MODE_NUMERIC, ref.MODE_ALNUM, ref.MODE_BYTE][i % 3]
        n = gt.max_chars(40, ecl, mode)
        if mode == ref.MODE_BYTE and i % 2 == 0:
            t = gt.rnd_utf8(rng, n)
        elif mode == ref.MODE_NUMERIC:
            t = gt.rnd_numeric(rng, n)
        elif mode == ref.MODE_ALNUM:
            t = gt.rnd_alnum(rng, n).ljust(n, "Q")
        else:
            t = gt.rnd_ascii_byte(rng, n).ljust(n, "x")
        qs.append((ecl, str(i % 8), t))
    return qs


WORDS = ("order invoice ticket gate seat event shipment parcel product batch serial "
         "café straße naïve 東京 日本語 Москва über señor").split()


def realistic_payload(rng):
    kind = rng.choice(["url", "url", "vcard", "wifi", "ticket", "numeric", "alnum", "text", "text"])
    if kind == "url":
        path = "/".join(rng.choice(WORDS[:12]) for _ in range(rng.randint(1, 6)))
        q = "&".join(f"{rng.choice(WORDS[:12])}={rng.randint(0, 10**9)}" for _ in range(rng.randint(0, 40)))
        return f"https://www.example.com/{path}?{q}".rstrip("?")
    if kind == "vcard":
        fields = [f"BEGIN:VCARD;VERSION:3.0;N:{rng.choice(WORDS)};{rng.choice(WORDS)}",
                  f"TEL:+61{rng.randint(10**8, 10**9 - 1)}",
                  f"EMAIL:{rng.choice(WORDS[:12])}@example.org",
                  "ADR:" + " ".join(rng.choice(WORDS) for _ in range(rng.randint(3, 30))),
                  "NOTE:" + " ".join(rng.choice(WORDS) for _ in range(rng.randint(0, 200))),
                  "END:VCARD"]
        return ";".join(fields)
    if kind == "wifi":
        return f"WIFI:T:WPA;S:{rng.choice(WORDS)}-{rng.randint(1, 999)};P:{gt.rnd_ascii_byte(rng, rng.randint(8, 63))};;"
    if kind == "ticket":
        return gt.rnd_alnum(rng, rng.randint(20, 1800)).replace("  ", " Z")
    if kind == "numeric":
        return gt.rnd_numeric(rng, rng.randint(10, 5000))
    if kind == "alnum":
        return gt.rnd_alnum(rng, rng.randint(10, 3000)).replace("  ", " Z")
    return gt.rnd_utf8(rng, rng.randint(50, 2300))


def bench_mixed_realistic(rng, n=MAX_QUERIES):
    """100 realistic payloads of varied size; mostly auto mask, some fixed."""
    qs = []
    while len(qs) < n:
        ecl = rng.choice("LMMQH")
        t = realistic_payload(rng).strip()
        b = t.encode("utf-8")
        mode = ref.select_mode(b)
        if gt.max_chars(40, ecl, mode) < (len(b) if mode == ref.MODE_BYTE else len(t)):
            continue
        mask = "auto" if rng.random() < 0.8 else str(rng.randint(0, 7))
        qs.append((ecl, mask, t))
    return qs


BENCHES = [
    ("001_auto_mask_v36_40", bench_auto_large, 7001),
    ("002_fixed_mask_v40_full", bench_fixed_mask_encode, 7002),
    ("003_mixed_realistic", bench_mixed_realistic, 7003),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--long", action="store_true",
                    help="write the long tier to ../bench-long instead")
    args = ap.parse_args()
    out_dir = os.path.join(PROBLEM, "bench-long") if args.long else HERE
    os.makedirs(out_dir, exist_ok=True)
    for name, fn, seed in BENCHES:
        if args.long:
            queries = fn(random.Random(seed), LONG_QUERIES[name])
            assert 1 <= len(queries) <= LONG_MAX_QUERIES
        else:
            queries = fn(random.Random(seed))
            assert 1 <= len(queries) <= MAX_QUERIES
        inp = b"\n".join(gt.query_bytes(*q) for q in queries) + b"\n"
        out = gt.run_reference(inp)
        assert len(gt.parse_output(out)) == len(queries)
        with open(os.path.join(out_dir, name + ".in"), "wb") as f:
            f.write(inp)
        with open(os.path.join(out_dir, name + ".out"), "wb") as f:
            f.write(out)
        print(f"{name}: {len(queries)} queries, {len(inp)} input bytes, {len(out)} output bytes")


if __name__ == "__main__":
    main()
