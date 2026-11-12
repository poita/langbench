from cardgame.prng import Rng


def test_seed_7_stream():
    r = Rng(7)
    assert [r.next() for _ in range(5)] == [
        15130880334998875822, 17123930943180875438, 1648209070578717474,
        1985375592982671918, 6908966637734145041]


def test_zero_seed_is_replaced():
    assert Rng(0).state == 0x2545F4914F6CDD1D


def test_short_lists_consume_nothing():
    r = Rng(7)
    items = [1]
    r.shuffle(items)
    r.shuffle([])
    assert r.state == Rng(7).state


def test_shuffle_matches_spec_example():
    r = Rng(7)
    items = list(range(1, 9))
    r.shuffle(items)
    assert items == [6, 8, 5, 2, 4, 1, 3, 7]
