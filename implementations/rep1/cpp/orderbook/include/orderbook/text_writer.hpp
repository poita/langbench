#pragma once
/// @file text_writer.hpp
/// An EventSink that renders events in the line-oriented text format.

#include <ostream>
#include <string>

#include "orderbook/event.hpp"

namespace orderbook {

/// Formats each event as one line (`TRADE a b 100 5`, `REST x`, `BID ...`,
/// `--`, ...) and writes it to an ostream. Output is buffered internally;
/// call flush() (or let the destructor run) to push the tail out.
class TextEventWriter final : public EventSink {
 public:
  explicit TextEventWriter(std::ostream& out, std::size_t buffer_bytes = 1 << 16);
  ~TextEventWriter() override;
  TextEventWriter(const TextEventWriter&) = delete;
  TextEventWriter& operator=(const TextEventWriter&) = delete;

  void flush();

  void on_trade(std::string_view taker, std::string_view maker, Price price, Qty qty) override;
  void on_filled(std::string_view id) override;
  void on_rest(std::string_view id) override;
  void on_cancel(std::string_view id, Qty remaining) override;
  void on_reject(std::string_view id) override;
  void on_level(Side side, Price price, Qty total_qty, std::size_t n_orders) override;
  void on_book_end() override;

 private:
  void append(std::string_view s) { buf_.append(s); }
  void append_int(std::uint64_t v);
  void end_line();

  std::ostream& out_;
  std::string buf_;
  std::size_t limit_;
};

}  // namespace orderbook
