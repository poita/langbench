//! The document tree.
//!
//! Both block and inline nodes live in one arena ([`Tree`]) and refer to each
//! other through [`NodeId`] indices. Siblings are doubly linked so that
//! re-parenting a run of inline nodes (wrapping them in emphasis, a link, …)
//! costs O(1) regardless of how many nodes are moved, and the whole tree can
//! be traversed and dropped without recursion, however deeply it nests.

/// Index of a node inside a [`Tree`].
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug, PartialOrd, Ord)]
pub struct NodeId(pub(crate) u32);

impl NodeId {
    #[inline]
    pub(crate) fn idx(self) -> usize {
        self.0 as usize
    }
}

/// Properties of a list node.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListData {
    /// `true` for an ordered list (`1.` / `1)`), `false` for a bullet list.
    pub ordered: bool,
    /// The bullet character (`-`, `+`, `*`) or the ordered delimiter
    /// (`.` or `)`). Items with a different marker start a new list.
    pub marker: char,
    /// The number of the first item (meaningful for ordered lists only).
    pub start: u32,
    /// Whether the list is tight (items are not separated by blank lines, so
    /// paragraphs inside them render without `<p>` tags).
    pub tight: bool,
}

/// What a node is, together with its payload.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NodeKind {
    /// The root of the tree.
    Document,
    /// `> …`
    BlockQuote,
    /// A bullet or ordered list; its children are all [`NodeKind::Item`]s.
    List(ListData),
    /// A list item.
    Item,
    /// A paragraph; children are inline nodes.
    Paragraph,
    /// An ATX or setext heading; children are inline nodes.
    Heading {
        /// Heading level, 1 to 6.
        level: u8,
    },
    /// `***`, `---` or `___`.
    ThematicBreak,
    /// An indented or fenced code block.
    CodeBlock {
        /// The info string (empty for indented blocks).
        info: String,
        /// The literal text of the block.
        literal: String,
    },
    /// Literal text.
    Text(String),
    /// A soft line break.
    SoftBreak,
    /// A hard line break.
    LineBreak,
    /// A code span.
    Code(String),
    /// Emphasis (`<em>`).
    Emph,
    /// Strong emphasis (`<strong>`).
    Strong,
    /// A link; children are the link text.
    Link {
        /// Destination URL (decoded, not yet percent-encoded).
        dest: String,
        /// Optional title.
        title: Option<String>,
    },
    /// An image; children are the description.
    Image {
        /// Destination URL (decoded, not yet percent-encoded).
        dest: String,
        /// Optional title.
        title: Option<String>,
    },
}

/// A node of the tree: its kind plus links to its relatives.
#[derive(Clone, Debug)]
pub struct Node {
    pub(crate) kind: NodeKind,
    pub(crate) parent: Option<NodeId>,
    pub(crate) first_child: Option<NodeId>,
    pub(crate) last_child: Option<NodeId>,
    pub(crate) prev: Option<NodeId>,
    pub(crate) next: Option<NodeId>,
}

impl Node {
    /// The kind (and payload) of this node.
    pub fn kind(&self) -> &NodeKind {
        &self.kind
    }
    /// The parent node, `None` for the document root.
    pub fn parent(&self) -> Option<NodeId> {
        self.parent
    }
    /// The first child, if any.
    pub fn first_child(&self) -> Option<NodeId> {
        self.first_child
    }
    /// The last child, if any.
    pub fn last_child(&self) -> Option<NodeId> {
        self.last_child
    }
    /// The previous sibling, if any.
    pub fn prev_sibling(&self) -> Option<NodeId> {
        self.prev
    }
    /// The next sibling, if any.
    pub fn next_sibling(&self) -> Option<NodeId> {
        self.next
    }
}

/// Arena holding every node of a document. The root is always [`Tree::ROOT`].
#[derive(Clone, Debug)]
pub struct Tree {
    pub(crate) nodes: Vec<Node>,
}

impl Default for Tree {
    fn default() -> Self {
        Tree::new()
    }
}

impl Tree {
    /// Id of the document node.
    pub const ROOT: NodeId = NodeId(0);

    /// Creates a tree containing only the document node.
    pub fn new() -> Tree {
        let mut t = Tree { nodes: Vec::new() };
        t.add(NodeKind::Document);
        t
    }

    /// Returns the node with the given id.
    #[inline]
    pub fn node(&self, id: NodeId) -> &Node {
        &self.nodes[id.idx()]
    }

    #[inline]
    pub(crate) fn node_mut(&mut self, id: NodeId) -> &mut Node {
        &mut self.nodes[id.idx()]
    }

    /// Iterates over the children of `id`, in order.
    pub fn children(&self, id: NodeId) -> Children<'_> {
        Children {
            tree: self,
            next: self.node(id).first_child,
        }
    }

    /// Adds a detached node and returns its id.
    pub(crate) fn add(&mut self, kind: NodeKind) -> NodeId {
        let id = NodeId(self.nodes.len() as u32);
        self.nodes.push(Node {
            kind,
            parent: None,
            first_child: None,
            last_child: None,
            prev: None,
            next: None,
        });
        id
    }

    /// Appends the detached node `child` to the children of `parent`.
    pub(crate) fn append_child(&mut self, parent: NodeId, child: NodeId) {
        let last = self.nodes[parent.idx()].last_child;
        {
            let c = &mut self.nodes[child.idx()];
            c.parent = Some(parent);
            c.prev = last;
            c.next = None;
        }
        match last {
            Some(l) => self.nodes[l.idx()].next = Some(child),
            None => self.nodes[parent.idx()].first_child = Some(child),
        }
        self.nodes[parent.idx()].last_child = Some(child);
    }

    /// Removes `node` from the child list of `parent` (O(1)).
    pub(crate) fn unlink(&mut self, parent: NodeId, node: NodeId) {
        let (prev, next) = {
            let n = &self.nodes[node.idx()];
            (n.prev, n.next)
        };
        match prev {
            Some(p) => self.nodes[p.idx()].next = next,
            None => self.nodes[parent.idx()].first_child = next,
        }
        match next {
            Some(n) => self.nodes[n.idx()].prev = prev,
            None => self.nodes[parent.idx()].last_child = prev,
        }
        let n = &mut self.nodes[node.idx()];
        n.prev = None;
        n.next = None;
    }

    /// Makes every node's `parent` link consistent with the child lists.
    ///
    /// The inline parser moves runs of nodes between parents without touching
    /// each moved node (that is what keeps wrapping O(1)); this single linear
    /// pass repairs the links afterwards.
    pub(crate) fn fix_parents(&mut self) {
        for i in 0..self.nodes.len() {
            let mut c = self.nodes[i].first_child;
            while let Some(id) = c {
                self.nodes[id.idx()].parent = Some(NodeId(i as u32));
                c = self.nodes[id.idx()].next;
            }
        }
    }
}

/// Iterator over the children of a node.
pub struct Children<'a> {
    tree: &'a Tree,
    next: Option<NodeId>,
}

impl<'a> Iterator for Children<'a> {
    type Item = NodeId;
    fn next(&mut self) -> Option<NodeId> {
        let cur = self.next?;
        self.next = self.tree.node(cur).next;
        Some(cur)
    }
}
