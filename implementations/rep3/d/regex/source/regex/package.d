/**
 * A small backtracking regular-expression engine.
 *
 * It implements a defined subset of Perl-style syntax (literals, `.`, `^`,
 * `$`, classes, `\d \w \s` escapes, capturing groups, alternation and greedy
 * quantifiers) with leftmost, ordered-choice matching, and reports the
 * position of every capture group.
 *
 * Modules:
 * $(UL
 *   $(LI `regex.charset`  - 256-bit character sets)
 *   $(LI `regex.ast`      - syntax tree)
 *   $(LI `regex.parser`   - pattern text to syntax tree)
 *   $(LI `regex.analysis` - static facts: anchoring, first-character set)
 *   $(LI `regex.program`  - virtual machine instruction set)
 *   $(LI `regex.compiler` - syntax tree to program)
 *   $(LI `regex.vm`       - the backtracking interpreter (`Matcher`))
 *   $(LI `regex.api`      - convenient `Regex` / `Match` types)
 *   $(LI `regex.batch`    - the line-oriented batch protocol used by the CLI)
 * )
 */
module regex;

public import regex.api;
public import regex.ast;
public import regex.analysis;
public import regex.batch;
public import regex.charset;
public import regex.compiler;
public import regex.parser;
public import regex.program;
public import regex.vm;
