package typeinfer

// The type graph. Types are nodes in a single arena indexed by int32; a
// node's children are reached by index, never through a map. Sub-terms are
// shared, and unification mutates variable nodes in place (union-find).

type nodeKind uint8

const (
	kVar nodeKind = iota
	kInt
	kBool
	kUnit
	kArrow
	kList
	kTuple
)

// Indices of the shared singleton nodes.
const (
	tInt  int32 = 0
	tBool int32 = 1
	tUnit int32 = 2
)

// genericLevel marks a quantified variable.
const genericLevel = int32(1<<31 - 1)

const noLink = int32(-1)

// node is a type node.
//
//	kVar:   a = link to the representative (noLink if unbound), level.
//	kArrow: a = argument, b = result.
//	kList:  a = element.
//	kTuple: pool[a : a+b] are the components.
//
// stamp and memo are scratch slots for the walks (occurs check,
// generalisation, instantiation, printing): memo is only meaningful when
// stamp equals the current walk's stamp.
type node struct {
	stamp uint64
	level int32
	a, b  int32
	memo  int32
	kind  nodeKind
}

func (c *Checker) newVar(level int32) int32 {
	c.nodes = append(c.nodes, node{kind: kVar, level: level, a: noLink})
	return int32(len(c.nodes) - 1)
}

func (c *Checker) newArrow(arg, res int32) int32 {
	c.nodes = append(c.nodes, node{kind: kArrow, a: arg, b: res})
	return int32(len(c.nodes) - 1)
}

func (c *Checker) newList(elem int32) int32 {
	c.nodes = append(c.nodes, node{kind: kList, a: elem})
	return int32(len(c.nodes) - 1)
}

// newTuple creates an n-ary tuple node whose components are the n pool slots
// starting at start.
func (c *Checker) newTuple(start, n int32) int32 {
	c.nodes = append(c.nodes, node{kind: kTuple, a: start, b: n})
	return int32(len(c.nodes) - 1)
}

// reservePool appends n zeroed slots to the component pool and returns the
// index of the first.
func (c *Checker) reservePool(n int32) int32 {
	start := int32(len(c.pool))
	for i := int32(0); i < n; i++ {
		c.pool = append(c.pool, 0)
	}
	return start
}

// find returns the representative of t, compressing the path.
func (c *Checker) find(t int32) int32 {
	nodes := c.nodes
	root := t
	for nodes[root].kind == kVar && nodes[root].a != noLink {
		root = nodes[root].a
	}
	for t != root {
		next := nodes[t].a
		nodes[t].a = root
		t = next
	}
	return root
}

func (c *Checker) newStamp() uint64 {
	c.stamp++
	return c.stamp
}
