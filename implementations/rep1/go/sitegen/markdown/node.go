package markdown

type kind uint8

const (
	kDocument kind = iota
	kBlockQuote
	kList
	kItem
	kParagraph
	kHeading
	kThematicBreak
	kCodeBlock

	kText
	kSoftBreak
	kLineBreak
	kCode
	kEmph
	kStrong
	kLink
	kImage
)

// node is a node of the document tree, used for both blocks and inlines.
// Children form a doubly linked list so that nodes can be moved and removed
// in constant time.
type node struct {
	kind                      kind
	parent, first, last, prev *node
	next                      *node

	// Block state.
	open            bool
	lastLineBlank   bool
	lastLineChecked bool
	startLine       int
	content         []byte // raw text accumulated by leaf blocks

	// Lists and items.
	ordered      bool
	bullet       byte // bullet character of a bullet list, else 0
	delim        byte // '.' or ')' of an ordered list, else 0
	start        int
	tight        bool
	markerOffset int
	padding      int

	// Headings.
	level int

	// Code blocks.
	fenced      bool
	fenceChar   byte
	fenceLen    int
	fenceOffset int
	info        string

	// Inlines: literal text of text and code nodes; destination and title of
	// links and images.
	lit      string
	dest     string
	title    string
	hasTitle bool
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

// insertAfter links c into the child list immediately after n.
func (n *node) insertAfter(c *node) {
	c.parent = n.parent
	c.prev = n
	c.next = n.next
	if n.next != nil {
		n.next.prev = c
	} else if n.parent != nil {
		n.parent.last = c
	}
	n.next = c
}
