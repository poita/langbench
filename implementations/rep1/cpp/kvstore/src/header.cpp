#include "tessera/header.hpp"

#include <cstring>

namespace tessera {

std::uint32_t Header::index_count() const {
  std::uint32_t n = 0;
  for (const auto& s : slots) n += s.live ? 1 : 0;
  return n;
}

Page Header::encode() const {
  Page p{};
  std::memcpy(p.data(), "TESSERA1", 8);
  put16(&p[8], 1);
  put16(&p[10], kPageSize);
  put32(&p[12], page_count);
  put32(&p[16], freelist_head);
  put32(&p[20], freelist_count);
  put32(&p[24], primary_root);
  put32(&p[28], primary_count);
  put64(&p[32], commit_counter);
  put32(&p[40], index_count());
  for (std::size_t i = 0; i < kMaxIndexes; ++i) {
    const IndexSlot& s = slots[i];
    if (!s.live) continue;
    std::uint8_t* d = &p[128 + 48 * i];
    d[0] = 1;
    d[1] = static_cast<std::uint8_t>(s.path.size());
    std::memcpy(d + 2, s.path.data(), s.path.size());
    put32(d + 32, s.root);
    put32(d + 36, s.entries);
  }
  return p;
}

Header Header::decode(const Page& p) {
  Header h;
  h.page_count = get32(&p[12]);
  h.freelist_head = get32(&p[16]);
  h.freelist_count = get32(&p[20]);
  h.primary_root = get32(&p[24]);
  h.primary_count = get32(&p[28]);
  h.commit_counter = get64(&p[32]);
  for (std::size_t i = 0; i < kMaxIndexes; ++i) {
    const std::uint8_t* d = &p[128 + 48 * i];
    if (d[0] != 1) continue;
    IndexSlot& s = h.slots[i];
    s.live = true;
    s.path.assign(reinterpret_cast<const char*>(d + 2), d[1]);
    s.root = get32(d + 32);
    s.entries = get32(d + 36);
  }
  return h;
}

}  // namespace tessera
