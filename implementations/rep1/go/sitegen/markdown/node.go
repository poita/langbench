package markdown

type nodeType uint8

const (
	// Blocks.
	nDocument nodeType = iota
	nBlockQuote
	nList
	nItem
	nCodeBlock
	nParagraph
	nHeading
	nThematicBreak
	// Inlines.
	nText
	nSoftbreak
	nLinebreak
	nCode
	nEmph
	nStrong
	nLink
	nImage
)

// listData holds the properties of lists and list items.
type listData struct {
	ordered      bool
	delim        byte // '.' or ')' for ordered lists
	bullet       byte // '-', '+' or '*' for bullet lists
	start        int
	tight        bool
	markerOffset int
	padding      int
}

// node is a block or inline node. Children form a doubly linked list.
type node struct {
	typ                   nodeType
	parent, first, last   *node
	prev, next            *node
	open                  bool
	lastLineBlank         bool
	lastLineChecked       bool
	startLine             int
	content               []byte // raw text of leaf blocks (before inline parsing)
	literal               string // text of inline text/code nodes, content of code blocks
	list                  *listData
	level                 int // heading level
	fenced                bool
	fenceChar             byte
	fenceLen, fenceOffset int
	info                  string
	setext                bool
	dest, title           string
	hasTitle              bool
}

func (n *node) appendChild(c *node) {
	c.parent = n
	c.prev = n.last
	c.next = nil
	if n.last != nil {
		n.last.next = c
	} else {
		n.first = c
	}
	n.last = c
}

// unlink removes n from its parent's child list.
func (n *node) unlink() {
	if n.prev != nil {
		n.prev.next = n.next
	} else if n.parent != nil {
		n.parent.first = n.next
	}
	if n.next != nil {
		n.next.prev = n.prev
	} else if n.parent != nil {
		n.parent.last = n.prev
	}
	n.parent, n.prev, n.next = nil, nil, nil
}

// insertAfter links c into n's parent right after n.
func (n *node) insertAfter(c *node) {
	c.parent = n.parent
	c.prev = n
	c.next = n.next
	if n.next != nil {
		n.next.prev = c
	} else {
		n.parent.last = c
	}
	n.next = c
}
