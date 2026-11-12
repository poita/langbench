from cdcl_sat import format_result, parse_dimacs


def test_basic():
    cnf = parse_dimacs("c hi\np cnf 3 2\n1 -2 0\n2 3 0\n")
    assert cnf.num_vars == 3
    assert cnf.clauses == [[1, -2], [2, 3]]


def test_clauses_span_lines_and_share_lines():
    cnf = parse_dimacs("p cnf 2 4\n1 2\n0 -1 2 0\n-1 -2 0 1 -2 0")
    assert cnf.clauses == [[1, 2], [-1, 2], [-1, -2], [1, -2]]


def test_comments_blanks_and_blank_padding():
    text = "\n  \t c before\n\tp  cnf \t 2   2 \n 1 -2 0 \n cfoo\n\n 0\n  c\n c end"
    cnf = parse_dimacs(text)
    assert cnf.num_vars == 2
    assert cnf.clauses == [[1, -2], []]


def test_comment_between_numbers_of_a_clause():
    cnf = parse_dimacs("p cnf 3 1\n1 2\nc interrupting\n3 0\n")
    assert cnf.clauses == [[1, 2, 3]]


def test_empty_clause_and_empty_formula():
    assert parse_dimacs("p cnf 1 1\n0\n").clauses == [[]]
    cnf = parse_dimacs("p cnf 0 0")
    assert cnf.num_vars == 0 and cnf.clauses == []


def test_format_result():
    assert format_result(None) == "UNSAT\n"
    assert format_result([1, -2, 3]) == "SAT\n1 -2 3 0\n"
    assert format_result([]) == "SAT\n0\n"
