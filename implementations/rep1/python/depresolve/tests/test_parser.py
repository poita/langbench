from depresolve import Version, parse_problem, parse_requirements


def test_empty_root_only():
    registry, root = parse_problem("root:\n")
    assert len(registry) == 0 and root == []


def test_registry_and_root():
    text = "a 1.0.0: b ^1.0.0, c *\nb 1.2.0:\nroot: a *\n"
    registry, root = parse_problem(text)
    assert [r.name for r in root] == ["a"]
    assert registry.versions("b") == [Version(1, 2, 0)]
    reqs = registry.requirements("a", Version(1, 0, 0))
    assert [r.name for r in reqs] == ["b", "c"]


def test_versions_sorted_newest_first_regardless_of_input_order():
    registry, _ = parse_problem("a 1.9.0:\na 1.10.0:\na 1.2.0:\nroot:\n")
    assert registry.versions("a") == [Version(1, 10, 0), Version(1, 9, 0), Version(1, 2, 0)]


def test_comparator_requirement_with_spaces():
    reqs = parse_requirements(" a >=1.0.0 <2.0.0, b *")
    assert [r.name for r in reqs] == ["a", "b"]
    assert Version(1, 5, 0) in reqs[0].range
