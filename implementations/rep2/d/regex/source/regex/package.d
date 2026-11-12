/**
 * A backtracking regular-expression engine for a defined subset of Perl-style
 * syntax, plus a batch driver for the line-oriented input format used by the
 * command-line tool.
 *
 * Modules:
 * $(UL
 *   $(LI $(MREF regex.regex)    – the `Regex` class and `Match` result)
 *   $(LI $(MREF regex.batch)    – parsing batch input and formatting results)
 *   $(LI $(MREF regex.parser)   – pattern → syntax tree)
 *   $(LI $(MREF regex.ast)      – syntax tree)
 *   $(LI $(MREF regex.compiler) – syntax tree → program)
 *   $(LI $(MREF regex.vm)       – backtracking interpreter)
 * )
 */
module regex;

public import regex.regex;
public import regex.batch;
public import regex.exception;
