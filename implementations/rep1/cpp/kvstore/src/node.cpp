#include "tessera/node.hpp"

#include <cstring>

namespace tessera {

std::size_t cell_size(PageType type, const Cell& c) {
  switch (type) {
    case PageType::PrimaryLeaf: return 12 + c.key.size() + c.inline_data.size();
    case PageType::Interior: return 6 + c.key.size();
    default: return 2 + c.key.size();
  }
}

std::size_t used(const Node& node) {
  std::size_t total = 0;
  for (const auto& c : node.cells) total += cell_cost(node.type, c);
  return total;
}

Page encode_node(const Node& node) {
  Page p{};
  std::size_t n = node.cells.size();
  std::size_t payload = 0;
  for (const auto& c : node.cells) payload += cell_size(node.type, c);
  std::size_t start = kPageSize - payload;

  p[0] = static_cast<std::uint8_t>(node.type);
  put16(&p[2], static_cast<std::uint16_t>(n));
  put16(&p[4], static_cast<std::uint16_t>(start));
  put32(&p[8], node.link);

  std::size_t at = start;
  for (std::size_t i = 0; i < n; ++i) {
    const Cell& c = node.cells[i];
    put16(&p[16 + 2 * i], static_cast<std::uint16_t>(at));
    std::uint8_t* d = &p[at];
    switch (node.type) {
      case PageType::PrimaryLeaf:
        put16(d, static_cast<std::uint16_t>(c.key.size()));
        put32(d + 2, c.doc_len);
        put16(d + 6, static_cast<std::uint16_t>(c.inline_data.size()));
        put32(d + 8, c.overflow);
        std::memcpy(d + 12, c.key.data(), c.key.size());
        std::memcpy(d + 12 + c.key.size(), c.inline_data.data(), c.inline_data.size());
        break;
      case PageType::Interior:
        put16(d, static_cast<std::uint16_t>(c.key.size()));
        put32(d + 2, c.child);
        std::memcpy(d + 6, c.key.data(), c.key.size());
        break;
      default:
        put16(d, static_cast<std::uint16_t>(c.key.size()));
        std::memcpy(d + 2, c.key.data(), c.key.size());
        break;
    }
    at += cell_size(node.type, c);
  }
  return p;
}

Node decode_node(const Page& p) {
  Node node;
  node.type = static_cast<PageType>(p[0]);
  std::size_t n = get16(&p[2]);
  node.link = get32(&p[8]);
  node.cells.resize(n);
  for (std::size_t i = 0; i < n; ++i) {
    const std::uint8_t* d = &p[get16(&p[16 + 2 * i])];
    Cell& c = node.cells[i];
    std::size_t key_len = get16(d);
    switch (node.type) {
      case PageType::PrimaryLeaf: {
        c.doc_len = get32(d + 2);
        std::size_t inline_len = get16(d + 6);
        c.overflow = get32(d + 8);
        c.key.assign(reinterpret_cast<const char*>(d + 12), key_len);
        c.inline_data.assign(reinterpret_cast<const char*>(d + 12 + key_len), inline_len);
        break;
      }
      case PageType::Interior:
        c.child = get32(d + 2);
        c.key.assign(reinterpret_cast<const char*>(d + 6), key_len);
        break;
      default:
        c.key.assign(reinterpret_cast<const char*>(d + 2), key_len);
        break;
    }
  }
  return node;
}

}  // namespace tessera
