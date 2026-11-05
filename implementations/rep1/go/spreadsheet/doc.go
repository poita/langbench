// Package spreadsheet implements an in-memory spreadsheet engine with
// incremental recalculation.
//
// Cells hold numbers, strings or formulas. Formulas may reference other cells
// and ranges, and always reflect the current contents of the sheet: after
// every Set or Clear, only the cells that transitively depend on the edited
// cell are recomputed. Reference cycles are detected (with an iterative
// Tarjan strongly-connected-components pass) and every cyclic cell evaluates
// to #CYCLE!.
//
// Basic use:
//
//	s := spreadsheet.New()
//	s.Set("A1", "10")
//	s.Set("A2", "=A1*2")
//	v, _ := s.Get("A2")
//	fmt.Println(v) // 20
//
// The package is organised as follows:
//
//   - value.go: the Value type and its display form
//   - content.go: classification of cell content (number, string, formula)
//   - sheet.go: cell storage, dependency graph and the public Sheet API
//   - recalc.go: affected-set discovery, cycle detection, recalculation
//   - eval.go: the formula interpreter
//
// Sub-packages: cellref (cell names), formula (parser and AST) and numfmt
// (number display).
package spreadsheet
