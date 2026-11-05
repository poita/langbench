// Package depresolve resolves package dependencies deterministically.
//
// Given a Registry (every version of every package together with its
// requirements) and a root manifest, Resolve picks exactly one version for
// every package that is needed so that every requirement is satisfied. The
// search order is fixed: depth-first in the order requirements are listed,
// newest candidate version first, with chronological backtracking. The result
// is the first complete solution that search finds, so it is reproducible
// and independent of the implementation strategy.
//
// The package is organised by responsibility:
//
//   - version.go:  Version and its packed integer Key.
//   - range.go:    Range, a version range compiled to one half-open interval.
//   - registry.go: Registry and Requirement, the package database.
//   - parse.go:    the line-oriented text format (Parse, Problem).
//   - resolve.go:  the iterative backtracking search and Resolution.
//
// The search is iterative (an explicit frame stack and a persistent pending
// list in an arena), so arbitrarily deep dependency chains do not grow the Go
// call stack, and no per-step copying is done.
package depresolve
