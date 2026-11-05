#!/usr/bin/env python3
"""Generate tests/*.in and tests/*.out for the `diff` problem.

Hand-written edge cases are embedded as literals; random families are built
with fixed seeds. Every .out is the reference implementation's stdout. For
diff-mode tests the reference's edit count is cross-checked against an
independent bit-parallel LCS (from verify.py) and, where N*M is small enough,
against a plain O(NM) dynamic-programming LCS.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TESTS = os.path.join(HERE, "tests")
REF = os.path.join(HERE, "reference", "main.py")
sys.path.insert(0, HERE)
from verify import lcs_length, parse_output  # noqa: E402

WORDS = ("alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi "
         "omicron pi rho sigma tau upsilon phi chi psi omega int return if else "
         "while for struct void char static const").split()


def diff_input(a, b):
    return "\n".join(["diff", str(len(a))] + a + [str(len(b))] + b) + "\n"


def patch_input(a, script):
    return "\n".join(["patch", str(len(a))] + a + [str(len(script))] + script) + "\n"


def rand_line(rng, vocab=None):
    if vocab is not None:
        return rng.choice(vocab)
    k = rng.randint(1, 6)
    line = " ".join(rng.choice(WORDS) for _ in range(k))
    r = rng.random()
    if r < 0.05:
        line = "    " + line
    elif r < 0.08:
        line = line + "  "
    elif r < 0.10:
        line = ""
    return line


def rand_file(rng, n, vocab=None):
    return [rand_line(rng, vocab) for _ in range(n)]


def mutate(rng, a, p_del, p_rep, p_ins, vocab=None):
    """Derive a new file from a by deleting, replacing and inserting lines with
    the given per-line probabilities."""
    b = []
    for line in a:
        r = rng.random()
        if r < p_del:
            continue
        if r < p_del + p_rep:
            b.append(rand_line(rng, vocab))
        else:
            b.append(line)
        if rng.random() < p_ins:
            b.append(rand_line(rng, vocab))
    return b


def rand_script(rng, a, p_del, p_ins, vocab=None):
    """A valid (not necessarily minimal) edit script over a."""
    script = []
    for line in a:
        if rng.random() < p_del:
            script.append("-" + line)
            if rng.random() < 0.5:
                script.append("+" + rand_line(rng, vocab))
        else:
            script.append(" " + line)
        if rng.random() < p_ins:
            script.append("+" + rand_line(rng, vocab))
    return script


def dp_lcs(a, b):
    m = len(b)
    prev = [0] * (m + 1)
    for x in a:
        cur = [0] * (m + 1)
        for j in range(m):
            cur[j + 1] = prev[j] + 1 if x == b[j] else max(prev[j + 1], cur[j])
        prev = cur
    return prev[m]


def build_cases():
    cases = []  # (name, input_text, a, b_or_None)

    def d(name, a, b):
        cases.append((name, diff_input(a, b), a, b))

    def p(name, a, script):
        cases.append((name, patch_input(a, script), a, None))

    d("001_diff_empty_both", [], [])
    d("002_diff_empty_to_lines", [], ["alpha", "beta", "gamma"])
    d("003_diff_lines_to_empty", ["alpha", "beta", "gamma"], [])
    d("004_diff_identical_one_line", ["hello"], ["hello"])
    d("005_diff_replace_one_line", ["hello"], ["world"])
    d("006_diff_identical_multi", ["a", "b", "c", "d"], ["a", "b", "c", "d"])
    d("007_diff_complete_replacement", ["one", "two", "three"], ["four", "five", "six", "seven"])
    d("008_diff_insert_middle", ["a", "b", "d"], ["a", "b", "c", "d"])
    d("009_diff_delete_middle", ["a", "b", "c", "d"], ["a", "d"])
    d("010_diff_duplicate_lines", ["x", "x", "x", "y", "x", "x"], ["x", "y", "x", "x", "x", "y"])
    d("011_diff_whitespace_lines",
      ["  indented", "trailing ", "trailing", " both ", "plain"],
      ["  indented", "trailing", "trailing ", " both", "plain", " "])
    d("012_diff_empty_lines", ["", "a", "", "", "b", ""], ["a", "", "b", "", "", ""])
    d("013_diff_myers_paper", list("abcabba"), list("cbabac"))
    d("014_diff_block_move", ["h1", "h2", "x", "y", "z", "t1", "t2"], ["h1", "h2", "t1", "t2", "x", "y", "z"])
    # "é" precomposed (U+00E9) versus "e" + combining acute (U+0301): canonically
    # equivalent but different bytes, so they are different lines.
    d("015_diff_unicode", ["héllo wörld", "日本語の行", "emoji 🎉 line", "tab\tinside", "caf\u00e9"],
      ["héllo wörld", "emoji 🎉 line", "日本語の行", "tab\tinside", "cafe\u0301", "ünïcödé"])
    # Content that looks like counts and tags: read by the declared counts only.
    d("016_diff_tag_lookalike_lines", ["5", "-", "+", " ", "+1", "-x", "  ", "3"],
      ["5", " ", "-", "+", "-x", "+1", "  ", "0"])

    p("017_patch_empty", [], [])
    p("018_patch_all_inserts", [], ["+alpha", "+beta", "+"])
    p("019_patch_all_deletes", ["alpha", "beta", "gamma"], ["-alpha", "-beta", "-gamma"])
    p("020_patch_mixed", ["a", "b", "c", "d", "e"], [" a", "-b", "+B", " c", "+c2", "-d", " e", "+f"])
    p("021_patch_non_minimal", ["x", "y", "z"], ["-x", "+x", "+y", "-y", " z", "+z"])
    p("022_patch_whitespace", ["  lead", "trail  ", "", " "], ["   lead", "-trail  ", "+trail", " ", "+ x ", "- ", "+"])
    p("023_patch_keep_only", ["k1", "k2", "k3"], [" k1", " k2", " k3"])
    p("024_patch_tag_lookalike_lines", ["-", "+", " ", "3", "+x", "-y"],
      [" -", "+-", "-+", "+ ", "  ", "+", " 3", "+4", " +x", "--y", "+-y", "+ "])

    rng = random.Random(20240917)
    a = rand_file(rng, 50)
    d("025_diff_random_small", a, mutate(rng, a, 0.15, 0.15, 0.15))
    a = rand_file(rng, 300)
    d("026_diff_random_medium", a, mutate(rng, a, 0.1, 0.1, 0.1))
    a = rand_file(rng, 500)
    d("027_diff_swap_halves_500", a, a[250:] + a[:250])
    a = rand_file(rng, 1000)
    p("028_patch_random_1000", a, rand_script(rng, a, 0.2, 0.15))
    vocab = ["a", "b"]
    d("029_diff_binary_alphabet_1000", rand_file(rng, 1000, vocab), rand_file(rng, 1000, vocab))
    vocab = ["x", "y", "z", "w"]
    a = rand_file(rng, 1500, vocab)
    d("030_diff_small_alphabet_1500", a, mutate(rng, a, 0.2, 0.2, 0.2, vocab))
    a = rand_file(rng, 2000)
    d("031_diff_2000_quarter_edits", a, mutate(rng, a, 0.12, 0.13, 0.12))
    a = rand_file(rng, 2000)
    d("032_diff_2000_heavy_edits", a, mutate(rng, a, 0.3, 0.3, 0.35))
    a = ["A%05d" % i for i in range(1500)]
    d("033_diff_disjoint_1500", a, ["B%05d" % i for i in range(1500)])
    a = rand_file(rng, 5000)
    d("034_diff_5000_sparse_edits", a, mutate(rng, a, 0.004, 0.004, 0.004))
    a = rand_file(rng, 5000)
    b = list(a)
    b[2500] = "the only changed line"
    d("035_diff_5000_single_change", a, b)
    a = rand_file(rng, 5000)
    p("036_patch_random_5000", a, rand_script(rng, a, 0.1, 0.1))
    a = rand_file(rng, 4000)
    d("037_diff_4000_mixed_edits", a, mutate(rng, a, 0.08, 0.08, 0.08))
    return cases


def main():
    os.makedirs(TESTS, exist_ok=True)
    for old in os.listdir(TESTS):
        if old.endswith((".in", ".out")):
            os.remove(os.path.join(TESTS, old))
    for name, text, a, b in build_cases():
        with open(os.path.join(TESTS, name + ".in"), "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        proc = subprocess.run([sys.executable, REF], input=text.encode("utf-8"), capture_output=True, check=True)
        out = proc.stdout.decode("utf-8")
        with open(os.path.join(TESTS, name + ".out"), "w", encoding="utf-8", newline="\n") as f:
            f.write(out)
        info = f"{name}: {len(text)} bytes in, {len(out)} bytes out"
        if b is not None:
            script = parse_output(out, name)
            edits = sum(1 for line in script if line[0] != " ")
            minimum = len(a) + len(b) - 2 * lcs_length(a, b)
            assert edits == minimum, f"{name}: reference produced {edits} edits, bit-parallel LCS says {minimum}"
            info += f", D={edits}"
            if len(a) * len(b) <= 1_500_000:
                dp_min = len(a) + len(b) - 2 * dp_lcs(a, b)
                assert dp_min == minimum, f"{name}: DP LCS says {dp_min}, bit-parallel says {minimum}"
                info += " (DP-checked)"
        print(info)


if __name__ == "__main__":
    main()
