#!/usr/bin/env python3
"""Generate tests/*.in and tests/*.out for the qrcode problem.

Inputs are deterministic (fixed seeds plus hand-written cases). Expected
outputs come from reference/main.py. When the `qrcode` or `segno` package is
importable, every generated query is additionally cross-checked against it.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "reference"))
import main as ref  # noqa: E402

TESTS = os.path.join(HERE, "tests")
ALNUM = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
UTF8_POOL = ["é", "ñ", "ü", "€", "日", "本", "語", "Ж", "ß", "😀", "中", "ø", "ç", "λ"]

# Published maximum capacities (ISO/IEC 18004 Table 7) used to sanity-check the
# reference's capacity computation.
PUBLISHED_V40 = {"L": (7089, 4296, 2953), "M": (5596, 3391, 2331),
                 "Q": (3993, 2420, 1663), "H": (3057, 1852, 1273)}


def max_chars(version, ecl, mode):
    """Largest character count of `mode` that fits in (version, ecl)."""
    cap = ref.num_data_codewords(version, ecl) * 8 - 4 - ref.cc_bits(mode, version)
    if mode == ref.MODE_NUMERIC:
        n = (cap // 10) * 3
        rest = cap % 10
        n += 2 if rest >= 7 else (1 if rest >= 4 else 0)
        return n
    if mode == ref.MODE_ALNUM:
        n = (cap // 11) * 2
        return n + (1 if cap % 11 >= 6 else 0)
    return cap // 8


def check_capacities():
    for ecl, (num, aln, byt) in PUBLISHED_V40.items():
        got = (max_chars(40, ecl, ref.MODE_NUMERIC), max_chars(40, ecl, ref.MODE_ALNUM), max_chars(40, ecl, ref.MODE_BYTE))
        assert got == (num, aln, byt), (ecl, got)
    assert (max_chars(1, "L", ref.MODE_NUMERIC), max_chars(1, "L", ref.MODE_ALNUM), max_chars(1, "L", ref.MODE_BYTE)) == (41, 25, 17)
    assert (max_chars(1, "H", ref.MODE_NUMERIC), max_chars(1, "H", ref.MODE_ALNUM), max_chars(1, "H", ref.MODE_BYTE)) == (17, 10, 7)


def rnd_numeric(rng, n):
    return "".join(rng.choice("0123456789") for _ in range(n))


def rnd_alnum(rng, n):
    # Interior spaces are fine; leading/trailing spaces are not allowed by the spec.
    s = "".join(rng.choice(ALNUM) for _ in range(n))
    return s.strip() or "A" * n


def rnd_ascii_byte(rng, n):
    chars = [chr(c) for c in range(33, 127)] + [" "] * 8
    s = "".join(rng.choice(chars) for _ in range(n)).strip()
    if s.isdigit() or all(c in ALNUM for c in s):
        s = "a" + s[1:]
    return s or "a"


def rnd_utf8(rng, nbytes):
    """Random text of exactly `nbytes` UTF-8 bytes mixing ASCII and multibyte characters."""
    out = []
    size = 0
    while size < nbytes:
        c = rng.choice(UTF8_POOL) if rng.random() < 0.4 else chr(rng.randint(97, 122))
        b = len(c.encode("utf-8"))
        if size + b > nbytes:
            c = "x"
            b = 1
        out.append(c)
        size += b
    return "".join(out)


def text_for_version(rng, version, ecl, mode):
    """Text that lands exactly on `version` at `ecl` using the given mode."""
    n = max_chars(version, ecl, mode)
    if mode == ref.MODE_NUMERIC:
        return rnd_numeric(rng, n)
    if mode == ref.MODE_ALNUM:
        return rnd_alnum(rng, n)
    return rnd_ascii_byte(rng, n)


def build_tests():
    rng = random.Random(20240918)
    tests = []

    def add(name, queries):
        tests.append((name, queries))

    add("001_hello_world", [("M", "0", "HELLO WORLD"), ("M", "auto", "HELLO WORLD")])
    add("002_single_char_all_ecl", [(e, "0", t) for e in "LMQH" for t in ("1", "A", "a")])
    add("003_all_masks_numeric", [("L", str(m), "01234567") for m in range(8)])
    add("004_all_masks_alnum", [("M", str(m), "HELLO WORLD") for m in range(8)])
    add("005_all_masks_byte", [("Q", str(m), "hello, world!") for m in range(8)])
    add("006_all_ecl_auto", [(e, "auto", "https://example.com/?q=1") for e in "LMQH"])
    add("007_mode_selection", [
        ("L", "2", "1"), ("L", "2", "12"), ("L", "2", "123"), ("L", "2", "1234"), ("L", "2", "12345"),
        ("L", "2", "A"), ("L", "2", "AB"), ("L", "2", "ABC"), ("L", "2", "A B"),
        ("L", "2", "$%*+-./:"), ("L", "2", "HELLO world"), ("L", "2", "0A"), ("L", "2", "a0"),
        ("L", "2", "ABCDEFGHIJKLMNOPQRSTUVWXYZ"), ("L", "2", "0123456789 $%*+-./:"), ("L", "2", "~"),
    ])
    add("008_version1_capacity_edges", [
        ("L", "1", "1" * 41), ("L", "1", "1" * 42),
        ("L", "1", "A" * 25), ("L", "1", "A" * 26),
        ("L", "1", "a" * 17), ("L", "1", "a" * 18),
        ("H", "1", "7" * 17), ("H", "1", "7" * 18),
        ("H", "1", "Z" * 10), ("H", "1", "Z" * 11),
        ("H", "1", "z" * 7), ("H", "1", "z" * 8),
    ])
    add("009_version2_all_ecl", [(e, str(i), "Version two alignment pattern test") for i, e in enumerate("LMQH")])
    add("010_terminator_truncation", [
        ("L", "3", rnd_numeric(rng, 41)),           # 151 bits used, 1-bit terminator
        ("L", "3", rnd_alnum(rng, 25).replace(" ", "A")),  # 151 bits, 1-bit terminator
        ("M", "3", rnd_numeric(rng, 34)),           # 128 bits, no room for a terminator
        ("Q", "auto", rnd_alnum(rng, 16).replace(" ", "B")),  # 101 bits of 104
        ("H", "auto", rnd_numeric(rng, 17)),        # 71 bits of 72
    ])
    add("011_padding_variety", [("M", "4", rnd_ascii_byte(rng, n)) for n in range(1, 15)])
    # Penalty ties between masks: auto must pick the lowest mask number.
    # (Penalties, in mask order: Y25/Q 336,378,455,494,452,527,336,368 -> masks 0 and 6 tie;
    # 199/H masks 1 and 3; eybtiilaewac/L masks 2 and 4; djyctof/H masks 1 and 6;
    # OQ/Q masks 4 and 7; 7801/L masks 0 and 3.)
    add("012_auto_tie_break", [
        ("Q", "auto", "Y25"), ("H", "auto", "199"), ("L", "auto", "eybtiilaewac"),
        ("H", "auto", "djyctof"), ("Q", "auto", "OQ"), ("L", "auto", "7801"),
    ])
    add("013_utf8_bytes", [
        ("M", "0", "héllo"), ("L", "auto", "日本語テキスト"), ("H", "7", "Ünïcödé €"),
        ("Q", "auto", "😀😃😄"), ("L", "5", "ß"), ("M", "auto", "Жизнь прекрасна"),
    ])
    add("014_utf8_all_masks", [("H", str(m), "naïve café 東京") for m in range(8)])
    add("015_version7_version_info", [(e, "auto", text_for_version(rng, 7, e, mode))
                                       for e in "LMQH" for mode in (ref.MODE_NUMERIC, ref.MODE_ALNUM, ref.MODE_BYTE)])
    add("016_versions_6_7_8", [("L", str(v % 8), text_for_version(rng, v, "L", ref.MODE_BYTE)) for v in (6, 7, 8)] +
        [("H", "auto", text_for_version(rng, v, "H", ref.MODE_ALNUM)) for v in (6, 7, 8)])
    add("017_cc_width_boundaries", [
        (e, "auto", text_for_version(rng, v, e, mode))
        for v in (9, 10, 26, 27) for e in ("L", "H") for mode in (ref.MODE_NUMERIC, ref.MODE_ALNUM, ref.MODE_BYTE)
    ])
    add("018_versions_10_to_20_fixed", [(rng.choice("LMQH"), str(rng.randint(0, 7)),
                                         text_for_version(rng, v, "M", rng.choice([ref.MODE_NUMERIC, ref.MODE_ALNUM, ref.MODE_BYTE])))
                                        for v in range(10, 21)])
    add("019_versions_21_to_30_auto", [(rng.choice("LMQH"), "auto", rnd_utf8(rng, max_chars(v, "Q", ref.MODE_BYTE)))
                                       for v in range(21, 31)])
    add("020_versions_31_to_39", [(e, m, text_for_version(rng, v, e, ref.MODE_ALNUM))
                                  for v, e, m in zip(range(31, 40), "LMQHLMQHL", ["auto", "0", "1", "2", "3", "4", "5", "6", "7"])])
    add("021_version40_fixed_each_ecl", [(e, str(i * 2 + 1), text_for_version(rng, 40, e, ref.MODE_BYTE)) for i, e in enumerate("LMQH")])
    add("022_version40_max_capacity", [
        (e, "auto", rnd_numeric(rng, PUBLISHED_V40[e][0])) for e in "LMQH"] + [
        (e, "6", rnd_alnum(rng, PUBLISHED_V40[e][1]).ljust(PUBLISHED_V40[e][1], "X")) for e in "LMQH"] + [
        (e, "auto", rnd_ascii_byte(rng, PUBLISHED_V40[e][2]).ljust(PUBLISHED_V40[e][2], "x")) for e in "LMQH"])
    add("023_version40_utf8_auto", [("L", "auto", rnd_utf8(rng, 2953)), ("M", "auto", rnd_utf8(rng, 2200)),
                                    ("Q", "auto", rnd_utf8(rng, 1663)), ("H", "auto", rnd_utf8(rng, 1273))])
    add("024_all_versions_byte_L", [("L", str(v % 8), text_for_version(rng, v, "L", ref.MODE_BYTE)) for v in range(1, 41)])
    add("025_all_versions_numeric_H_auto", [("H", "auto", text_for_version(rng, v, "H", ref.MODE_NUMERIC)) for v in range(1, 41)])
    add("026_all_versions_alnum_mixed", [(rng.choice("LMQH"), rng.choice(["auto", str(rng.randint(0, 7))]),
                                          text_for_version(rng, v, "Q", ref.MODE_ALNUM)) for v in range(1, 41)])

    def random_mixed(count, max_len):
        qs = []
        for _ in range(count):
            kind = rng.choice(["num", "alnum", "byte", "utf8"])
            n = rng.randint(1, max_len)
            if kind == "num":
                t = rnd_numeric(rng, n)
            elif kind == "alnum":
                t = rnd_alnum(rng, n)
            elif kind == "byte":
                t = rnd_ascii_byte(rng, n)
            else:
                t = rnd_utf8(rng, n)
            qs.append((rng.choice("LMQH"), rng.choice(["auto", "auto", str(rng.randint(0, 7))]), t))
        return qs

    add("027_random_small", random_mixed(100, 40))
    add("028_random_medium", random_mixed(60, 400))
    add("029_random_large", random_mixed(30, 1200))
    add("030_stress_auto_mixed", [(e, "auto", t) for e, _, t in random_mixed(60, 1273)])
    add("031_stress_version40_auto", [(rng.choice("LMQH"), "auto", rnd_ascii_byte(rng, 1273)) for _ in range(40)] +
        [("L", "auto", rnd_numeric(rng, 7089)) for _ in range(20)] +
        [("L", str(m), rnd_alnum(rng, 4296).ljust(4296, "Q")) for m in range(8)] +
        [("L", "auto", rnd_utf8(rng, 2953)) for _ in range(12)] +
        [("H", "auto", rnd_numeric(rng, 3057)) for _ in range(20)])
    return tests


def query_bytes(ecl, mask, text):
    b = text.encode("utf-8")
    assert b and not b.startswith(b" ") and not b.endswith(b" ") and b"\n" not in b and b"\r" not in b and b"\t" not in b
    return ecl.encode() + b" " + mask.encode() + b" " + b


def run_reference(inp):
    return subprocess.run([sys.executable, os.path.join(HERE, "reference", "main.py")],
                          input=inp, capture_output=True, check=True).stdout


def parse_output(out):
    """Split reference output into (version, mask, rows) per query."""
    result = []
    blocks = out.decode().split("\n\n")
    for blk in blocks:
        if not blk.strip():
            continue
        lines = blk.split("\n")
        _, v, _, m = lines[0].split()
        result.append((int(v), int(m), [l.replace("#", "1").replace(".", "0") for l in lines[1:]]))
    return result


def oracle_check(queries, results):
    """Cross-check against the qrcode and/or segno packages when available."""
    try:
        import qrcode
        from qrcode.util import lost_point, QRData, MODE_NUMBER, MODE_ALPHA_NUM, MODE_8BIT_BYTE
    except ImportError:
        qrcode = None
    try:
        import segno
    except ImportError:
        segno = None
    if qrcode is None and segno is None:
        return None
    checked = 0
    for (ecl, mask, text), (v, m, rows) in zip(queries, results):
        b = text.encode("utf-8")
        mode = ref.select_mode(b)
        if qrcode is not None:
            ec = {"L": qrcode.constants.ERROR_CORRECT_L, "M": qrcode.constants.ERROR_CORRECT_M,
                  "Q": qrcode.constants.ERROR_CORRECT_Q, "H": qrcode.constants.ERROR_CORRECT_H}[ecl]
            qmode = {ref.MODE_NUMERIC: MODE_NUMBER, ref.MODE_ALNUM: MODE_ALPHA_NUM, ref.MODE_BYTE: MODE_8BIT_BYTE}[mode]

            def qr_rows(fixed_mask):
                q = qrcode.QRCode(error_correction=ec, border=0, mask_pattern=fixed_mask)
                q.add_data(QRData(b, mode=qmode), optimize=0)
                q.make(fit=True)
                return q.version, ["".join("1" if c else "0" for c in r) for r in q.modules]

            if mask == "auto":
                # python-qrcode scores masks with the format bits blanked, so the
                # comparison recomputes the argmin over full symbols with its penalty function.
                best = None
                for cand in range(8):
                    qv, qrows = qr_rows(cand)
                    p = lost_point([[c == "1" for c in r] for r in qrows])
                    if best is None or p < best[0]:
                        best = (p, cand, qv, qrows)
                assert best[1:] == (m, v, rows), ("qrcode auto mismatch", ecl, text[:40])
            else:
                qv, qrows = qr_rows(int(mask))
                assert (qv, qrows) == (v, rows), ("qrcode mismatch", ecl, mask, text[:40])
            checked += 1
        if segno is not None and mask != "auto":
            # segno appends a spurious all-zero codeword whenever the stream is already
            # byte-aligned after the terminator, so only unaligned streams are comparable.
            bits = 4 + ref.cc_bits(mode, v) + ref.data_bits_for_mode(mode, b)
            cap = ref.num_data_codewords(v, ecl) * 8
            if (bits + min(4, cap - bits)) % 8 != 0:
                smode = {ref.MODE_NUMERIC: "numeric", ref.MODE_ALNUM: "alphanumeric", ref.MODE_BYTE: "byte"}[mode]
                s = segno.make(text, error=ecl.lower(), mask=int(mask), boost_error=False, mode=smode,
                               encoding="utf-8", micro=False)
                srows = ["".join("1" if c else "0" for c in r) for r in s.matrix]
                assert (s.version, srows) == (v, rows), ("segno mismatch", ecl, mask, text[:40])
                checked += 1
    return checked


def main():
    check_capacities()
    os.makedirs(TESTS, exist_ok=True)
    for f in os.listdir(TESTS):
        os.remove(os.path.join(TESTS, f))
    total_checked = 0
    for name, queries in build_tests():
        assert len(queries) <= 100
        inp = b"\n".join(query_bytes(*q) for q in queries) + b"\n"
        out = run_reference(inp)
        with open(os.path.join(TESTS, name + ".in"), "wb") as f:
            f.write(inp)
        with open(os.path.join(TESTS, name + ".out"), "wb") as f:
            f.write(out)
        results = parse_output(out)
        assert len(results) == len(queries)
        checked = oracle_check(queries, results)
        if checked is not None:
            total_checked += checked
        print(f"{name}: {len(queries)} queries, {len(out)} bytes" + (f", oracle-checked {checked}" if checked is not None else ""))
    if total_checked:
        print(f"oracle cross-checked {total_checked} query results")


if __name__ == "__main__":
    main()
