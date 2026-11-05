// Package depresolve resolves package dependencies deterministically.
//
// Given a registry (every version of every package together with its
// requirements) and a root manifest, Resolve picks exactly one version for
// every package that is needed so that all requirements are satisfied. The
// result is defined as the first complete solution found by a depth-first,
// newest-version-first search with chronological backtracking, so every
// correct implementation prints the same resolution.
//
// The package is organised by responsibility:
//
//   - version.go: the Version type and its numeric ordering;
//   - constraint.go: Range, a version constraint (*, exact, ^, ~, comparators)
//     reduced to one half-open interval of packed version keys;
//   - problem.go: Builder and Problem, which intern package names, sort the
//     versions of each package newest first and precompute, for every
//     requirement, the window of candidate versions it admits;
//   - parse.go: the line-oriented text format of the registry and root;
//   - resolve.go: the iterative search with an explicit frame stack, a
//     persistent pending list in an arena and an undo-by-frame-stack scheme.
//
// Typical use:
//
//	p, err := depresolve.Parse(input)
//	if err != nil { ... }
//	res, err := p.Resolve()
//	if errors.Is(err, depresolve.ErrUnsatisfiable) { ... }
package depresolve
