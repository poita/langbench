//! A parsed message: its MIME tree plus body and attachment selection.

use crate::address::{parse_address_list, Address};
use crate::date::{parse_date, ParsedDate};
use crate::header::{find_field, Field};
use crate::part::{parse_parts, Kind, Part};

/// The address headers, in output order.
pub const ADDRESS_HEADERS: [&str; 6] = ["from", "sender", "reply-to", "to", "cc", "bcc"];

/// The `Date` header of a message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DateInfo {
    /// The unfolded raw value.
    pub raw: String,
    /// The parsed date, if valid.
    pub parsed: Option<ParsedDate>,
}

/// A fully parsed message.
#[derive(Debug, Clone)]
pub struct Message {
    /// Length in bytes of the message as extracted from the mailbox.
    pub size: usize,
    /// All parts in pre-order; `parts[0]` is the message itself.
    pub parts: Vec<Part>,
    /// Index of the selected plain-text body part.
    pub text_body: Option<usize>,
    /// Index of the selected HTML body part.
    pub html_body: Option<usize>,
    /// Indices of attachment parts in ascending order.
    pub attachments: Vec<usize>,
}

impl Message {
    /// Parses a message from its raw bytes.
    pub fn parse(bytes: &[u8]) -> Message {
        let parts = parse_parts(bytes);
        let (text_body, html_body, attachments) = select(&parts);
        Message { size: bytes.len(), parts, text_body, html_body, attachments }
    }

    /// The top-level header fields.
    pub fn headers(&self) -> &[Field] {
        &self.parts[0].headers
    }

    /// The first top-level header named `name` (lower case).
    pub fn header(&self, name: &str) -> Option<&Field> {
        find_field(self.headers(), name)
    }

    /// The addresses of all top-level fields named `name`, in order.
    pub fn addresses(&self, name: &str) -> Vec<Address> {
        self.headers()
            .iter()
            .filter(|f| f.key() == name)
            .flat_map(|f| parse_address_list(&f.raw_value))
            .collect()
    }

    /// The `Date` header, if any.
    pub fn date(&self) -> Option<DateInfo> {
        self.header("date")
            .map(|f| DateInfo { raw: f.raw_value.clone(), parsed: parse_date(&f.raw_value) })
    }

    /// The role of part `index`: `text`, `html` or `attachment` for leaves.
    pub fn role(&self, index: usize) -> Option<&'static str> {
        if !self.parts[index].is_leaf() {
            None
        } else if self.text_body == Some(index) {
            Some("text")
        } else if self.html_body == Some(index) {
            Some("html")
        } else {
            Some("attachment")
        }
    }
}

fn select(parts: &[Part]) -> (Option<usize>, Option<usize>, Vec<usize>) {
    let mut text = None;
    let mut html = None;
    let mut skip_below: Option<usize> = None; // depth of the rfc822 container being skipped
    for p in parts {
        if let Some(d) = skip_below {
            if p.depth > d {
                continue;
            }
            skip_below = None;
        }
        if p.kind == Kind::Message {
            skip_below = Some(p.depth);
            continue;
        }
        let candidate = p.is_leaf() && p.disposition.as_deref() != Some("attachment");
        if candidate {
            if text.is_none() && p.main_type == "text" && p.sub_type == "plain" {
                text = Some(p.index);
            } else if html.is_none() && p.main_type == "text" && p.sub_type == "html" {
                html = Some(p.index);
            }
        }
    }
    let attachments = parts
        .iter()
        .filter(|p| p.is_leaf() && Some(p.index) != text && Some(p.index) != html)
        .map(|p| p.index)
        .collect();
    (text, html, attachments)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn selects_bodies_and_attachments() {
        let msg = b"Content-Type: multipart/mixed; boundary=B\n\n\
--B\nContent-Disposition: attachment\n\nfirst\n\
--B\n\nsecond\n\
--B\nContent-Type: text/plain\n\nthird\n\
--B\nContent-Type: text/html\n\n<p>\n\
--B\nContent-Type: message/rfc822\n\nContent-Type: text/html\n\nx\n\
--B--\n";
        let m = Message::parse(msg);
        assert_eq!(m.text_body, Some(2));
        assert_eq!(m.html_body, Some(4));
        assert_eq!(m.attachments, vec![1, 3, 6]);
        assert_eq!(m.role(0), None);
        assert_eq!(m.role(2), Some("text"));
        assert_eq!(m.role(6), Some("attachment"));
    }

    #[test]
    fn inline_disposition_is_candidate() {
        let m = Message::parse(b"Content-Disposition: inline; filename=a.txt\n\nhi\n");
        assert_eq!(m.text_body, Some(0));
        assert!(m.attachments.is_empty());
    }

    #[test]
    fn addresses_and_date() {
        let m = Message::parse(b"To: a@b.c\nTo: d@e.f, g@h.i\nDate: bad\n\n");
        assert_eq!(m.addresses("to").len(), 3);
        let d = m.date().unwrap();
        assert_eq!(d.raw, " bad");
        assert!(d.parsed.is_none());
    }
}
