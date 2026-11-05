#!/usr/bin/env python3
"""Generates the performance benchmark inputs for the "regex" problem.

Writes bench/NNN_name.in and bench/NNN_name.out in the same layout as tests/,
so `run_tests.py regex --tests-dir problems/regex/bench` runs them. All inputs
use fixed seeds. Expected outputs come from reference/main.py and every file
is cross-checked against Python's `re` module (re.ASCII), which agrees with
the SPEC's semantics on this subset.

Usage: python3 gen_bench.py [--no-ref]   (--no-ref writes outputs from `re`
only, for quick iteration; the published outputs use the reference)
"""
import os
import random
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROBLEM = os.path.dirname(HERE)
sys.dont_write_bytecode = True

FILES = []  # (name, [(pattern, [subjects])])


def add(name, cases):
    FILES.append((name, cases))


# ---------------------------------------------------------------------------
# Shared text generators
# ---------------------------------------------------------------------------

WORDS = ["alpha", "beta", "gamma", "delta", "foo", "bar", "baz", "qux", "lorem", "ipsum",
         "request", "response", "timeout", "retry", "user", "admin", "root", "guest",
         "session", "cache", "worker", "queue", "disk", "memory", "socket", "handler"]
LEVELS = ["DEBUG", "INFO", "INFO", "INFO", "WARN", "ERROR"]
TLDS = ["com", "org", "net", "io", "co.uk"]
METHODS = ["GET", "POST", "PUT", "DELETE"]


class Text:
    def __init__(self, rng):
        self.rng = rng

    def word(self):
        return self.rng.choice(WORDS)

    def email(self):
        r = self.rng
        return "%s%s%s@%s.%s" % (self.word(), r.choice(["", ".", "_"]), r.choice(["", "42", "7"]),
                                 self.word(), r.choice(TLDS))

    def ip(self):
        return ".".join(str(self.rng.randint(0, 255)) for _ in range(4))

    def date(self):
        r = self.rng
        return "%04d-%02d-%02d" % (r.randint(2015, 2026), r.randint(1, 12), r.randint(1, 28))

    def time(self):
        r = self.rng
        return "%02d:%02d:%02d.%03d" % (r.randint(0, 23), r.randint(0, 59), r.randint(0, 59), r.randint(0, 999))

    def path(self):
        r = self.rng
        return "/" + "/".join(self.word() for _ in range(r.randint(1, 4))) + r.choice(["", ".html", ".json", "?id=%d" % r.randint(1, 99999)])

    def number(self):
        r = self.rng
        return r.choice(["", "-"]) + str(r.randint(0, 99999)) + r.choice(["", ".5", ".25"])

    def kv(self):
        r = self.rng
        v = r.choice([self.word(), str(r.randint(0, 9999)), '"%s %s"' % (self.word(), self.word())])
        return "%s=%s" % (self.word(), v)

    def token(self):
        x = self.rng.random()
        if x < 0.45:
            return self.word()
        if x < 0.55:
            return self.kv()
        if x < 0.62:
            return self.number()
        if x < 0.68:
            return self.ip()
        if x < 0.73:
            return self.email()
        if x < 0.78:
            return self.path()
        if x < 0.82:
            return self.date()
        return self.rng.choice(["-", ",", ";", ":", "(%s)" % self.word(), "[%s]" % self.word(), "#%d" % self.rng.randint(1, 999)])

    def log_line(self, ntok):
        r = self.rng
        head = "%s %s %-5s [%s-%d] " % (self.date(), self.time(), r.choice(LEVELS), self.word(), r.randint(1, 16))
        return head + " ".join(self.token() for _ in range(ntok))

    def access_line(self):
        r = self.rng
        return '%s - %s [%s %s] "%s %s HTTP/1.1" %d %d "%s"' % (
            self.ip(), r.choice(["-", self.word()]), self.date(), self.time(), r.choice(METHODS), self.path(),
            r.choice([200, 200, 200, 301, 304, 404, 500]), r.randint(0, 99999), self.email())

    def csv_line(self, nfields):
        r = self.rng
        fields = []
        for _ in range(nfields):
            x = r.random()
            if x < 0.4:
                fields.append(self.word())
            elif x < 0.7:
                fields.append(self.number())
            elif x < 0.8:
                fields.append(self.date())
            else:
                fields.append(self.email())
        return ",".join(fields)


# ---------------------------------------------------------------------------
# 001: throughput over large ordinary log text
# ---------------------------------------------------------------------------

def log_throughput(seed, n_lines=64):
    """Long log lines (a few thousand characters each, as from batched or
    multi-record log lines) scanned by a typical set of extraction and
    filter patterns. Most patterns match only rarely or late, so the engine
    walks most start positions of most subjects."""
    t = Text(random.Random(seed))
    subjects = [t.log_line(t.rng.randint(300, 900)) for _ in range(n_lines)]
    kw = "|".join(WORDS)
    patterns = [
        "(\\w+) (\\w+) (timeout|refused|reset|denied|unreachable|overflow|exhausted|corrupt)",
        "(" + kw + ")=(\\d{5,})",
        "(\\S+) (\\S+) (ERROR|FATAL) \\[(\\w+)-(\\d+)\\]",
        "([a-z0-9_.]+)@([a-z0-9]+)\\.(org|io) ([a-z]+)=",
        "([A-Za-z]+)(\\d+)\\.(\\d+)\\.",
        "(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3}) (" + kw + ") (\\w+)",
        "(\\w+)=\"(\\w+) (\\w+)\" (\\w+)=(\\d+) (\\w+)=\"",
        "/(\\w+)/(\\w+)/(\\w+)/(\\w+)\\.json\\?id=(\\d+) #",
        "\\[(" + kw + ")\\] (\\w+)=(\\w+) ",
        "([a-z]+) ([a-z]+) ([a-z]+) ([a-z]+) (-\\d+\\.\\d+)",
    ]
    return [(p, subjects) for p in patterns]


add("001_log_throughput", lambda: log_throughput(1001))


# ---------------------------------------------------------------------------
# 002: backtracking-heavy realistic patterns
# ---------------------------------------------------------------------------

def backtracking_heavy(seed, k=1):
    """Patterns written the way people commonly write them, with greedy `.*`
    captures, overlapping alternations and nested (but not exponential)
    quantifiers, over medium-length records. Each subject forces real
    backtracking: greedy runs overshoot and give characters back, and failing
    searches retry the pattern at every start position."""
    t = Text(random.Random(seed))
    r = t.rng
    csv = [t.csv_line(r.randint(10, 40)) for _ in range(300 * k)]
    logs = [t.log_line(r.randint(20, 120)) for _ in range(300 * k)]
    access = [t.access_line() for _ in range(1500 * k)]
    kvs = [" ".join(t.kv() for _ in range(r.randint(10, 60))) for _ in range(300 * k)]
    cases = [
        ("^(.*),(.*),(.*),(.*)$", csv),
        ("^(.*),(.*),(.*)\\.(json|xml)$", csv),
        ("^([^,]*),([^,]*),(.*),([^,]*)@(.*)$", csv),
        ("(.*),(\\d+\\.\\d+),(.*)", csv),
        ("^(.*)(\\d{4})-(\\d\\d)-(\\d\\d)(.*)$", csv),
        ("^(\\S+) (\\S+) (\\S+) +\\[(.*)\\] (.*) (.*) (.*)$", logs),
        ("^(.*) (ERROR|WARN) (.*)(timeout|retry)(.*)$", logs),
        ("^(.*)=\"(.*)\"(.*)=(\\d+)$", logs),
        ("^.*(lorem|ipsum).*(lorem|ipsum).*(lorem|ipsum).*FATAL", logs),
        ("^(\\d+\\.\\d+\\.\\d+\\.\\d+) - (\\S+) \\[(.*)\\] \"(\\w+) (.*) HTTP/1\\.1\" (\\d+) (\\d+) \"(.*)@(.*)\"$", access),
        ("^(.*)\"(GET|POST) (/.*)+ (.*)\" (404|500) (.*)$", access),
        ("(.*) \\[(.*)\\] \"(.*)\" (.*) (.*) \"(.*)\\.(net|io)\"", access),
        ("((\\w+)=(\\w+|\"[^\"]*\") ?)+$", kvs),
        ("^(.*)=(.*) (\\w+)=(\\d+)$", kvs),
        ("^((\\w+)=(\\d+) )*(\\w+)=\"", kvs),
    ]
    return cases


add("002_backtracking_heavy", lambda: backtracking_heavy(2002))


# ---------------------------------------------------------------------------
# 003: many patterns, many short subjects
# ---------------------------------------------------------------------------

def make_gen(rng, alpha, class_pool, group_prob, max_depth, max_pieces):
    """Random pattern generator (same shape as gen_tests.py's fuzz patterns)."""
    def atom(depth):
        x = rng.random()
        if x < 0.35:
            return rng.choice(alpha)
        if x < 0.45:
            return "."
        if x < 0.55:
            return rng.choice(class_pool)
        if x < 0.60:
            return rng.choice(["^", "$"])
        if depth > 0 and rng.random() < group_prob:
            return "(" + alt(depth - 1) + ")"
        return rng.choice(alpha)

    def quant():
        x = rng.random()
        if x < 0.5:
            return ""
        if x < 0.62:
            return "*"
        if x < 0.74:
            return "+"
        if x < 0.86:
            return "?"
        a = rng.randint(0, 4)
        b = a + rng.randint(0, 4)
        return rng.choice(["{%d}" % a, "{%d,}" % a, "{%d,%d}" % (a, b)])

    def seq(depth):
        out = []
        for _ in range(rng.randint(1, max_pieces)):
            a = atom(depth)
            out.append(a + (quant() if a not in ("^", "$") else ""))
        return "".join(out)

    def alt(depth):
        return "|".join(seq(depth) for _ in range(rng.randint(1, 3)))

    return lambda: alt(max_depth)


def escape_literal(c):
    return "\\" + c if c in "\\.[]()|*+?{}^$" else c


CLASSES = ["[ab]", "[^a]", "[a-c]", "\\w", "\\d", "\\s", "\\W", "\\D", "\\S",
           "[\\d_]", "[^\\w ]", "[a-c1-3]", "[ -/]", "[^\\s]", "[\\-.]", "[a-z]"]

# Templates for realistic validation/extraction patterns; {} slots are
# filled with small random counts so each pattern is distinct.
TEMPLATES = [
    "^([a-z0-9_.]+)@([a-z0-9]+)\\.([a-z]{{2,{0}}})$",
    "(\\d{{1,3}})\\.(\\d{{1,3}})\\.(\\d{{1,3}})\\.(\\d{{1,{0}}})",
    "^(\\d{{4}})-(\\d{{2}})-(\\d{{2}})( (\\d{{2}}):(\\d{{2}}))?{1}",
    "(\\w+)=(\"([^\"]*)\"|\\w{{1,{0}}})",
    "^(\\+|-)?(\\d{{1,{0}}})(\\.(\\d*))?$",
    "(\\S+)\\s+(\\S+)\\s+(\\S{{{0},}})",
    "^([^ ]+ ){{{0}}}(\\w+)",
    "(alpha|beta|gamma|delta|foo|bar){{1,{0}}} (\\w+)",
    "[a-z]{{{0},}}\\d{{1,{1}}}",
    "^(.*) (\\w{{{0}}})$",
    "((\\w+)\\.){{1,{0}}}(com|org|net|io)",
    "(\\d+)(,\\d{{3}}){{0,{0}}}(\\.\\d+)?",
    "^(\\w+)( \\w+){{{0},{1}}}$",
    "(/[a-z]+){{{0},}}(\\.json|\\.html)?",
    "^\\s*(\\w+)\\s*[:=]\\s*(.{{0,{1}}})$",
]


def many_patterns(seed, k=1):
    """The maximum 500 patterns, each with 200 short subjects (the maximum
    100000 subjects in total): a mix of realistic validation/extraction
    patterns over short records and random patterns (groups, alternation,
    classes, counted repeats, anchors) over short strings. Measures pattern
    compilation, per-subject setup and capture bookkeeping rather than one
    long scan."""
    rng = random.Random(seed)
    t = Text(rng)
    sys.path.insert(0, os.path.join(PROBLEM, "reference"))
    import main as ref

    def record():
        x = rng.random()
        if x < 0.2:
            return t.email()
        if x < 0.35:
            return t.ip() + rng.choice(["", ":%d" % rng.randint(1, 65535)])
        if x < 0.5:
            return t.date() + rng.choice(["", " %02d:%02d" % (rng.randint(0, 23), rng.randint(0, 59))])
        if x < 0.6:
            return t.number()
        if x < 0.7:
            return t.path()
        if x < 0.8:
            return "%s %s %s" % (t.word(), rng.choice([":", "=", " = "]), t.word())
        return " ".join(t.token() for _ in range(rng.randint(3, 24)))

    cases = []
    for i in range(250 * k):
        tpl = TEMPLATES[i % len(TEMPLATES)]
        lo = rng.randint(2, 9)
        pat = tpl.format(lo, lo + rng.randint(1, 12))
        subs = [record() for _ in range(200)]
        cases.append((pat, subs))

    gen = make_gen(rng, [escape_literal(c) for c in "abc1 _."], CLASSES, 0.8, 3, 5)
    alpha = "abcc1 _."
    while len(cases) < 500 * k:
        pat = gen()
        if len(pat) > 250 or len(pat) < 6:
            continue
        subs = ["".join(rng.choice(alpha) for _ in range(rng.randint(0, 60))) for _ in range(200)]
        rx = ref.Regex(pat)
        rx.budget = 20000
        total = 0
        try:
            for s in subs:
                rx.search(s)
                total += rx.backtracks
        except ref.BudgetExceeded:
            continue
        # Keep patterns that do a moderate amount of backtracking: trivial
        # ones (an early literal that rarely occurs) would measure only I/O.
        if total < 50000:
            continue
        cases.append((pat, subs))
    rng.shuffle(cases)
    return cases


add("003_many_patterns", lambda: many_patterns(3003))

# Long tier (bench-long/): the same three workloads scaled up: more log lines
# for 001, more records of every kind for 002, more patterns (same 200
# subjects each) for 003. 002 and 003 are sized so the fastest implementation
# needs >= 5 s; 001 repeats its subjects for every pattern, so disk, not time,
# bounds it (see NOTES.md). SPEC.md's size limits are raised to match.
LONG_FILES = [
    ("001_log_throughput", lambda: log_throughput(1001, n_lines=64 * 20)),
    ("002_backtracking_heavy", lambda: backtracking_heavy(2002, k=44)),
    ("003_many_patterns", lambda: many_patterns(3003, k=26)),
]
LIMITS = (500, 100000, 4 * 1024 * 1024)
LONG_LIMITS = (15000, 3000000, 200 * 1024 * 1024)


# ---------------------------------------------------------------------------
# Emit and verify
# ---------------------------------------------------------------------------

def encode(cases):
    lines = [str(len(cases))]
    for pat, subs in cases:
        lines.append(pat)
        lines.append(str(len(subs)))
        lines.extend(subs)
    return "\n".join(lines) + "\n"


def re_expected(cases):
    """Independent expected output from Python's re, in the SPEC's output format."""
    out = []
    for pat, subs in cases:
        c = re.compile(pat, re.ASCII)
        for s in subs:
            m = c.search(s)
            if m is None:
                out.append("no")
                continue
            parts = ["match %d %d" % m.span()]
            for g in range(1, c.groups + 1):
                a, b = m.span(g)
                parts.append("-" if a < 0 else "%d,%d" % (a, b))
            out.append("|".join(parts))
    return out


def check_limits(name, cases, data, limits=LIMITS):
    max_patterns, max_subjects, max_bytes = limits
    assert 1 <= len(cases) <= max_patterns, name
    assert sum(len(s) for _, s in cases) <= max_subjects, name
    assert len(data) <= max_bytes, (name, len(data))
    for pat, subs in cases:
        assert len(pat) <= 300, (name, pat)
        assert pat.count("(") - pat.count("\\(") <= 50, (name, pat)
        assert all(32 <= ord(ch) <= 126 for ch in pat), (name, pat)
        assert all(len(s) <= 10000 for s in subs), name
        assert all(32 <= ord(ch) <= 126 for s in subs for ch in s), name


def main():
    use_ref = "--no-ref" not in sys.argv
    long_tier = "--long" in sys.argv
    files, limits, out_dir = FILES, LIMITS, HERE
    if long_tier:
        files, limits = LONG_FILES, LONG_LIMITS
        out_dir = os.path.join(PROBLEM, "bench-long")
        os.makedirs(out_dir, exist_ok=True)
    only = [a for a in sys.argv[1:] if not a.startswith("--")]
    for name, build in files:
        if only and not any(name.startswith(o) for o in only):
            continue
        cases = build()
        data = encode(cases)
        check_limits(name, cases, data, limits)
        with open(os.path.join(out_dir, name + ".in"), "w") as f:
            f.write(data)
        expected = re_expected(cases)
        out = "\n".join(expected) + "\n"
        if use_ref:
            proc = subprocess.run([sys.executable, os.path.join(PROBLEM, "reference", "main.py")],
                                  input=data.encode(), capture_output=True, check=True)
            got = proc.stdout.decode()
            if got != out:
                a, b = got.split("\n"), out.split("\n")
                for i, (x, y) in enumerate(zip(a, b)):
                    if x != y:
                        sys.exit("CROSS-CHECK MISMATCH in %s line %d: ref=%r re=%r" % (name, i + 1, x, y))
                sys.exit("CROSS-CHECK MISMATCH in %s (length)" % name)
        with open(os.path.join(out_dir, name + ".out"), "w") as f:
            f.write(out)
        print("%-26s %3d patterns %6d subjects %8d bytes" % (
            name, len(cases), sum(len(s) for _, s in cases), len(data)))
        sys.stdout.flush()


if __name__ == "__main__":
    main()
