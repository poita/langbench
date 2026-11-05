package commonmark

// blockKind identifies the type of a block node.
type blockKind uint8

const (
	kDocument blockKind = iota
	kBlockQuote
	kList
	kItem
	kParagraph
	kHeading
	kThematicBreak
	kCodeBlock
)

// block is a node of the block tree. Children form a doubly linked list so
// that every structural change is O(1).
type block struct {
	kind blockKind

	open            bool
	lastLineBlank   bool
	lastLineChecked bool

	// list
	ordered bool
	tight   bool
	// listChar is the bullet character of a bullet list, or the '.' / ')'
	// delimiter of an ordered list.
	listChar byte
	start    int

	// list item
	markerOffset int
	padding      int

	// code block
	fenced      bool
	fenceChar   byte
	fenceLen    int
	fenceOffset int
	info        []byte

	// heading
	level  int
	setext bool

	startLine int

	// content holds the raw text of paragraphs, headings and code blocks.
	content []byte

	parent, first, last, next, prev *block
}

// appendChild adds c as the last child of b.
func (b *block) appendChild(c *block) {
	c.parent = b
	c.prev = b.last
	c.next = nil
	if b.last != nil {
		b.last.next = c
	} else {
		b.first = c
	}
	b.last = c
}

// canContain reports whether a block of kind parent may contain a block of
// kind child.
func canContain(parent, child blockKind) bool {
	switch parent {
	case kDocument, kBlockQuote, kItem:
		return child != kItem
	case kList:
		return child == kItem
	}
	return false
}

// acceptsLines reports whether blocks of this kind collect raw text lines.
func acceptsLines(k blockKind) bool {
	return k == kParagraph || k == kHeading || k == kCodeBlock
}
