/**
 * fulltext: a small full-text search engine.
 *
 * Index documents with `Index`, parse and run queries with `SearchEngine`,
 * and use the lower-level modules (analysis, stemmer, query, matcher,
 * ranking, snippet) directly when you need only a part of the pipeline.
 *
 * Example:
 * ---
 * import fulltext;
 *
 * auto index = new Index([
 *     Document.fromString("a", "The quick brown fox"),
 *     Document.fromString("b", "A lazy dog"),
 * ]);
 * auto engine = new SearchEngine(index);
 * foreach (hit; engine.search("fox OR dog", 10))
 *     writeln(hit.docId, " ", hit.score, " ", hit.snippet);
 * ---
 */
module fulltext;

public import fulltext.analysis;
public import fulltext.corpus;
public import fulltext.index;
public import fulltext.matcher;
public import fulltext.query;
public import fulltext.queryfile;
public import fulltext.ranking;
public import fulltext.report;
public import fulltext.search;
public import fulltext.snippet;
public import fulltext.stemmer;
public import fulltext.whitespace;
