from cdcl_sat import format_result, parse_dimacs


def test_basic():
    cnf = parse_dimacs("c hi\np cnf 3 2\n1 -2 0\n2 3 0\n")
    assert cnf.num_vars == 3
    assert cnf.clauses == [[1, -2], [2, 3]]


def test_clauses_span_lines_and_share_lines():
    cnf = parse_dimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0")
    assert cnf.clauses == [[1, 2], [-1, 2], [-1, -2], [1, -2]]


def test_comments_blanks_and_blanks_around_lines():
    text = "\n  \tc x\ncfoo\n p cnf 2 2 \n\t1\n c middle\n 2 0\n\n0\nc end"
    cnf = parse_dimacs(text)
    assert cnf.num_vars == 2
    assert cnf.clauses == [[1, 2], []]


def test_empty_header_only():
    assert parse_dimacs("p cnf 0 0").clauses == []


def test_format_unsat():
    assert format_result(3, None) == "UNSAT\n"


def test_format_sat():
    assert format_result(3, [True, False, True]) == "SAT\n1 -2 3 0\n"
    assert format_result(0, []) == "SAT\n0\n"
