/**
 * Codexa typesetting engine.
 *
 * Reads a Codexa document and an optional settings file and lays the
 * document out on numbered pages using total-fit (Knuth–Plass) line
 * breaking, Liang hyphenation, footnotes, floating figures, a generated table
 * of contents and running headers. Every quantity is an integer number of
 * millipoints, so the output is exactly reproducible.
 *
 * Example:
 * ---
 * import typeset;
 *
 * auto resources = Resources.load("data");
 * auto result = typesetSources(resources, "The quick brown fox.\n");
 * if (result.ok)
 *     writeln(result.layout.toText());
 * else
 *     writeln(result.errorText());
 * ---
 */
module typeset;

public import typeset.engine;
public import typeset.errors;
public import typeset.layout;
public import typeset.settings : Settings, parseSettings;
