//! Basic value types shared by the whole crate: prices, quantities, sides and
//! order identifiers.

use std::fmt;
use std::hash::{Hash, Hasher};

/// A limit price. The specification restricts prices to `1..=1_000_000_000`,
/// but the engine itself accepts any `u64`.
pub type Price = u64;

/// A quantity. Level totals and FOK availability sums can exceed 32 bits, so
/// every quantity is 64-bit.
pub type Qty = u64;

/// Which side of the book an order is on.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Side {
    /// A buyer; rests as a *bid*.
    Buy,
    /// A seller; rests as an *ask*.
    Sell,
}

impl Side {
    /// The opposite side of the book.
    #[inline]
    pub fn opposite(self) -> Side {
        match self {
            Side::Buy => Side::Sell,
            Side::Sell => Side::Buy,
        }
    }

    /// Whether a taker on `self` with limit `limit` crosses a resting order
    /// of the opposite side at price `resting`.
    #[inline]
    pub fn crosses(self, limit: Price, resting: Price) -> bool {
        match self {
            Side::Buy => resting <= limit,
            Side::Sell => resting >= limit,
        }
    }
}

impl fmt::Display for Side {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Side::Buy => "BUY",
            Side::Sell => "SELL",
        })
    }
}

/// Maximum length, in bytes, of an [`OrderId`].
pub const MAX_ID_LEN: usize = 32;

/// An opaque order identifier: 1 to 32 printable ASCII characters (`!`..=`~`).
///
/// Identifiers are compared byte for byte. The type is `Copy` and stored
/// inline, so handling ids never allocates.
#[derive(Clone, Copy)]
pub struct OrderId {
    len: u8,
    // Bytes past `len` are always zero, so derived-style comparison is exact.
    bytes: [u8; MAX_ID_LEN],
}

/// Error returned when a string is not a valid [`OrderId`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct InvalidId;

impl fmt::Display for InvalidId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "order id must be 1 to {MAX_ID_LEN} printable ASCII characters without spaces"
        )
    }
}

impl std::error::Error for InvalidId {}

impl OrderId {
    /// Builds an id from raw bytes, validating length and character range.
    pub fn from_bytes(s: &[u8]) -> Result<OrderId, InvalidId> {
        if s.is_empty() || s.len() > MAX_ID_LEN || !s.iter().all(|&b| (b'!'..=b'~').contains(&b)) {
            return Err(InvalidId);
        }
        let mut bytes = [0u8; MAX_ID_LEN];
        bytes[..s.len()].copy_from_slice(s);
        Ok(OrderId { len: s.len() as u8, bytes })
    }

    /// Builds an id from a string slice. See [`OrderId::from_bytes`].
    pub fn new(s: &str) -> Result<OrderId, InvalidId> {
        OrderId::from_bytes(s.as_bytes())
    }

    /// The id's bytes.
    #[inline]
    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }

    /// The id as a string slice (ids are always ASCII).
    pub fn as_str(&self) -> &str {
        // Validated as ASCII on construction.
        std::str::from_utf8(self.as_bytes()).expect("OrderId is ASCII")
    }
}

impl PartialEq for OrderId {
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.bytes == other.bytes
    }
}
impl Eq for OrderId {}

impl Hash for OrderId {
    #[inline]
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.as_bytes().hash(state)
    }
}

impl fmt::Display for OrderId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl fmt::Debug for OrderId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "OrderId({:?})", self.as_str())
    }
}

impl std::str::FromStr for OrderId {
    type Err = InvalidId;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        OrderId::new(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn id_validation() {
        assert!(OrderId::new("a").is_ok());
        assert!(OrderId::new(&"x".repeat(32)).is_ok());
        assert_eq!(OrderId::new(""), Err(InvalidId));
        assert_eq!(OrderId::new(&"x".repeat(33)), Err(InvalidId));
        assert_eq!(OrderId::new("a b"), Err(InvalidId));
        assert_eq!(OrderId::new("é"), Err(InvalidId));
    }

    #[test]
    fn id_equality_and_display() {
        let a = OrderId::new("BUY").unwrap();
        assert_eq!(a, OrderId::new("BUY").unwrap());
        assert_ne!(a, OrderId::new("BUY!").unwrap());
        assert_ne!(OrderId::new("a").unwrap(), OrderId::new("a\u{21}").unwrap());
        assert_eq!(a.to_string(), "BUY");
        assert_eq!(a.as_bytes(), b"BUY");
    }

    #[test]
    fn crossing() {
        assert!(Side::Buy.crosses(10, 10));
        assert!(Side::Buy.crosses(10, 9));
        assert!(!Side::Buy.crosses(10, 11));
        assert!(Side::Sell.crosses(10, 10));
        assert!(Side::Sell.crosses(10, 11));
        assert!(!Side::Sell.crosses(10, 9));
        assert_eq!(Side::Buy.opposite(), Side::Sell);
    }
}
