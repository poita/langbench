/**
 * btregex: a small backtracking regular-expression engine.
 *
 * Implements a fixed Perl-style subset (literals, `.`, classes, `\d \w \s`
 * and their complements, `^`, `$`, capturing groups, alternation and the
 * greedy quantifiers `* + ? {n} {n,} {n,m}`) with leftmost, ordered-choice
 * semantics, and reports the offsets of every capture group.
 *
 * Example:
 * ---
 * import btregex;
 *
 * auto re = new Regex("(a|(b))+");
 * auto m = re.search("ba");
 * assert(m.matched && m.start == 0 && m.end == 2);
 * assert(m.groups[0] == Group(1, 2));   // group 1
 * assert(m.groups[1] == Group(0, 1));   // group 2
 * ---
 *
 * Modules: $(LREF btregex.parser) (syntax), $(LREF btregex.program)
 * (compiler), $(LREF btregex.engine) (matcher), $(LREF btregex.batch)
 * (the line-oriented batch format used by the command-line tool).
 */
module btregex;

public import btregex.engine;
public import btregex.parser : RegexException;
public import btregex.batch;
