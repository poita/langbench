//! A from-scratch MIME email parser.
//!
//! The crate reads a mailbox (an mbox file or a directory of `.eml` files),
//! parses each message as RFC 5322 / RFC 2045–2047 / RFC 2231 email, and can
//! write a normalised text dump of every message plus the decoded bytes of
//! every attachment. Nothing here depends on an email, MIME, date or
//! transfer-encoding library: every decoder is implemented in this crate.
//!
//! # Example
//!
//! ```
//! use mime::Message;
//!
//! let raw = b"From: Ann <ann@example.com>\r\n\
//!             Subject: =?utf-8?Q?Caf=C3=A9?=\r\n\
//!             Content-Type: text/plain; charset=utf-8\r\n\
//!             \r\n\
//!             hello\r\n";
//! let msg = Message::parse(raw);
//! assert_eq!(msg.addresses("from")[0].spec, "ann@example.com");
//! assert_eq!(msg.header("subject").unwrap().display_value(), "Café");
//! let body = msg.text_body.unwrap();
//! assert_eq!(msg.parts[body].text.as_deref(), Some("hello\n"));
//! ```
//!
//! # Modules
//!
//! * [`mailbox`] — mbox splitting and directory listing.
//! * [`message`] — the parsed [`Message`] with body/attachment selection.
//! * [`part`] — the MIME part tree.
//! * [`header`], [`rfc2047`], [`params`], [`address`], [`date`] — header parsing.
//! * [`charset`], [`transfer`], [`checksum`] — decoders.
//! * [`output`] — rendering of the dump format and writing the output tree.

pub mod address;
pub mod charset;
pub mod checksum;
pub mod date;
pub mod header;
pub mod lines;
pub mod mailbox;
pub mod message;
pub mod output;
pub mod params;
pub mod part;
pub mod rfc2047;
pub mod scan;
pub mod transfer;

pub use address::Address;
pub use mailbox::RawMessage;
pub use message::Message;
pub use part::{Kind, Part};

use std::io;
use std::path::Path;

/// Reads the mailbox at `input` and writes the dump tree into `output`.
///
/// `output` is created if it does not exist.
pub fn convert(input: &Path, output: &Path) -> io::Result<()> {
    let messages = mailbox::read_mailbox(input)?;
    output::write_output(&messages, output)
}
