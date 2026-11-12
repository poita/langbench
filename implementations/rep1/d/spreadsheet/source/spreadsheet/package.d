/**
 * A spreadsheet engine with incremental recalculation.
 *
 * Import `spreadsheet` to get the whole public API:
 *
 * $(UL
 *   $(LI $(MREF spreadsheet.cellref) — cell addresses)
 *   $(LI $(MREF spreadsheet.value) — values, errors and number formatting)
 *   $(LI $(MREF spreadsheet.ast), $(MREF spreadsheet.parser) — formula syntax trees and parsing)
 *   $(LI $(MREF spreadsheet.eval) — formula evaluation)
 *   $(LI $(MREF spreadsheet.sheet) — the `Sheet` class)
 *   $(LI $(MREF spreadsheet.script) — the `set`/`get`/`clear`/`dump` command language)
 * )
 */
module spreadsheet;

public import spreadsheet.ast;
public import spreadsheet.cellref;
public import spreadsheet.eval;
public import spreadsheet.parser;
public import spreadsheet.script;
public import spreadsheet.sheet;
public import spreadsheet.value;
