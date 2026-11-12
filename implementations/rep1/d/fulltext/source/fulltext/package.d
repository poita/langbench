/**
 * fulltext — a small positional full-text search library.
 *
 * Index documents, run boolean and phrase queries (`AND`, `OR`, `NOT`,
 * parentheses, `"quoted phrases"`) and get BM25-ranked hits with snippets.
 * The Porter stemmer, tokeniser and ranking are implemented here, with no
 * dependencies beyond Phobos.
 *
 * ---
 * import fulltext;
 *
 * auto index = Index.build([Document("a", "The quick brown fox"),
 *                           Document("b", "A lazy dog")]);
 * auto searcher = new Searcher(index);
 * foreach (hit; searcher.search("quick OR \"lazy dog\"", 10))
 *     writeln(hit.id, " ", hit.score, " ", hit.snippet);
 * ---
 *
 * Modules:
 * $(UL
 *   $(LI `fulltext.analysis` — tokeniser, folding, stop words)
 *   $(LI `fulltext.stemmer` — Porter stemmer)
 *   $(LI `fulltext.index` — positional inverted index)
 *   $(LI `fulltext.query` — query language parser)
 *   $(LI `fulltext.search` — matching, BM25 scoring, ranking)
 *   $(LI `fulltext.snippet` — best-window snippets)
 *   $(LI `fulltext.queryfile`, `fulltext.corpus`, `fulltext.report` — batch I/O helpers)
 * )
 */
module fulltext;

public import fulltext.analysis;
public import fulltext.corpus;
public import fulltext.index;
public import fulltext.query;
public import fulltext.queryfile;
public import fulltext.report;
public import fulltext.search;
public import fulltext.snippet;
public import fulltext.stemmer;
