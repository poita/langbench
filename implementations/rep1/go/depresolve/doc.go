// Package depresolve resolves package dependencies.
//
// Given a registry of package versions (each with an ordered list of
// requirements) and a root manifest, Resolve picks one version for every
// package that is needed so that every requirement is satisfied. The search
// order is fixed — depth-first in requirement order, newest candidate first,
// chronological backtracking — so the result is deterministic: it is the
// first solution that search finds.
//
// The implementation interns names to dense ids, packs versions into
// integer keys, turns every range into a precomputed window of candidate
// indices, and runs the search iteratively with an explicit frame stack and
// an arena-backed persistent pending list, so deep dependency chains do not
// grow the call stack and backtracking never copies state.
//
// Typical use:
//
//	reg, root, err := depresolve.Parse(os.Stdin)
//	res, err := reg.Resolve(root)
//	if errors.Is(err, depresolve.ErrUnsatisfiable) { ... }
//	fmt.Print(res.Format())
package depresolve
