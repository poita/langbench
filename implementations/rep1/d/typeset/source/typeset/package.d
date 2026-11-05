/// A typesetting engine for the Codexa markup language.
///
/// The library is organised in layers; each module has one responsibility:
///
/// $(UL
///   $(LI `typeset.arith`: exact integer arithmetic (floor division, scaling, badness))
///   $(LI `typeset.errors`: error codes and diagnostics)
///   $(LI `typeset.values`: literal parsing shared by the settings and document parsers)
///   $(LI `typeset.fonts`, `typeset.hyphen`: font metrics and Liang hyphenation patterns)
///   $(LI `typeset.settings`: the `settings.cfg` parser)
///   $(LI `typeset.markup`: the Codexa block tree and inline parser)
///   $(LI `typeset.hlist`, `typeset.linebreak`, `typeset.setline`: horizontal lists, total-fit breaking, line setting)
///   $(LI `typeset.layout`: block layout into a vertical list (lists, tables, figures, footnotes, TOC))
///   $(LI `typeset.page`: page breaking, footnote areas, running headers)
///   $(LI `typeset.output`: output formatting)
///   $(LI `typeset.engine`: the top-level pipeline)
/// )
module typeset;

public import typeset.arith;
public import typeset.engine;
public import typeset.errors;
public import typeset.fonts;
public import typeset.hlist;
public import typeset.hyphen;
public import typeset.layout;
public import typeset.linebreak;
public import typeset.markup;
public import typeset.output;
public import typeset.page;
public import typeset.setline;
public import typeset.settings;
public import typeset.values;
