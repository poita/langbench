#include "orderbook/text_writer.hpp"

#include <charconv>

namespace orderbook {

TextEventWriter::TextEventWriter(std::ostream& out, std::size_t buffer_bytes)
    : out_(out), limit_(buffer_bytes) {
  buf_.reserve(buffer_bytes + 256);
}

TextEventWriter::~TextEventWriter() { flush(); }

void TextEventWriter::flush() {
  if (!buf_.empty()) {
    out_.write(buf_.data(), static_cast<std::streamsize>(buf_.size()));
    buf_.clear();
  }
  out_.flush();
}

void TextEventWriter::append_int(std::uint64_t v) {
  char tmp[24];
  auto r = std::to_chars(tmp, tmp + sizeof tmp, v);
  buf_.append(tmp, r.ptr);
}

void TextEventWriter::end_line() {
  buf_.push_back('\n');
  if (buf_.size() >= limit_) {
    out_.write(buf_.data(), static_cast<std::streamsize>(buf_.size()));
    buf_.clear();
  }
}

void TextEventWriter::on_trade(std::string_view taker, std::string_view maker, Price price,
                               Qty qty) {
  append("TRADE ");
  append(taker);
  buf_.push_back(' ');
  append(maker);
  buf_.push_back(' ');
  append_int(static_cast<std::uint64_t>(price));
  buf_.push_back(' ');
  append_int(static_cast<std::uint64_t>(qty));
  end_line();
}

void TextEventWriter::on_filled(std::string_view id) {
  append("FILLED ");
  append(id);
  end_line();
}

void TextEventWriter::on_rest(std::string_view id) {
  append("REST ");
  append(id);
  end_line();
}

void TextEventWriter::on_cancel(std::string_view id, Qty remaining) {
  append("CANCEL ");
  append(id);
  buf_.push_back(' ');
  append_int(static_cast<std::uint64_t>(remaining));
  end_line();
}

void TextEventWriter::on_reject(std::string_view id) {
  append("REJECT ");
  append(id);
  end_line();
}

void TextEventWriter::on_level(Side side, Price price, Qty total_qty, std::size_t n_orders) {
  append(side == Side::Buy ? "BID " : "ASK ");
  append_int(static_cast<std::uint64_t>(price));
  buf_.push_back(' ');
  append_int(static_cast<std::uint64_t>(total_qty));
  buf_.push_back(' ');
  append_int(n_orders);
  end_line();
}

void TextEventWriter::on_book_end() {
  append("--");
  end_line();
}

}  // namespace orderbook
