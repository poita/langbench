from minisql.lexer import Token, split_statements


def kinds(text):
    return [[(t.kind, t.value) for t in s] for s in split_statements(text)]


def test_case_insensitive_keywords_and_identifiers():
    assert kinds("Select Emp") == [[("kw", "SELECT"), ("ident", "emp")]]


def test_splits_on_semicolons_and_drops_empty_statements():
    assert len(split_statements(";; select 1; ; -- c\n ;select 2")) == 2


def test_comment_starts_with_double_dash():
    assert kinds("1 --5\n+ 2") == [[("int", 1), ("op", "+"), ("int", 2)]]


def test_semicolon_in_string_and_comment_does_not_split():
    assert len(split_statements("select 'a;b'; -- x;y\n select 2")) == 2


def test_string_escapes_and_multiline():
    assert kinds("'it''s\n\\n'") == [[("str", "it's\n\\n")]]


def test_operator_normalisation_and_longest_match():
    toks = split_statements("<= <> != == < >=")[0]
    assert [t.value for t in toks] == ["<=", "!=", "!=", "=", "<", ">="]


def test_invalid_characters():
    assert kinds('a "b" @')[0][1] == ("invalid", '"')
    assert split_statements("é")[0] == [Token("invalid", "é")]


def test_unterminated_string_swallows_rest_of_input():
    stmts = split_statements("select 1; select 'abc; select 2;")
    assert len(stmts) == 2
    assert stmts[1][-1].kind == "invalid"


def test_decimal_point_is_separate_tokens():
    assert [t.value for t in split_statements("1.5")[0]] == [1, ".", 5]


def test_non_ascii_digits_are_not_integers():
    assert split_statements("٣")[0][0].kind == "invalid"
