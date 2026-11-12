#pragma once
/// @file command.hpp
/// Parsed form of one input line, and the line parser.

#include <optional>
#include <string_view>

#include "orderbook/types.hpp"

namespace orderbook {

enum class CommandType : std::uint8_t { Limit, Market, Cancel, Replace, Book };

/// One command. Fields not used by `type` keep their defaults.
/// `id` is a view into the text that was parsed; it must outlive the Command.
struct Command {
  CommandType type = CommandType::Book;
  std::string_view id;
  Side side = Side::Buy;
  Price price = 0;
  Qty qty = 0;
  TimeInForce tif = TimeInForce::GoodTillCancel;

  friend bool operator==(const Command&, const Command&) = default;
};

/// Parse one command line (no line terminator; a trailing '\r' is tolerated).
///
///     LIMIT <id> <BUY|SELL> <price> <qty> [IOC|FOK]
///     MARKET <id> <BUY|SELL> <qty>
///     CANCEL <id>
///     REPLACE <id> <price> <qty>
///     BOOK
///
/// Tokens are separated by single spaces and identified by position, so an id
/// may equal a keyword. Returns std::nullopt if the line is malformed
/// (unknown command, wrong token count, bad number, id longer than
/// kMaxIdLength, ...).
std::optional<Command> parse_command(std::string_view line) noexcept;

}  // namespace orderbook
