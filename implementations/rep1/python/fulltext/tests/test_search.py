import pytest

from fulltext import Index, Searcher, parse_queries
from fulltext.matching import _phrase_starts
from fulltext.output import format_results, format_stats


def ids(hits):
    return [h.doc_id for h in hits]


@pytest.fixture
def note():
    return Searcher(Index({"note": "The quick brown fox jumps over the lazy dog."}))


def test_worked_example(note):
    (hit,) = note.search("fox")
    assert f"{hit.score:.4f}" == "0.2877"
    assert hit.snippet == "The quick brown fox jumps over the lazy dog"
    (hit,) = note.search("quick brown")
    assert f"{hit.score:.4f}" == "0.5754"
    assert note.search("cat") == []
    assert len(note.search('"lazy dog"')) == 1
    assert note.search('"dog lazy"') == []


def test_stats(note):
    assert format_stats(note.index) == "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n"


def test_tie_break_and_term_frequency():
    docs = {f"copy{i}": "alpha beta gamma" for i in (1, 2, 3)}
    docs["other"] = "alpha alpha beta"
    hits = Searcher(Index(docs)).search("alpha")
    assert ids(hits) == ["other", "copy1", "copy2", "copy3"]
    assert [f"{h.score:.4f}" for h in hits] == ["0.1449", "0.1054", "0.1054", "0.1054"]


def test_boolean_operators():
    s = Searcher(Index({"a": "cat dog", "b": "cat", "c": "dog bird", "d": "fish"}))
    assert sorted(ids(s.search("cat dog"))) == ["a"]
    assert sorted(ids(s.search("cat OR bird"))) == ["a", "b", "c"]
    assert sorted(ids(s.search("NOT cat"))) == ["c", "d"]
    assert sorted(ids(s.search("cat NOT dog"))) == ["b"]
    assert sorted(ids(s.search("NOT NOT cat"))) == ["a", "b"]
    assert s.search("the") == []  # empty tree matches nothing
    assert s.search("()") == []


def test_not_only_query_scores_zero():
    hits = Searcher(Index({"a": "cat", "b": "dog"})).search("NOT cat")
    assert [(h.doc_id, h.score) for h in hits] == [("b", 0.0)]


def test_phrases_include_stop_words_and_overlap():
    s = Searcher(Index({"a": "to be or not to be", "b": "aa aa aa aa"}))
    assert ids(s.search('"to be or not to be"')) == ["a"]
    assert ids(s.search('"be or"')) == ["a"]
    assert ids(s.search('"aa aa"')) == ["b"]
    assert _phrase_starts([[0, 1, 2, 3], [0, 1, 2, 3]]) == [0, 1, 2]


def test_phrase_does_not_cross_documents_or_gaps():
    s = Searcher(Index({"a": "cat sat mat", "b": "cat mat"}))
    assert ids(s.search('"cat mat"')) == ["b"]


def test_k_limit_and_snippet_whitespace():
    s = Searcher(Index({"a": "one\n\ttwo   three", "b": "one", "c": "one"}))
    assert len(s.search("one", k=2)) == 2
    assert s.search("two", k=1)[0].snippet == "one two three"


def test_snippet_window_selection():
    words = ["w%d" % i for i in range(100)]
    words[70] = "needle"
    hit = Searcher(Index({"d": " ".join(words)})).search("needle")[0]
    toks = hit.snippet.split()
    assert len(toks) == 30 and "needle" in toks and toks[0] == "w41"


def test_empty_document_and_empty_corpus():
    assert Searcher(Index({})).search("cat") == []
    s = Searcher(Index({"e": ""}))
    assert s.search("NOT cat")[0].snippet == ""
    assert format_stats(s.index) == "documents 1\ntokens 0\nterms 0\navgdl 0.0000\n"
    assert format_stats(Index({})) == "documents 0\ntokens 0\nterms 0\navgdl 0.0000\n"


def test_parse_queries():
    qs = parse_queries("# c\n\ncat\n%k 3\n  dog  \n%k\t5 \nbird")
    assert [(q.number, q.text, q.k) for q in qs] == [
        (1, "cat", 10), (2, "dog", 3), (3, "bird", 5),
    ]


def test_format_results():
    s = Searcher(Index({"a": "cat"}))
    out = format_results([(1, "cat", s.search("cat")), (2, "dog", [])])
    assert out == "QUERY 1 cat\nHITS 1\n1\ta\t0.2877\tcat\nQUERY 2 dog\nHITS 0\n"
