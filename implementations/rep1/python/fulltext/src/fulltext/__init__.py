"""fulltext: a small positional full-text search engine.

Typical use::

    from fulltext import Index, Searcher

    index = Index({"note": "The quick brown fox jumps over the lazy dog."})
    for hit in Searcher(index).search("quick AND (fox OR cat)", k=5):
        print(hit.rank, hit.doc_id, f"{hit.score:.4f}", hit.snippet)
"""

from .analysis import analyze, fold, term_for, token_texts
from .corpus import QueryLine, load_documents, parse_queries
from .index import Index
from .query import And, Atom, Not, Or, parse_query, positive_atoms
from .search import Hit, Searcher
from .stemmer import stem

__version__ = "1.0.0"

__all__ = [
    "And", "Atom", "Hit", "Index", "Not", "Or", "QueryLine", "Searcher",
    "analyze", "fold", "load_documents", "parse_queries", "parse_query",
    "positive_atoms", "stem", "term_for", "token_texts",
]
