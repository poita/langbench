//! # protowire
//!
//! A schema-driven codec for the Protocol Buffers wire format (proto3
//! semantics) with a canonical, human-readable text form.
//!
//! The crate is organised by responsibility:
//!
//! | module | role |
//! |---|---|
//! | [`schema`] | parse the schema language into message descriptors |
//! | [`wire`] | varints, zigzag, tags and a bounds-checked [`wire::Reader`] |
//! | [`value`] | the value tree ([`Message`]) shared by all directions |
//! | `decode` | bytes → value tree (methods on [`Schema`]) |
//! | `render` | value tree → canonical text (methods on [`Schema`]) |
//! | `parse` | text → value tree (methods on [`Schema`]) |
//! | `encode` | value tree → canonical bytes (methods on [`Schema`]) |
//! | [`hex`] | lowercase hex conversion |
//! | [`session`] | the batch request protocol used by the CLI |
//!
//! Decoding is linear in the payload and encoding is linear in the output
//! regardless of nesting depth: decoding reads each byte once and skips
//! unknown fields and groups without building anything, and encoding
//! measures every sub-message once before writing the whole message into a
//! single buffer.
//!
//! # Example
//!
//! ```
//! use protowire::Schema;
//!
//! let schema = Schema::parse(
//!     "message Inner { sint32 v = 1; }
//!      message Outer { int32 a = 1; string b = 2; repeated int32 c = 3; Inner d = 4; }",
//! )
//! .unwrap();
//!
//! let bytes = schema
//!     .encode_from_text("Outer", r#"{d: {v: -5}, a: 1, b: "x", c: [1, 2]}"#)
//!     .unwrap();
//! assert_eq!(protowire::hex::encode(&bytes), "08011201781a02010222020809");
//!
//! let text = schema.decode_to_text("Outer", &bytes).unwrap();
//! assert_eq!(text, r#"{a: 1, b: "x", c: [1, 2], d: {v: -5}}"#);
//! ```

mod decode;
mod encode;
pub mod error;
pub mod hex;
mod parse;
mod render;
pub mod schema;
pub mod session;
pub mod value;
pub mod wire;

pub use error::{Error, Result};
pub use schema::{FieldDesc, FieldKind, MessageDesc, MessageId, ScalarType, Schema};
pub use value::{FieldValue, Message, Value};
