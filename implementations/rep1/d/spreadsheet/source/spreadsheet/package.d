/**
 * A spreadsheet engine with incremental recalculation.
 *
 * $(UL
 *   $(LI `spreadsheet.sheet`: the `Sheet` class (the main entry point))
 *   $(LI `spreadsheet.value`: `Value` and `Kind`)
 *   $(LI `spreadsheet.cellref`: cell names)
 *   $(LI `spreadsheet.parser`, `spreadsheet.ast`, `spreadsheet.eval`: formulas)
 *   $(LI `spreadsheet.numfmt`: number parsing and display)
 *   $(LI `spreadsheet.script`: the `set`/`get`/`clear`/`dump` command language)
 * )
 */
module spreadsheet;

public import spreadsheet.cellref;
public import spreadsheet.numfmt;
public import spreadsheet.parser : SyntaxError;
public import spreadsheet.script;
public import spreadsheet.sheet;
public import spreadsheet.value;
