// Package dimacs reads formulas in the DIMACS CNF format and writes solver
// results in the SAT-competition-style layout used by the sat command.
//
// The parser is tolerant of the usual layout freedoms: comment and blank
// lines anywhere, clauses spanning several lines, several clauses on one
// line, and tabs or repeated spaces as separators.
package dimacs
