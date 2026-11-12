"""rubiks: a Rubik's cube solver (Thistlethwaite's four-phase algorithm).

Public API::

    from rubiks import Cube, Solver, solve

    solution = solve("R U R' U'")           # -> list of move tokens
    cube = Cube.from_moves("F R U'")
    cube.apply_moves(Solver().solve(cube))
    assert cube.is_solved()
"""

from .cube import Cube
from .notation import format_moves, invert_moves, parse_moves
from .solver import Solver, default_solver, solve

__all__ = ["Cube", "Solver", "default_solver", "solve",
           "parse_moves", "format_moves", "invert_moves"]
__version__ = "1.0.0"
