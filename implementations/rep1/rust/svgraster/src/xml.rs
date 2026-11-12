//! A tiny non-validating XML parser sufficient for SVG documents.
//!
//! Only elements and attributes are kept. Processing instructions, comments,
//! `DOCTYPE` declarations, CDATA sections and character data are skipped.
//! Namespace prefixes are stripped from element and attribute names.

use std::collections::HashMap;
use std::fmt;

/// Index of an element in a [`Document`].
pub type NodeId = usize;

/// One XML element.
#[derive(Debug, Clone, Default)]
pub struct Element {
    /// Tag name with any namespace prefix removed.
    pub tag: String,
    /// Attributes keyed by prefix-stripped name; the last duplicate wins.
    pub attrs: HashMap<String, String>,
    /// Child elements in document order.
    pub children: Vec<NodeId>,
}

impl Element {
    /// Returns the value of attribute `name`, if present.
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attrs.get(name).map(String::as_str)
    }
}

/// A parsed document: an arena of elements plus the root element.
#[derive(Debug, Clone)]
pub struct Document {
    nodes: Vec<Element>,
    root: NodeId,
}

/// Errors produced while parsing XML.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum XmlError {
    /// The input contains no start tag.
    NoRoot,
    /// The input ended in the middle of a construct.
    UnexpectedEnd,
}

impl fmt::Display for XmlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            XmlError::NoRoot => write!(f, "document has no root element"),
            XmlError::UnexpectedEnd => write!(f, "unexpected end of XML input"),
        }
    }
}

impl std::error::Error for XmlError {}

impl Document {
    /// The document element.
    pub fn root(&self) -> NodeId {
        self.root
    }

    /// Returns the element with the given id.
    pub fn get(&self, id: NodeId) -> &Element {
        &self.nodes[id]
    }

    /// Iterates over all elements in document order (depth first).
    pub fn iter_ids(&self) -> impl Iterator<Item = NodeId> + '_ {
        // Nodes are pushed to the arena when their start tag is read, so the
        // arena order is document order.
        0..self.nodes.len()
    }

    /// Parses `src` into a document.
    pub fn parse(src: &str) -> Result<Document, XmlError> {
        let b = src.as_bytes();
        let mut nodes: Vec<Element> = Vec::new();
        let mut stack: Vec<NodeId> = Vec::new();
        let mut root: Option<NodeId> = None;
        let mut i = 0;
        while i < b.len() {
            if b[i] != b'<' {
                i += 1;
                continue;
            }
            if b[i..].starts_with(b"<?") {
                i = find(b, i + 2, b"?>").ok_or(XmlError::UnexpectedEnd)? + 2;
            } else if b[i..].starts_with(b"<!--") {
                i = find(b, i + 4, b"-->").ok_or(XmlError::UnexpectedEnd)? + 3;
            } else if b[i..].starts_with(b"<![CDATA[") {
                i = find(b, i + 9, b"]]>").ok_or(XmlError::UnexpectedEnd)? + 3;
            } else if b[i..].starts_with(b"<!") {
                i = skip_declaration(b, i + 2)?;
            } else if b[i..].starts_with(b"</") {
                let end = find(b, i + 2, b">").ok_or(XmlError::UnexpectedEnd)?;
                stack.pop();
                i = end + 1;
                if stack.is_empty() && root.is_some() {
                    break;
                }
            } else {
                let (el, self_closing, next) = parse_start_tag(src, i + 1)?;
                let id = nodes.len();
                nodes.push(el);
                match stack.last() {
                    Some(&p) => nodes[p].children.push(id),
                    None => {
                        if root.is_none() {
                            root = Some(id);
                        }
                    }
                }
                if !self_closing {
                    stack.push(id);
                } else if stack.is_empty() {
                    break;
                }
                i = next;
            }
        }
        match root {
            Some(root) => Ok(Document { nodes, root }),
            None => Err(XmlError::NoRoot),
        }
    }
}

fn find(b: &[u8], from: usize, pat: &[u8]) -> Option<usize> {
    if from > b.len() {
        return None;
    }
    b[from..].windows(pat.len()).position(|w| w == pat).map(|p| p + from)
}

/// Skips a `<!...>` declaration (e.g. `DOCTYPE`), honouring an internal
/// `[...]` subset and quoted strings. `i` points just after `<!`.
fn skip_declaration(b: &[u8], mut i: usize) -> Result<usize, XmlError> {
    let mut depth = 0usize;
    while i < b.len() {
        match b[i] {
            b'"' | b'\'' => {
                let q = b[i];
                i += 1;
                while i < b.len() && b[i] != q {
                    i += 1;
                }
            }
            b'<' if b[i..].starts_with(b"<!--") => {
                i = find(b, i + 4, b"-->").ok_or(XmlError::UnexpectedEnd)? + 2;
            }
            b'[' => depth += 1,
            b']' => depth = depth.saturating_sub(1),
            b'>' if depth == 0 => return Ok(i + 1),
            _ => {}
        }
        i += 1;
    }
    Err(XmlError::UnexpectedEnd)
}

fn strip_prefix(name: &str) -> &str {
    match name.rfind(':') {
        Some(p) => &name[p + 1..],
        None => name,
    }
}

/// Parses a start tag whose name begins at `i`. Returns the element, whether
/// it was self-closing, and the index just past the closing `>`.
fn parse_start_tag(src: &str, mut i: usize) -> Result<(Element, bool, usize), XmlError> {
    let b = src.as_bytes();
    let is_ws = |c: u8| c.is_ascii_whitespace();
    let start = i;
    while i < b.len() && !is_ws(b[i]) && b[i] != b'/' && b[i] != b'>' {
        i += 1;
    }
    let mut el = Element { tag: strip_prefix(&src[start..i]).to_string(), ..Default::default() };
    loop {
        while i < b.len() && is_ws(b[i]) {
            i += 1;
        }
        if i >= b.len() {
            return Err(XmlError::UnexpectedEnd);
        }
        match b[i] {
            b'>' => return Ok((el, false, i + 1)),
            b'/' => {
                // "/>"; tolerate stray slashes.
                if i + 1 < b.len() && b[i + 1] == b'>' {
                    return Ok((el, true, i + 2));
                }
                i += 1;
            }
            _ => {
                let ns = i;
                while i < b.len() && !is_ws(b[i]) && b[i] != b'=' && b[i] != b'>' && b[i] != b'/' {
                    i += 1;
                }
                let name = strip_prefix(&src[ns..i]).to_string();
                while i < b.len() && is_ws(b[i]) {
                    i += 1;
                }
                if i < b.len() && b[i] == b'=' {
                    i += 1;
                    while i < b.len() && is_ws(b[i]) {
                        i += 1;
                    }
                    if i < b.len() && (b[i] == b'"' || b[i] == b'\'') {
                        let q = b[i];
                        let vs = i + 1;
                        let ve = b[vs..].iter().position(|&c| c == q).ok_or(XmlError::UnexpectedEnd)? + vs;
                        el.attrs.insert(name, decode_entities(&src[vs..ve]));
                        i = ve + 1;
                    }
                } else if name.is_empty() {
                    i += 1; // avoid an infinite loop on stray characters
                }
            }
        }
    }
}

/// Resolves the five predefined entities and numeric character references.
/// Any other `&...;` sequence is left untouched.
pub fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(p) = rest.find('&') {
        out.push_str(&rest[..p]);
        rest = &rest[p..];
        let decoded = rest.find(';').and_then(|semi| {
            let name = &rest[1..semi];
            let ch = match name {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                _ => name.strip_prefix('#').and_then(|n| {
                    let code = match n.strip_prefix('x').or_else(|| n.strip_prefix('X')) {
                        Some(h) => u32::from_str_radix(h, 16).ok(),
                        None => n.parse::<u32>().ok(),
                    };
                    code.and_then(char::from_u32)
                }),
            };
            ch.map(|c| (c, semi + 1))
        });
        match decoded {
            Some((c, len)) => {
                out.push(c);
                rest = &rest[len..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_nested_elements_and_strips_prefixes() {
        let d = Document::parse(
            "<?xml version='1.0'?><!DOCTYPE svg [ <!ENTITY a \"b>\"> ]><!-- c --><svg:svg xmlns:svg='u'>\
             <g id='a'><![CDATA[ <x/> ]]><rect xlink:href=\"#q\" width='1'/></g></svg:svg>",
        )
        .unwrap();
        let root = d.get(d.root());
        assert_eq!(root.tag, "svg");
        let g = d.get(root.children[0]);
        assert_eq!(g.attr("id"), Some("a"));
        let rect = d.get(g.children[0]);
        assert_eq!(rect.tag, "rect");
        assert_eq!(rect.attr("href"), Some("#q"));
    }

    #[test]
    fn gt_in_attribute_value_and_duplicates() {
        let d = Document::parse("<svg a=\"1\" a='x>y'/>").unwrap();
        assert_eq!(d.get(d.root()).attr("a"), Some("x>y"));
    }

    #[test]
    fn entities() {
        assert_eq!(decode_entities("&amp;&lt;&gt;&quot;&apos;&#65;&#x42;&foo;&"), "&<>\"'AB&foo;&");
    }

    #[test]
    fn empty_input_is_an_error() {
        assert_eq!(Document::parse("  ").unwrap_err(), XmlError::NoRoot);
    }
}
