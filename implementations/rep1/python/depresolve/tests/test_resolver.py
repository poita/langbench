import pytest

from depresolve import parse_problem, resolve


def run(text: str):
    registry, root = parse_problem(text)
    res = resolve(registry, root)
    return None if res is None else res.lines()


def test_diamond_needs_backtracking():
    text = "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n"
    assert run(text) == ["a 1.0.0", "b 1.0.0", "c 1.2.5"]


def test_first_solution_not_globally_newest():
    text = (
        "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\n"
        "root: a *, b *\n"
    )
    assert run(text) == ["a 2.0.0", "b 1.0.5"]


def test_conflicting_majors():
    text = "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n"
    assert run(text) is None


REG4 = (
    "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\n"
    "b 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\n"
)


def test_requirement_order_matters():
    assert run(REG4 + "root: a *, b *\n") == ["a 2.0.0", "b 1.0.0", "c 2.0.0"]
    assert run(REG4 + "root: b *, a *\n") == ["a 1.0.0", "b 2.0.0", "c 1.0.0"]


def test_empty_root_yields_nothing():
    assert run("root:\n") == []


def test_missing_package_is_unsatisfiable():
    assert run("a 1.0.0: ghost *\nroot: a *\n") is None
    assert run("root: ghost *\n") is None


def test_self_dependency_and_cycle():
    assert run("a 1.0.0: a *\nroot: a *\n") == ["a 1.0.0"]
    text = "a 1.0.0: b *\nb 1.0.0: a *\nroot: a *\n"
    assert run(text) == ["a 1.0.0", "b 1.0.0"]


def test_self_dependency_conflict_steps_down():
    text = "a 2.0.0: a ^1.0.0\na 1.0.0:\nroot: a *\n"
    assert run(text) == ["a 1.0.0"]


def test_unrelated_package_is_retried_chronologically():
    # x is chosen after y but only y's pick conflicts; chronological
    # backtracking exhausts x's candidates before stepping y down.
    text = (
        "y 2.0.0:\ny 1.0.0:\nx 2.0.0:\nx 1.0.0:\nz 1.0.0: y ^1.0.0\n"
        "root: y *, x *, z *\n"
    )
    assert run(text) == ["x 2.0.0", "y 1.0.0", "z 1.0.0"]


def test_output_sorted_by_byte_order():
    text = "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n"
    assert run(text) == ["my-lib 1.0.0", "my-lib2 1.0.0", "mylib 1.0.0"]


def test_empty_range_candidates():
    assert run("a 1.0.0:\nroot: a >=2.0.0 <1.0.0\n") is None


def test_deep_chain_needs_no_recursion():
    n = 20000
    lines = [f"p{i} 1.0.0: p{i + 1} *" for i in range(n)]
    lines.append(f"p{n} 1.0.0:")
    lines.append("root: p0 *")
    res = run("\n".join(lines) + "\n")
    assert res is not None and len(res) == n + 1


def test_many_versions_stepped_through():
    lines = [f"a 1.{i}.0:" for i in range(1600)]
    lines.append("b 1.0.0: a ~1.3.0")
    lines.append("root: a *, b *")
    assert run("\n".join(lines) + "\n") == ["a 1.3.0", "b 1.0.0"]
