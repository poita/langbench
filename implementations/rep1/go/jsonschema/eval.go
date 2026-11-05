package jsonschema

import (
	"errors"

	"example.com/jsonschema/jsonvalue"
)

// maxDepth bounds evaluation recursion so that a schema that refers to itself
// without consuming any of the instance fails cleanly instead of overflowing
// the stack.
const maxDepth = 100000

var errTooDeep = errors.New("jsonschema: recursion limit exceeded (reference cycle?)")

// state is the per-Validate-call evaluation state.
type state struct {
	schema *Schema
	scope  []int // dynamic scope: base URI ids, outermost first
	depth  int
	err    error
}

func (s *state) fail(err error) bool {
	if s.err == nil {
		s.err = err
	}
	return false
}

// eval evaluates node n against v. When collect is true the returned
// annotation sets (non-nil only if n accepts) describe what n evaluated.
func (s *state) eval(n *node, v *jsonvalue.Value, collect bool) (bool, *annot) {
	if n.isBool {
		return n.boolVal, nil
	}
	if s.err != nil {
		return false, nil
	}
	if s.depth >= maxDepth {
		return s.fail(errTooDeep), nil
	}
	s.depth++
	pushed := len(s.scope) == 0 || s.scope[len(s.scope)-1] != n.base
	if pushed {
		s.scope = append(s.scope, n.base)
	}
	ok, a := s.evalObject(n, v, collect)
	if pushed {
		s.scope = s.scope[:len(s.scope)-1]
	}
	s.depth--
	if !ok {
		return false, nil
	}
	return true, a
}

func kindBit(v *jsonvalue.Value) uint8 {
	switch v.Kind() {
	case jsonvalue.KindNull:
		return tNull
	case jsonvalue.KindBool:
		return tBoolean
	case jsonvalue.KindObject:
		return tObject
	case jsonvalue.KindArray:
		return tArray
	case jsonvalue.KindString:
		return tString
	}
	if v.Number().IsInteger() {
		return tNumber | tInteger
	}
	return tNumber
}

func (c count) lt(n int) bool { return c.set && int64(n) < c.v }
func (c count) gt(n int) bool { return c.set && int64(n) > c.v }

func (s *state) evalObject(n *node, v *jsonvalue.Value, collect bool) (bool, *annot) {
	collecting := collect || n.hasUneval
	var a *annot
	if collecting {
		a = new(annot)
	}

	if n.typeMask != 0 && n.typeMask&kindBit(v) == 0 {
		return false, nil
	}
	if n.constVal != nil && !jsonvalue.Equal(*n.constVal, *v) {
		return false, nil
	}
	if n.hasEnum {
		found := false
		for _, e := range n.enum {
			if jsonvalue.Equal(e, *v) {
				found = true
				break
			}
		}
		if !found {
			return false, nil
		}
	}

	switch v.Kind() {
	case jsonvalue.KindNumber:
		if !checkNumber(n, v.Number()) {
			return false, nil
		}
	case jsonvalue.KindString:
		if !s.checkString(n, v.Str()) {
			return false, nil
		}
	case jsonvalue.KindArray:
		if !s.evalArray(n, v, collecting, a) {
			return false, nil
		}
	case jsonvalue.KindObject:
		if !s.evalMembers(n, v, collecting, a) {
			return false, nil
		}
	}

	// In-place applicators.
	if n.hasRef {
		if n.ref == nil {
			return s.fail(n.refErr), nil
		}
		if !s.apply(n.ref, v, collecting, a) {
			return false, nil
		}
	}
	if n.hasDynRef {
		target := n.dynRef
		if n.dynName >= 0 {
			for _, base := range s.scope {
				if t, ok := s.schema.dynTargets[anchorKey{base, n.dynName}]; ok {
					target = t
					break
				}
			}
		}
		if target == nil {
			return s.fail(n.dynRefErr), nil
		}
		if !s.apply(target, v, collecting, a) {
			return false, nil
		}
	}
	for _, c := range n.allOf {
		if !s.apply(c, v, collecting, a) {
			return false, nil
		}
	}
	if len(n.anyOf) > 0 {
		matched := false
		for _, c := range n.anyOf {
			ok, ca := s.eval(c, v, collecting)
			if ok {
				matched = true
				a.merge(ca)
				if !collecting {
					break
				}
			}
		}
		if !matched {
			return false, nil
		}
	}
	if len(n.oneOf) > 0 {
		var winner *annot
		matches := 0
		for _, c := range n.oneOf {
			ok, ca := s.eval(c, v, collecting)
			if ok {
				matches++
				winner = ca
				if matches > 1 {
					return false, nil
				}
			}
		}
		if matches != 1 {
			return false, nil
		}
		a.merge(winner)
	}
	if n.not != nil {
		if ok, _ := s.eval(n.not, v, false); ok {
			return false, nil
		}
	}
	if n.ifNode != nil && (collecting || n.thenNode != nil || n.elseNode != nil) {
		if ok, ia := s.eval(n.ifNode, v, collecting); ok {
			a.merge(ia)
			if n.thenNode != nil && !s.apply(n.thenNode, v, collecting, a) {
				return false, nil
			}
		} else if n.elseNode != nil && !s.apply(n.elseNode, v, collecting, a) {
			return false, nil
		}
	}
	if len(n.dependentSchemas) > 0 && v.Kind() == jsonvalue.KindObject {
		for _, d := range n.dependentSchemas {
			if v.Object().Has(d.name) && !s.apply(d.child, v, collecting, a) {
				return false, nil
			}
		}
	}
	if s.err != nil {
		return false, nil
	}

	// unevaluated*: see everything collected above.
	if n.unevaluatedItems != nil && v.Kind() == jsonvalue.KindArray {
		arr := v.Array()
		for i := range arr {
			if a.items.has(i) {
				continue
			}
			if ok, _ := s.eval(n.unevaluatedItems, &arr[i], false); !ok {
				return false, nil
			}
			a.items.set(i)
		}
	}
	if n.unevaluatedProperties != nil && v.Kind() == jsonvalue.KindObject {
		ms := v.Object().Members()
		for i := range ms {
			if a.props.has(i) {
				continue
			}
			if ok, _ := s.eval(n.unevaluatedProperties, &ms[i].Value, false); !ok {
				return false, nil
			}
			a.props.set(i)
		}
	}
	return true, a
}

// apply evaluates an in-place child against the same instance and merges its
// annotations into a on success.
func (s *state) apply(c *node, v *jsonvalue.Value, collecting bool, a *annot) bool {
	ok, ca := s.eval(c, v, collecting)
	if ok {
		a.merge(ca)
	}
	return ok
}

func checkNumber(n *node, x jsonvalue.Number) bool {
	if n.multipleOf != nil && n.multipleOf.Sign() > 0 && !x.MultipleOf(*n.multipleOf) {
		return false
	}
	if n.maximum != nil && x.Cmp(*n.maximum) > 0 {
		return false
	}
	if n.minimum != nil && x.Cmp(*n.minimum) < 0 {
		return false
	}
	if n.exclusiveMax != nil && x.Cmp(*n.exclusiveMax) >= 0 {
		return false
	}
	if n.exclusiveMin != nil && x.Cmp(*n.exclusiveMin) <= 0 {
		return false
	}
	return true
}

// codePoints counts the code points of a UTF-8 string by counting bytes that
// are not continuation bytes.
func codePoints(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i]&0xC0 != 0x80 {
			n++
		}
	}
	return n
}

func (s *state) checkString(n *node, str string) bool {
	if n.maxLength.set || n.minLength.set {
		l := codePoints(str)
		if n.maxLength.gt(l) || n.minLength.lt(l) {
			return false
		}
	}
	if n.pattern != nil {
		if n.pattern.err != nil {
			return s.fail(n.pattern.err)
		}
		if !n.pattern.re.MatchString(str) {
			return false
		}
	}
	return true
}

func (s *state) evalArray(n *node, v *jsonvalue.Value, collecting bool, a *annot) bool {
	arr := v.Array()
	l := len(arr)
	if n.maxItems.gt(l) || n.minItems.lt(l) {
		return false
	}
	if n.uniqueItems && !allUnique(arr) {
		return false
	}
	for i := 0; i < len(n.prefixItems) && i < l; i++ {
		if ok, _ := s.eval(n.prefixItems[i], &arr[i], false); !ok {
			return false
		}
		if collecting {
			a.items.set(i)
		}
	}
	if n.items != nil {
		for i := len(n.prefixItems); i < l; i++ {
			if ok, _ := s.eval(n.items, &arr[i], false); !ok {
				return false
			}
			if collecting {
				a.items.set(i)
			}
		}
	}
	if n.contains != nil {
		minC := int64(1)
		if n.minContains.set {
			minC = n.minContains.v
		}
		matches := int64(0)
		for i := range arr {
			if ok, _ := s.eval(n.contains, &arr[i], false); ok {
				matches++
				if collecting {
					a.items.set(i)
				} else if !n.maxContains.set && matches >= minC {
					break
				}
			}
		}
		if matches < minC || (n.maxContains.set && matches > n.maxContains.v) {
			return false
		}
	}
	return s.err == nil
}

func (s *state) evalMembers(n *node, v *jsonvalue.Value, collecting bool, a *annot) bool {
	obj := v.Object()
	ms := obj.Members()
	l := len(ms)
	if n.maxProperties.gt(l) || n.minProperties.lt(l) {
		return false
	}
	for _, name := range n.required {
		if !obj.Has(name) {
			return false
		}
	}
	for _, d := range n.dependentRequired {
		if obj.Has(d.name) {
			for _, name := range d.names {
				if !obj.Has(name) {
					return false
				}
			}
		}
	}
	if n.properties != nil || n.patternProperties != nil || n.additionalProperties != nil {
		for i := range ms {
			m := &ms[i]
			matched := false
			if child, ok := n.properties[m.Key]; ok {
				matched = true
				if ok, _ := s.eval(child, &m.Value, false); !ok {
					return false
				}
			}
			for _, pp := range n.patternProperties {
				if pp.pat.err != nil {
					return s.fail(pp.pat.err)
				}
				if pp.pat.re.MatchString(m.Key) {
					matched = true
					if ok, _ := s.eval(pp.child, &m.Value, false); !ok {
						return false
					}
				}
			}
			if !matched && n.additionalProperties != nil {
				matched = true
				if ok, _ := s.eval(n.additionalProperties, &m.Value, false); !ok {
					return false
				}
			}
			if matched && collecting {
				a.props.set(i)
			}
		}
	}
	if n.propertyNames != nil {
		for i := range ms {
			name := jsonvalue.NewString(ms[i].Key)
			if ok, _ := s.eval(n.propertyNames, &name, false); !ok {
				return false
			}
		}
	}
	return s.err == nil
}
