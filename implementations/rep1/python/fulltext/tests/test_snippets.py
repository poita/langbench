from fulltext.snippets import best_window, collapse_whitespace


def test_short_document_starts_at_zero():
    assert best_window(10, [(1, [9])]) == 0


def test_no_occurrences():
    assert best_window(100, []) == 0


def test_prefers_distinct_atoms_then_count_then_earliest():
    # atom A at 0, 1, 2 (three occurrences); atoms A and B together at 50 and 60
    occ = [(1, [0, 1, 2, 50]), (1, [60])]
    assert best_window(100, occ) == 31  # window 31..60 holds A@50 and B@60
    assert best_window(100, [(1, [0, 1, 2, 50])]) == 0  # more occurrences wins


def test_window_clamped_to_document_end():
    assert best_window(40, [(1, [39])]) == 10


def test_atom_longer_than_window_never_counts():
    assert best_window(100, [(31, [5])]) == 0


def test_phrase_must_fit_inside():
    # a 2-term atom at 29 straddles window 0 (tokens 0..29): the first window
    # that holds it entirely starts at 1
    assert best_window(100, [(2, [29])]) == 1


def test_collapse_whitespace():
    assert collapse_whitespace("a \n\t b\u00a0\u00a0c  d") == "a b c d"


def _brute(length, occurrences, width=30):
    if length <= width:
        return 0
    best, best_key = 0, (-1, -1)
    for s in range(length - width + 1):
        atoms = total = 0
        for n, positions in occurrences:
            inside = [p for p in positions if p >= s and p + n - 1 <= s + width - 1]
            atoms += bool(inside)
            total += len(inside)
        if (atoms, total) > best_key:
            best, best_key = s, (atoms, total)
    return best


def test_matches_brute_force():
    import random

    rng = random.Random(1)
    for _ in range(300):
        length = rng.randint(1, 120)
        occ = []
        for _ in range(rng.randint(0, 4)):
            n = rng.randint(1, 33)
            if length - n < 0:
                continue
            positions = sorted(rng.sample(range(length - n + 1), rng.randint(1, min(8, length - n + 1))))
            occ.append((n, positions))
        assert best_window(length, occ) == _brute(length, occ)
