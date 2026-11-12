// Package ast defines the document tree produced by the CommonMark parser.
//
// A tree is made of [Node] values linked through Parent, FirstChild,
// LastChild, Prev and Next pointers, so that unlinking a node, appending a
// child or moving a run of siblings under a new parent all cost O(1) per node
// touched. Block nodes (document, block quote, list, list item, paragraph,
// heading, thematic break, code block) form the upper levels of the tree; the
// content of paragraphs and headings is made of inline nodes.
package ast

// Kind identifies the type of a [Node].
type Kind uint8

// Node kinds. Kinds up to and including CodeBlock are blocks, the rest are
// inlines.
const (
	Document Kind = iota
	BlockQuote
	List
	Item
	Paragraph
	Heading
	ThematicBreak
	CodeBlock

	Text
	Softbreak
	Linebreak
	Code
	Emph
	Strong
	Link
	Image
)

var kindNames = [...]string{
	Document: "document", BlockQuote: "block_quote", List: "list",
	Item: "item", Paragraph: "paragraph", Heading: "heading",
	ThematicBreak: "thematic_break", CodeBlock: "code_block",
	Text: "text", Softbreak: "softbreak", Linebreak: "linebreak",
	Code: "code", Emph: "emph", Strong: "strong", Link: "link", Image: "image",
}

// String returns the lower-case name of the kind.
func (k Kind) String() string {
	if int(k) < len(kindNames) {
		return kindNames[k]
	}
	return "unknown"
}

// IsBlock reports whether k is a block kind.
func (k Kind) IsBlock() bool { return k <= CodeBlock }

// ListType distinguishes bullet lists from ordered lists.
type ListType uint8

// List types.
const (
	Bullet ListType = iota
	Ordered
)

// ListData describes a List node.
type ListData struct {
	Type  ListType
	Delim byte // the bullet character, or '.' / ')' for ordered lists
	Start int  // first number of an ordered list
	Tight bool // true if the list is tight
}

// ParseState is the bookkeeping the block parser keeps on block nodes while it
// builds the tree. Its contents are not meaningful to users of the tree.
type ParseState struct {
	Open            bool
	LastLineBlank   bool
	LastLineChecked bool
	Fenced          bool
	Setext          bool
	FenceChar       byte
	FenceLength     int
	FenceOffset     int
	MarkerOffset    int // list items: indentation of the marker
	Padding         int // list items: width of marker plus following spaces
	StartLine       int
	Content         []byte // raw text of paragraphs, headings and code blocks
}

// Node is an element of the document tree.
type Node struct {
	Kind Kind

	Parent, FirstChild, LastChild, Prev, Next *Node

	// Literal is the text of Text and Code nodes and the content of CodeBlock
	// nodes.
	Literal string
	// Level is the level (1-6) of a Heading.
	Level int
	// Info is the (decoded) info string of a fenced CodeBlock.
	Info string
	// Dest and Title are the destination and title of a Link or Image;
	// HasTitle distinguishes an empty title from none.
	Dest, Title string
	HasTitle    bool
	// List holds the properties of a List node.
	List ListData

	// State is non-nil on block nodes only.
	State *ParseState
}

// New returns a detached node of the given kind. Block nodes get a ParseState.
func New(k Kind) *Node {
	n := &Node{Kind: k}
	if k.IsBlock() {
		n.State = &ParseState{}
	}
	return n
}

// AppendChild adds c, which must be detached, as the last child of n.
func (n *Node) AppendChild(c *Node) {
	c.Parent = n
	c.Next = nil
	c.Prev = n.LastChild
	if n.LastChild != nil {
		n.LastChild.Next = c
	} else {
		n.FirstChild = c
	}
	n.LastChild = c
}

// Unlink detaches n from its parent and siblings.
func (n *Node) Unlink() {
	if n.Prev != nil {
		n.Prev.Next = n.Next
	} else if n.Parent != nil {
		n.Parent.FirstChild = n.Next
	}
	if n.Next != nil {
		n.Next.Prev = n.Prev
	} else if n.Parent != nil {
		n.Parent.LastChild = n.Prev
	}
	n.Parent, n.Prev, n.Next = nil, nil, nil
}

// InsertAfter places the detached node c immediately after n among n's
// siblings.
func (n *Node) InsertAfter(c *Node) {
	c.Parent = n.Parent
	c.Prev = n
	c.Next = n.Next
	if n.Next != nil {
		n.Next.Prev = c
	} else if n.Parent != nil {
		n.Parent.LastChild = c
	}
	n.Next = c
}

// AdoptRange moves the run of siblings first..last (first and last included)
// to the end of n's children. n must not be inside the run. The cost is
// proportional to the number of nodes moved.
func (n *Node) AdoptRange(first, last *Node) {
	if first == nil {
		return
	}
	p := first.Parent
	before, after := first.Prev, last.Next
	if before != nil {
		before.Next = after
	} else {
		p.FirstChild = after
	}
	if after != nil {
		after.Prev = before
	} else {
		p.LastChild = before
	}
	first.Prev = n.LastChild
	if n.LastChild != nil {
		n.LastChild.Next = first
	} else {
		n.FirstChild = first
	}
	last.Next = nil
	n.LastChild = last
	for c := first; c != nil; c = c.Next {
		c.Parent = n
	}
}

// WalkStatus tells Walk how to proceed.
type WalkStatus uint8

// Walk statuses.
const (
	Continue     WalkStatus = iota // visit the children next
	SkipChildren                   // do not visit the children of this node
)

// Walk traverses the tree rooted at root depth first, without recursion. fn
// is called with entering=true before a node's children and with
// entering=false after them; leaves are visited with both calls. fn may add
// children to the node being entered, and returns SkipChildren (on entry) to
// avoid descending.
func Walk(root *Node, fn func(n *Node, entering bool) WalkStatus) {
	n := root
	for n != nil {
		if fn(n, true) == Continue && n.FirstChild != nil {
			n = n.FirstChild
			continue
		}
		for {
			fn(n, false)
			if n == root {
				return
			}
			if n.Next != nil {
				n = n.Next
				break
			}
			n = n.Parent
		}
	}
}
