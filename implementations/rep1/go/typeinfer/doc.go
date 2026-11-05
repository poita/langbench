// Package typeinfer implements Hindley-Milner type inference with
// let-polymorphism for a small ML-like language.
//
// A program is a sequence of ";;"-terminated declarations. A Checker infers
// them in order and reports, for each one, either its principal type or the
// kind of type error that made it fail (unbound variable, infinite type, or
// unification failure). A failing declaration adds nothing to the
// environment.
//
//	c := typeinfer.NewChecker()
//	results, err := c.Check([]byte("let id x = x;; (id 1, id true);;"))
//	for _, r := range results {
//		fmt.Println(r) // "id : 'a -> 'a", then "- : int * bool"
//	}
//
// The implementation is Algorithm J: destructive union-find unification over
// a shared graph of type nodes, with Rémy-style level-based generalisation
// (every let is generalised; there is no value restriction). The environment
// is a set of per-name binding stacks, so lookup and generalisation cost
// does not depend on how many bindings are in scope.
//
// The concrete syntax is documented in package
// example.com/typeinfer/syntax and in the README.
package typeinfer
