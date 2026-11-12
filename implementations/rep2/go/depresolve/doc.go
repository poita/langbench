// Package depresolve resolves package dependencies deterministically.
//
// Given a Registry (every version of every package together with its
// requirements) and a root manifest (a list of Requirements), Resolve picks
// exactly one version for every package that is needed so that every
// requirement of the root and of every picked version is satisfied.
//
// The result is defined as the first complete solution found by a
// depth-first search that tries candidate versions newest first and
// backtracks chronologically. Requirements of a newly chosen version are
// processed before the requirements that were already pending. Because the
// search order is fixed, every run over the same input yields the same
// resolution, which makes the output suitable for lock files.
//
// The package is organised as follows:
//
//   - version.go:  the Version type (MAJOR.MINOR.PATCH, numeric comparison).
//   - rangespec.go: the Range type and its parser (npm-style caret, tilde
//     and comparator ranges).
//   - registry.go: Registry and Requirement, the data being resolved.
//   - parse.go:    reading the textual registry/root format.
//   - resolve.go:  the search itself.
//
// A minimal example:
//
//	reg := depresolve.NewRegistry()
//	reg.Add("a", depresolve.MustParseVersion("1.0.0"), depresolve.MustParseRequirements("c ^1.0.0"))
//	reg.Add("c", depresolve.MustParseVersion("1.2.0"), nil)
//	sol, err := reg.Resolve(depresolve.MustParseRequirements("a *"))
package depresolve
