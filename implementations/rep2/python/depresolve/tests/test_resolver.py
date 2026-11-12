import random

from depresolve import Registry, Requirement, Version, format_resolution, parse_input, parse_range, resolve


def run(text: str) -> str:
    registry, root = parse_input(text)
    return format_resolution(resolve(registry, root))


def test_empty_root():
    assert run("root:\n") == ""


def test_diamond_backtracking():
    text = "a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n"
    assert run(text) == "a 1.0.0\nb 1.0.0\nc 1.2.5\n"


def test_first_solution_not_newest_set():
    text = "a 2.0.0: b ~1.0.0\na 1.0.0:\nb 1.0.0:\nb 1.0.5:\nb 1.5.0:\nb 2.0.0:\nroot: a *, b *\n"
    assert run(text) == "a 2.0.0\nb 1.0.5\n"


def test_conflicting_majors():
    text = "a 1.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\nc 1.0.0:\nc 2.0.0:\nroot: a *, b *\n"
    assert run(text) == "unsatisfiable\n"


REG4 = (
    "a 2.0.0: c ^2.0.0\na 1.0.0: c ^1.0.0\nb 2.0.0: c ^1.0.0\nb 1.0.0: c ^2.0.0\n"
    "c 1.0.0:\nc 2.0.0:\n"
)


def test_requirement_order_matters():
    assert run(REG4 + "root: a *, b *\n") == "a 2.0.0\nb 1.0.0\nc 2.0.0\n"
    assert run(REG4 + "root: b *, a *\n") == "a 1.0.0\nb 2.0.0\nc 1.0.0\n"


def test_missing_package_and_empty_candidates():
    assert run("root: ghost *\n") == "unsatisfiable\n"
    assert run("a 1.0.0:\nroot: a ^2.0.0\n") == "unsatisfiable\n"


def test_cycle_and_self_dependency():
    text = "a 1.0.0: b *\nb 1.0.0: a *\nc 1.0.0: c 1.0.0\nroot: a *, c *\n"
    assert run(text) == "a 1.0.0\nb 1.0.0\nc 1.0.0\n"


def test_output_sorted_bytewise():
    text = "mylib 1.0.0:\nmy-lib2 1.0.0:\nmy-lib 1.0.0:\nroot: mylib *, my-lib2 *, my-lib *\n"
    assert run(text) == "my-lib 1.0.0\nmy-lib2 1.0.0\nmylib 1.0.0\n"


def test_numeric_version_order():
    assert run("a 1.9.0:\na 1.10.0:\nroot: a *\n") == "a 1.10.0\n"


def test_deep_chain_no_recursion_limit():
    n = 5000
    lines = [f"p{chr(97 + i % 26)}{i} 1.0.0: p{chr(97 + (i + 1) % 26)}{i + 1} *" for i in range(n)]
    lines.append(f"p{chr(97 + n % 26)}{n} 1.0.0:")
    text = "\n".join(lines) + "\nroot: pa0 *\n"
    assert len(run(text).splitlines()) == n + 1


def test_api_building_registry_directly():
    reg = Registry()
    reg.add("a", Version(1, 0, 0), (Requirement("b", parse_range("^1.0.0")),))
    reg.add("b", Version(1, 2, 0))
    reg.add("b", Version(1, 1, 0))
    assert resolve(reg, [Requirement("a", parse_range("*"))]) == {
        "a": Version(1, 0, 0),
        "b": Version(1, 2, 0),
    }
    assert resolve(reg, [Requirement("a", parse_range(">5.0.0"))]) is None


def reference(registry, root):
    """Literal recursive transcription of the specification."""

    def go(pending, chosen):
        if not pending:
            return chosen
        (name, rng), rest = pending[0], pending[1:]
        if name in chosen:
            return go(rest, chosen) if chosen[name] in rng else None
        for v in registry.versions(name):
            if v in rng:
                r = go(tuple((q.name, q.range) for q in registry.requirements(name, v)) + rest, {**chosen, name: v})
                if r is not None:
                    return r
        return None

    return go(tuple((q.name, q.range) for q in root), {})


def random_text(rng: random.Random) -> str:
    names = [f"p{i}" for i in range(rng.randint(1, 6))]
    ranges = ["*", "^1.0.0", "^2.0.0", "~1.1.0", ">=1.1.0 <2.1.0", "^0.1.0", "^0.0.2", "<=1.0.0", "2.0.0", ">1.1.1"]
    lines = []
    for n in names:
        for v in rng.sample(["0.0.2", "0.1.0", "0.1.5", "1.0.0", "1.1.0", "1.2.0", "2.0.0", "2.1.0"], rng.randint(0, 5)):
            deps = rng.sample(names + ["ghost"], rng.randint(0, min(3, len(names))))
            reqs = ", ".join(f"{d} {rng.choice(ranges)}" for d in deps)
            lines.append(f"{n} {v}:" + (" " + reqs if reqs else ""))
    roots = rng.sample(names, rng.randint(0, min(3, len(names))))
    lines.append("root:" + (" " + ", ".join(f"{d} {rng.choice(ranges)}" for d in roots) if roots else ""))
    return "\n".join(lines) + "\n"


def test_matches_reference_on_random_registries():
    rng = random.Random(1234)
    for _ in range(500):
        text = random_text(rng)
        registry, root = parse_input(text)
        assert resolve(registry, root) == reference(registry, root), text
