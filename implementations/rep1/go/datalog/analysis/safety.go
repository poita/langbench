// Package analysis performs the static checks on a program: rule safety and
// stratification of negation.
package analysis

import (
	"fmt"

	"example.com/datalog/ast"
)

// UnsafeError reports a rule with a variable that does not occur in any
// positive body atom although it occurs in the head, a negated atom or a
// comparison.
type UnsafeError struct {
	Rule     ast.Rule
	Variable string
}

func (e *UnsafeError) Error() string {
	v := e.Variable
	if len(v) > 0 && v[0] == '_' {
		v = "_"
	}
	return fmt.Sprintf("unsafe rule (line %d): variable %s is not bound by a positive body atom: %s",
		e.Rule.Line, v, e.Rule)
}

// CheckSafety returns an *UnsafeError for the first unsafe rule, or nil.
func CheckSafety(rules []ast.Rule) error {
	for _, r := range rules {
		if v, ok := unboundVar(r); !ok {
			return &UnsafeError{Rule: r, Variable: v}
		}
	}
	return nil
}

// unboundVar returns a variable violating safety, and false if there is one.
func unboundVar(r ast.Rule) (string, bool) {
	bound := make(map[string]bool)
	for _, l := range r.Body {
		if l.Kind == ast.Positive {
			for _, t := range l.Atom.Args {
				if t.IsVar {
					bound[t.Name] = true
				}
			}
		}
	}
	check := func(ts ...ast.Term) (string, bool) {
		for _, t := range ts {
			if t.IsVar && !bound[t.Name] {
				return t.Name, false
			}
		}
		return "", true
	}
	if v, ok := check(r.Head.Args...); !ok {
		return v, false
	}
	for _, l := range r.Body {
		switch l.Kind {
		case ast.Negative:
			if v, ok := check(l.Atom.Args...); !ok {
				return v, false
			}
		case ast.Comparison:
			if v, ok := check(l.Left, l.Right); !ok {
				return v, false
			}
		}
	}
	return "", true
}
