from rubiks import Cube
from rubiks.model import MOVE_NAMES, MOVES

from facelets import SOLVED, apply

SUPERFLIP = "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"


def test_eighteen_moves():
    assert len(MOVES) == 18 == len(set(MOVE_NAMES))


def test_solved_facelets():
    assert Cube().to_facelets() == SOLVED


def test_cubie_matches_facelet_model_for_every_move():
    for name in MOVE_NAMES:
        assert Cube.from_moves([name]).to_facelets() == apply(SOLVED, [name]), name


def test_cubie_matches_facelet_model_on_long_sequence():
    seq = (SUPERFLIP + " R U R' U' F2 B' L D2 R2 U' F").split()
    assert Cube.from_moves(seq).to_facelets() == apply(SOLVED, seq)


def test_example_from_spec():
    f = apply(SOLVED, ["U"])
    assert f[18:21] == "RRR"      # F1 F2 F3 show the R colour
    assert f[36:39] == "FFF"      # L1 L2 L3 show F
    assert f[45:48] == "LLL"      # B1 B2 B3 show L
    assert f[9:12] == "BBB"       # R1 R2 R3 show B


def test_order_of_moves():
    def order(seq):
        cube, n = Cube.from_moves(seq), 1
        while not cube.is_solved():
            cube.apply_moves(seq)
            n += 1
        return n

    assert order(["R"]) == 4
    assert order("R U".split()) == 105
    assert order("U D".split()) == 4
    assert order("R U R' U'".split()) == 6


def test_superflip():
    cube = Cube.from_moves(SUPERFLIP)
    assert cube.cp == list(range(8)) and not any(cube.co)
    assert cube.ep == list(range(12)) and all(cube.eo)


def test_move_then_inverse():
    for name in MOVE_NAMES:
        cube = Cube.from_moves([name, name[0] + ("2" if name.endswith("2") else
                                                  "" if name.endswith("'") else "'")])
        assert cube.is_solved()


def test_fb_quarter_turns_flip_edges_but_others_do_not():
    for name in MOVE_NAMES:
        cube = Cube.from_moves([name])
        flips = sum(cube.eo)
        assert flips == (4 if name[0] in "FB" and not name.endswith("2") else 0), name
