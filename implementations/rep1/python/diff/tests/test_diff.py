import random

import pytest

from myersdiff import Edit, cost, diff, new_lines, old_lines


def lcs_len(a, b):
    prev = [0] * (len(b) + 1)
    for x in a:
        cur = [0]
        for j, y in enumerate(b):
            cur.append(prev[j] + 1 if x == y else max(prev[j + 1], cur[j]))
        prev = cur
    return prev[-1]


def check(a, b):
    script = diff(a, b)
    assert old_lines(script) == list(a)
    assert new_lines(script) == list(b)
    assert cost(script) == len(a) + len(b) - 2 * lcs_len(a, b)
    return script


def test_paper_example():
    assert cost(check(list("abcabba"), list("cbabac"))) == 5


def test_empty_inputs():
    assert diff([], []) == []
    assert diff([], ["x"]) == [Edit("+", "x")]
    assert diff(["x"], []) == [Edit("-", "x")]


def test_identical_is_all_keeps():
    script = diff(["a", "", " "], ["a", "", " "])
    assert script == [Edit(" ", "a"), Edit(" ", ""), Edit(" ", " ")]


def test_whitespace_significant():
    script = check(["a ", "b"], ["a", "b "])
    assert cost(script) == 4


def test_disjoint():
    a = [f"a{i}" for i in range(50)]
    b = [f"b{i}" for i in range(37)]
    assert cost(check(a, b)) == 87


@pytest.mark.parametrize("seed", range(300))
def test_random_small_alphabet(seed):
    rng = random.Random(seed)
    alpha = rng.choice([1, 2, 3, 5, 20])
    a = [str(rng.randrange(alpha)) for _ in range(rng.randrange(0, 25))]
    b = [str(rng.randrange(alpha)) for _ in range(rng.randrange(0, 25))]
    check(a, b)


@pytest.mark.parametrize("seed", range(20))
def test_random_edits_of_a_file(seed):
    rng = random.Random(1000 + seed)
    a = [str(rng.randrange(40)) for _ in range(300)]
    b = list(a)
    for _ in range(rng.randrange(1, 30)):
        op = rng.randrange(3)
        i = rng.randrange(len(b) + 1)
        if op == 0:
            b.insert(i, str(rng.randrange(40)))
        elif i < len(b):
            if op == 1:
                del b[i]
            else:
                b[i] = str(rng.randrange(40))
    check(a, b)
