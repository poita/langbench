#!/usr/bin/env python3
"""Generate the commonmark performance benchmark inputs deterministically.

Writes bench/NNN_name.in (same layout as tests/) and bench/NNN_name.out via
reference/main.py. Every input is checked against the subset guarantees of
SPEC.md (gen_tests.subset_violation) and stays within its 1 MB input limit.
When `cmark` is on PATH (or $CMARK names it) every expected output is also
cross-checked against it, the oracle of this problem.
"""
import os
import random
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.path.insert(0, PROBLEM)

sys.dont_write_bytecode = True
import gen_tests  # noqa: E402
from gen_tests import gen_document, subset_violation  # noqa: E402

REF = os.path.join(PROBLEM, "reference", "main.py")
CMARK = os.environ.get("CMARK", "cmark")
MAX_BYTES = 1_000_000
TARGET = 990_000

WORDS = ("the of and to in is that for it as with was on be by this are or from at which an have not but "
         "can all were when there their will each if about how up out them then she many some so these "
         "would other into has more her two like him see time could no make than first been its who now "
         "people my made over did down only way find use may water long little very after words called "
         "just where most know get through back much before go good new write our used me man too any "
         "day same right look think also around another came come work three word must because does part "
         "even place well such here take why things help put years different away again off went old "
         "number great tell men say small every found still between name should home big give air line "
         "set own under read last never us left end along while might next sound below saw something "
         "thought both few those always looked show large often together asked house world going want "
         "school important until form food keep children feet land side without boy once animals life "
         "enough took sometimes four head above kind began almost live page got earth need far hand high "
         "year mother light parts country father let night following picture being study second eyes "
         "server client request response buffer parser token stream module function value config cache "
         "index query schema record field option handler thread process memory output input runtime").split()
IDENTS = ["parse_args", "read_config", "HttpClient", "max_retries", "user_id", "on_error", "BufferPool",
          "open_stream", "timeout_ms", "is_valid", "get_or_insert", "Vec<u8>", "std::string", "map[string]int",
          "__init__", "self.items", "ctx.Done()", "len(xs)", "x->next", "a && b", "i < n", "--verbose",
          "--output=out.html", "$HOME/.config", "0x7fff", "#include", "*ptr", "**kwargs", "foo_bar_baz"]
# Unmatched backtick runs can move code-span boundaries in dense prose, so a
# '<' there must never be readable as an HTML tag.
PLAIN_IDENTS = [x for x in IDENTS if "<" not in x]
LANGS = ["python", "rust", "go", "c++", "js", "bash", "toml", "json", "", ""]
SITES = ["https://example.com", "https://docs.example.org", "http://localhost:8080", "https://github.com/example/repo",
         "https://en.wikipedia.org/wiki", "https://api.example.net/v2"]


def w(rng):
    r = rng.random()
    if r < 0.03:
        return rng.choice(gen_tests.UNICODE_WORDS)
    if r < 0.06:
        return str(rng.randint(0, 9999))
    return rng.choice(WORDS)


def url(rng):
    path = "/".join(rng.choice(WORDS) for _ in range(rng.randint(0, 3)))
    u = rng.choice(SITES) + "/" + path
    r = rng.random()
    if r < 0.15:
        u += "?q=%s&page=%d" % (rng.choice(WORDS), rng.randint(1, 50))
    elif r < 0.25:
        u += "#" + rng.choice(WORDS)
    elif r < 0.30:
        u += ".html"
    return u


# ---------------------------------------------------------------------------
# 001: realistic documentation site (block-structure throughput)
# ---------------------------------------------------------------------------
def doc_inline(rng):
    """One plain-prose phrase, sometimes decorated with a common inline construct."""
    r = rng.random()
    if r < 0.80:
        return w(rng)
    if r < 0.84:
        return "`" + rng.choice(IDENTS) + "`"
    if r < 0.88:
        return "*" + w(rng) + " " + w(rng) + "*"
    if r < 0.91:
        return "**" + w(rng) + "**"
    if r < 0.95:
        return "[" + w(rng) + " " + w(rng) + "](" + url(rng) + ")"
    if r < 0.96:
        return "<" + url(rng) + ">"
    if r < 0.97:
        return "&amp;"
    if r < 0.98:
        return "_" + w(rng) + "_"
    return w(rng) + rng.choice([",", ".", ";", ":", "!", "?"])


def doc_sentence(rng):
    n = rng.randint(6, 20)
    s = " ".join(doc_inline(rng) for _ in range(n))
    return s[0].upper() + s[1:] + "." if s[0].isalpha() else w(rng).capitalize() + " " + s + "."


def doc_paragraph(rng, width=78):
    text = " ".join(doc_sentence(rng) for _ in range(rng.randint(2, 6)))
    lines, cur = [], ""
    for tok in text.split(" "):
        if cur and len(cur) + 1 + len(tok) > width:
            lines.append(cur)
            cur = tok
        else:
            cur = cur + " " + tok if cur else tok
    if cur:
        lines.append(cur)
    # A wrapped line that starts with a block marker would change the structure.
    fixed = []
    for ln in lines:
        if ln[0] in "-+*#>=_`~0123456789<[!&" or ln.startswith("    "):
            ln = w(rng) + " " + ln
        fixed.append(ln)
    return fixed


def code_lines(rng):
    out = []
    indent = 0
    for _ in range(rng.randint(3, 25)):
        r = rng.random()
        if r < 0.15 and indent < 12:
            out.append(" " * indent + "def %s(%s, %s):" % (rng.choice(IDENTS).split("(")[0].replace(".", "_"), w(rng), w(rng)))
            indent += 4
        elif r < 0.25 and indent:
            indent -= 4
            out.append(" " * indent + "}")
        elif r < 0.30:
            out.append("")
        else:
            out.append(" " * indent + "%s = %s(%s) %s &amp; \"%s\" * 2  # %s" % (
                w(rng), rng.choice(IDENTS), w(rng), "<b>", w(rng), w(rng)))
    return out


def doc_list(rng, depth):
    ordered = rng.random() < 0.35
    bullet = rng.choice("-*+")
    loose = rng.random() < 0.25
    out = []
    for i in range(rng.randint(2, 8)):
        marker = "%d." % (i + 1) if ordered else bullet
        pad = " " * (len(marker) + 1)
        para = doc_paragraph(rng, 70)[: rng.randint(1, 3)]
        out.append(marker + " " + para[0])
        out.extend(pad + ln for ln in para[1:])
        if depth < 3 and rng.random() < 0.25:
            if loose:
                out.append("")
            out.extend(pad + ln if ln else "" for ln in doc_list(rng, depth + 1))
        elif rng.random() < 0.08:
            out.append("")
            out.append(pad + "```" + rng.choice(LANGS))
            out.extend(pad + ln if ln else "" for ln in code_lines(rng))
            out.append(pad + "```")
        if loose and i:
            out.append("")
    while out and out[-1] == "":
        out.pop()
    return out


def doc_block(rng):
    r = rng.random()
    if r < 0.45:
        return doc_paragraph(rng)
    if r < 0.65:
        return doc_list(rng, 0)
    if r < 0.80:
        fence = rng.choice(["```", "```", "~~~"])
        return [fence + rng.choice(LANGS)] + code_lines(rng) + [fence]
    if r < 0.86:
        # The lead-in paragraph closes any preceding list, which would otherwise
        # absorb the indented lines as item content.
        code = ["    " + ln for ln in code_lines(rng) if ln][:8]
        return ["For example, run the following " + w(rng) + ":", ""] + code
    if r < 0.95:
        inner = doc_paragraph(rng)
        if rng.random() < 0.5:
            inner[0] = "**Note:** " + inner[0]
        out = ["> " + ln for ln in inner]
        if rng.random() < 0.3:
            out.append(">")
            out.extend("> " + ln for ln in doc_list(rng, 1))
        return out
    if r < 0.97:
        return ["---" if rng.random() < 0.5 else "* * *"]
    return [w(rng).capitalize() + " " + w(rng), rng.choice(["===", "---"])]


def docs_site(seed, TARGET=TARGET, MAX_BYTES=MAX_BYTES):
    rng = random.Random(seed)
    lines = []
    size = 0
    page = 0
    while size < TARGET:
        b = []
        if rng.random() < 0.08:
            page += 1
            b.append("# Chapter %d: %s %s" % (page, w(rng).capitalize(), w(rng)))
        elif rng.random() < 0.25:
            b.append("#" * rng.randint(2, 4) + " " + " ".join(doc_inline(rng) for _ in range(rng.randint(1, 6))))
        else:
            b.extend(doc_block(rng))
        if size + sum(len(x.encode("utf-8")) + 1 for x in b) > MAX_BYTES - 2000:
            break
        lines.extend(b)
        lines.append("")
        size += sum(len(x.encode("utf-8")) + 1 for x in b) + 1
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 002: inline-dense prose (delimiter / bracket / code-span algorithms)
# ---------------------------------------------------------------------------
def dense_atom(rng, depth=0):
    r = rng.random()
    if r < 0.38:
        return w(rng)
    if r < 0.46:
        # Nested emphasis of every flavour, closed most of the time.
        d = rng.choice(["*", "**", "_", "__", "***", "*", "**"])
        inner = " ".join(dense_atom(rng, depth + 1) if depth < 3 else w(rng) for _ in range(rng.randint(1, 4)))
        if inner[0] in " " or inner[-1] in " ":
            inner = w(rng)
        if rng.random() < 0.9:
            return d + inner + d
        return d + inner             # unmatched opener
    if r < 0.50:
        # Intraword delimiters: snake_case and arithmetic.
        return rng.choice(["snake_case_name", "a_b_c_d", "__dunder__", "2*3*4", "x**2", "foo*bar*baz", "a*b**c"])
    if r < 0.57:
        n = rng.choice([1, 1, 1, 2, 3])
        t = "`" * n
        inner = rng.choice([rng.choice(PLAIN_IDENTS), w(rng) + " *" + w(rng) + "* [x](y)", "` " + w(rng) if n > 1 else w(rng),
                            "a_b_c", "x < y && y > z"])
        if rng.random() < 0.95:
            return t + inner + t
        return t + w(rng)            # unmatched backtick run
    if r < 0.67:
        depth_text = " ".join(dense_atom(rng, depth + 1) if depth < 2 else w(rng) for _ in range(rng.randint(1, 4)))
        dest = rng.choice([url(rng), "/" + w(rng), "<" + url(rng) + " " + w(rng) + ">", "/a(b)c", "/x\\)y"])
        ttl = rng.choice(["", "", ' "' + w(rng) + " " + w(rng) + '"', " '" + w(rng) + "'", " (" + w(rng) + ")"])
        bang = "!" if rng.random() < 0.2 else ""
        if dest.startswith("<"):
            depth_text = w(rng)     # the '<' form must stay inside a link that parses
            return bang + "[" + depth_text + "](" + dest + ttl + ")"
        if rng.random() < 0.92:
            return bang + "[" + depth_text + "](" + dest + ttl + ")"
        return "[" + depth_text + "]"   # literal brackets
    if r < 0.70:
        return "<" + url(rng) + ">"
    if r < 0.74:
        return rng.choice(["&amp;", "&lt;", "&gt;", "&quot;", "&#169;", "&#x2014;", "&nbsp", "AT&T"])
    if r < 0.78:
        return rng.choice(["\\*", "\\_", "\\`", "\\[", "\\]", "\\\\", "\\#", "\\<", "\\&"])
    if r < 0.82:
        return rng.choice(["(", ")", "[", "]", "!", "*", "_", "-", ":", "\""]) + w(rng)
    return w(rng) + rng.choice([",", ".", ";", ":", "!", "?", ")"])


def dense_paragraph(rng):
    toks = [dense_atom(rng) for _ in range(rng.randint(150, 900))]
    lines, cur = [], ""
    for tok in toks:
        if cur and len(cur) + 1 + len(tok) > 90:
            lines.append(cur + rng.choice(["", "", "", "", "  ", "\\"]))
            cur = tok
        else:
            cur = cur + " " + tok if cur else tok
    lines.append(cur)
    lines = [w(rng) + " " + ln for ln in lines]   # never start a line with a block marker
    if lines[-1].endswith("\\"):
        lines[-1] = lines[-1][:-1]
    return lines


def inline_dense(seed, TARGET=TARGET, MAX_BYTES=MAX_BYTES):
    rng = random.Random(seed)
    lines = []
    size = 0
    while size < TARGET:
        b = dense_paragraph(rng)
        if size + sum(len(x.encode("utf-8")) + 1 for x in b) > MAX_BYTES - 2000:
            break
        if rng.random() < 0.1:
            b = ["## " + " ".join(dense_atom(rng, 2) for _ in range(rng.randint(2, 6))), ""] + b
        lines.extend(b)
        lines.append("")
        size += sum(len(x.encode("utf-8")) + 1 for x in b) + 1
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# 003: random documents mixing every construct (gen_tests generator)
# ---------------------------------------------------------------------------
def mixed_random(seed):
    target = TARGET
    while True:
        text = gen_document(seed, target)
        if len(text.encode("utf-8")) <= MAX_BYTES:
            return text
        target -= 5000


def mixed_random_long(first_seed, total):
    """Long tier: whole gen_document documents (as in 003) from consecutive
    seeds, skipping any that leave the subset, joined until `total` bytes."""
    parts, size, seed = [], 0, first_seed
    while True:
        text = mixed_random(seed)
        seed += 1
        if subset_violation(text.encode("utf-8")) is not None:
            continue
        n = len(text.encode("utf-8")) + 1
        if size + n > total:
            return "\n".join(parts)
        parts.append(text)
        size += n


# Long tier (--long, written to ../bench-long): the same three documents,
# 16x larger (SPEC.md's input limit is raised to 16 MB for it).
LONG_MAX_BYTES = 16_000_000
LONG_TARGET = 15_900_000
LONG_CASES = [
    ("docs_site", lambda: docs_site(1001, LONG_TARGET, LONG_MAX_BYTES)),
    ("inline_dense", lambda: inline_dense(2002, LONG_TARGET, LONG_MAX_BYTES)),
    ("mixed_random", lambda: mixed_random_long(3005, LONG_TARGET)),
]

CASES = [
    ("docs_site", lambda: docs_site(1001)),
    ("inline_dense", lambda: inline_dense(2002)),
    # Seeds 3003 and 3004 produce a '<' that cmark could read as raw HTML.
    ("mixed_random", lambda: mixed_random(3005)),
]


def run(cmd, data):
    proc = subprocess.run(cmd, input=data, capture_output=True, timeout=900)
    assert proc.returncode == 0, proc.stderr.decode()
    return proc.stdout


def main():
    long_tier = "--long" in sys.argv[1:]
    out_dir = os.path.join(PROBLEM, "bench-long") if long_tier else HERE
    limit = LONG_MAX_BYTES if long_tier else MAX_BYTES
    os.makedirs(out_dir, exist_ok=True)
    for f in os.listdir(out_dir):
        if f.endswith(".in") or f.endswith(".out"):
            os.remove(os.path.join(out_dir, f))
    have_cmark = shutil.which(CMARK) is not None
    for idx, (name, make) in enumerate(LONG_CASES if long_tier else CASES, 1):
        data = make().encode("utf-8")
        assert len(data) <= limit, (name, len(data))
        bad = subset_violation(data)
        assert bad is None, "%s violates the subset: %s" % (name, bad)
        expected = run([sys.executable, REF], data)
        if have_cmark and run([CMARK], data) != expected:
            sys.exit("ORACLE DISAGREEMENT on %s" % name)
        base = "%03d_%s" % (idx, name)
        with open(os.path.join(out_dir, base + ".in"), "wb") as f:
            f.write(data)
        with open(os.path.join(out_dir, base + ".out"), "wb") as f:
            f.write(expected)
        print("%-24s %8d bytes in %8d bytes out%s" % (base, len(data), len(expected),
                                                      "  (cmark agrees)" if have_cmark else ""))


if __name__ == "__main__":
    main()
