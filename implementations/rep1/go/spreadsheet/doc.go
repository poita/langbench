// Package spreadsheet implements an in-memory spreadsheet engine with
// incremental recalculation.
//
// Cells hold numbers, strings or formulas. Formulas may reference other cells
// and ranges, and the sheet is kept consistent after every edit: only the
// cells that (transitively) read the edited cell are re-evaluated, and cells
// that take part in a reference cycle evaluate to #CYCLE!.
//
// # Usage
//
//	s := spreadsheet.New()
//	_ = s.Set("A1", "10")
//	_ = s.Set("A2", "=A1*2")
//	v, _ := s.Get("A2")
//	fmt.Println(v) // 20
//
// # Structure
//
// The package is split by responsibility:
//
//   - value.go:   the Value type, its kinds and error codes
//   - format.go:  number display ("%.10g"-style formatting)
//   - cellname.go: cell name parsing and printing
//   - lexer.go, parser.go: formulas to syntax trees
//   - eval.go:    evaluation of syntax trees against stored cell values
//   - sheet.go:   the Sheet, its dependency graph and recalculation
//
// A Sheet is not safe for concurrent use.
package spreadsheet
