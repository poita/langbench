//! Input commands and their text parser.

use crate::types::{InvalidId, OrderId, Price, Qty, Side};
use std::fmt;

/// How long the unfilled part of a limit order stays alive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TimeInForce {
    /// Good till cancelled: the remainder rests in the book.
    Gtc,
    /// Immediate-or-cancel: the remainder is discarded.
    Ioc,
    /// Fill-or-kill: either the whole quantity fills, or nothing happens.
    Fok,
}

/// A command for the order book.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Command {
    /// `LIMIT <id> <side> <price> <qty> [IOC|FOK]`
    Limit {
        /// Id of the new order (must not have been used before).
        id: OrderId,
        /// Buy or sell.
        side: Side,
        /// Limit price.
        price: Price,
        /// Quantity.
        qty: Qty,
        /// Time in force.
        tif: TimeInForce,
    },
    /// `MARKET <id> <side> <qty>`
    Market {
        /// Id of the new order.
        id: OrderId,
        /// Buy or sell.
        side: Side,
        /// Quantity.
        qty: Qty,
    },
    /// `CANCEL <id>`
    Cancel {
        /// Id of the order to cancel.
        id: OrderId,
    },
    /// `REPLACE <id> <price> <qty>`; `qty` is the new *remaining* quantity.
    Replace {
        /// Id of the resting order.
        id: OrderId,
        /// New limit price.
        price: Price,
        /// New remaining quantity.
        qty: Qty,
    },
    /// `BOOK`
    Book,
}

/// Why a line could not be parsed as a [`Command`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseError {
    /// The line was empty or its first token is not a known command.
    UnknownCommand,
    /// Wrong number of tokens for the command.
    WrongArity,
    /// The order id is invalid.
    BadId(InvalidId),
    /// The side is neither `BUY` nor `SELL`.
    BadSide,
    /// A price or quantity is not a valid unsigned decimal integer.
    BadNumber,
    /// The trailing flag is neither `IOC` nor `FOK`.
    BadFlag,
}

impl fmt::Display for ParseError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ParseError::UnknownCommand => f.write_str("unknown command"),
            ParseError::WrongArity => f.write_str("wrong number of fields"),
            ParseError::BadId(e) => write!(f, "bad id: {e}"),
            ParseError::BadSide => f.write_str("side must be BUY or SELL"),
            ParseError::BadNumber => f.write_str("invalid number"),
            ParseError::BadFlag => f.write_str("flag must be IOC or FOK"),
        }
    }
}

impl std::error::Error for ParseError {}

fn parse_side(tok: &str) -> Result<Side, ParseError> {
    match tok {
        "BUY" => Ok(Side::Buy),
        "SELL" => Ok(Side::Sell),
        _ => Err(ParseError::BadSide),
    }
}

fn parse_num(tok: &str) -> Result<u64, ParseError> {
    let b = tok.as_bytes();
    if b.is_empty() || b.len() > 19 || !b.iter().all(u8::is_ascii_digit) {
        return Err(ParseError::BadNumber);
    }
    Ok(b.iter().fold(0u64, |acc, &d| acc * 10 + u64::from(d - b'0')))
}

fn parse_id(tok: &str) -> Result<OrderId, ParseError> {
    OrderId::new(tok).map_err(ParseError::BadId)
}

impl Command {
    /// Parses one command line (without its line terminator).
    ///
    /// Tokens are separated by single spaces, as in the input format.
    ///
    /// ```
    /// use orderbook::Command;
    /// let cmd = Command::parse("LIMIT a BUY 100 5 IOC").unwrap();
    /// assert!(matches!(cmd, Command::Limit { .. }));
    /// ```
    pub fn parse(line: &str) -> Result<Command, ParseError> {
        let mut it = line.split(' ');
        let name = it.next().unwrap_or("");
        let mut next = || it.next().ok_or(ParseError::WrongArity);
        let cmd = match name {
            "LIMIT" => {
                let id = parse_id(next()?)?;
                let side = parse_side(next()?)?;
                let price = parse_num(next()?)?;
                let qty = parse_num(next()?)?;
                let tif = match it.next() {
                    None => TimeInForce::Gtc,
                    Some("IOC") => TimeInForce::Ioc,
                    Some("FOK") => TimeInForce::Fok,
                    Some(_) => return Err(ParseError::BadFlag),
                };
                Command::Limit { id, side, price, qty, tif }
            }
            "MARKET" => {
                let id = parse_id(next()?)?;
                let side = parse_side(next()?)?;
                let qty = parse_num(next()?)?;
                Command::Market { id, side, qty }
            }
            "CANCEL" => Command::Cancel { id: parse_id(next()?)? },
            "REPLACE" => {
                let id = parse_id(next()?)?;
                let price = parse_num(next()?)?;
                let qty = parse_num(next()?)?;
                Command::Replace { id, price, qty }
            }
            "BOOK" => Command::Book,
            _ => return Err(ParseError::UnknownCommand),
        };
        if it.next().is_some() {
            return Err(ParseError::WrongArity);
        }
        Ok(cmd)
    }
}

impl std::str::FromStr for Command {
    type Err = ParseError;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Command::parse(s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(s: &str) -> OrderId {
        OrderId::new(s).unwrap()
    }

    #[test]
    fn parses_all_commands() {
        assert_eq!(
            Command::parse("LIMIT a BUY 100 5"),
            Ok(Command::Limit { id: id("a"), side: Side::Buy, price: 100, qty: 5, tif: TimeInForce::Gtc })
        );
        assert_eq!(
            Command::parse("LIMIT a SELL 100 5 FOK"),
            Ok(Command::Limit { id: id("a"), side: Side::Sell, price: 100, qty: 5, tif: TimeInForce::Fok })
        );
        assert_eq!(
            Command::parse("MARKET m SELL 7"),
            Ok(Command::Market { id: id("m"), side: Side::Sell, qty: 7 })
        );
        assert_eq!(Command::parse("CANCEL x"), Ok(Command::Cancel { id: id("x") }));
        assert_eq!(
            Command::parse("REPLACE x 5 6"),
            Ok(Command::Replace { id: id("x"), price: 5, qty: 6 })
        );
        assert_eq!(Command::parse("BOOK"), Ok(Command::Book));
    }

    #[test]
    fn keyword_ids_are_positional() {
        assert_eq!(
            Command::parse("LIMIT BUY SELL 1 1 IOC"),
            Ok(Command::Limit { id: id("BUY"), side: Side::Sell, price: 1, qty: 1, tif: TimeInForce::Ioc })
        );
        assert_eq!(Command::parse("CANCEL BOOK"), Ok(Command::Cancel { id: id("BOOK") }));
    }

    #[test]
    fn rejects_bad_lines() {
        assert_eq!(Command::parse(""), Err(ParseError::UnknownCommand));
        assert_eq!(Command::parse("FOO"), Err(ParseError::UnknownCommand));
        assert_eq!(Command::parse("CANCEL"), Err(ParseError::WrongArity));
        assert_eq!(Command::parse("BOOK x"), Err(ParseError::WrongArity));
        assert_eq!(Command::parse("LIMIT a HOLD 1 1"), Err(ParseError::BadSide));
        assert_eq!(Command::parse("LIMIT a BUY -1 1"), Err(ParseError::BadNumber));
        assert_eq!(Command::parse("LIMIT a BUY 1 1 GTC"), Err(ParseError::BadFlag));
    }
}
