#include "tessera/overflow.hpp"

#include <algorithm>
#include <cstring>
#include <vector>

#include "tessera/limits.hpp"

namespace tessera {

std::uint32_t write_overflow_chain(Pager& pager, std::string_view data) {
  if (data.empty()) return 0;
  std::size_t chunks = (data.size() + kOverflowPayload - 1) / kOverflowPayload;
  std::vector<std::uint32_t> pages(chunks);
  for (auto& p : pages) p = pager.allocate();
  for (std::size_t i = 0; i < chunks; ++i) {
    std::size_t len = std::min(kOverflowPayload, data.size() - i * kOverflowPayload);
    Page page{};
    page[0] = static_cast<std::uint8_t>(PageType::Overflow);
    put32(&page[4], i + 1 < chunks ? pages[i + 1] : 0);
    put16(&page[8], static_cast<std::uint16_t>(len));
    std::memcpy(&page[12], data.data() + i * kOverflowPayload, len);
    pager.write(pages[i], page);
  }
  return pages[0];
}

std::string read_overflow_chain(const Pager& pager, std::uint32_t first) {
  std::string out;
  for (std::uint32_t p = first; p != 0;) {
    Page page = pager.read(p);
    out.append(reinterpret_cast<const char*>(&page[12]), get16(&page[8]));
    p = get32(&page[4]);
  }
  return out;
}

void free_overflow_chain(Pager& pager, std::uint32_t first) {
  for (std::uint32_t p = first; p != 0;) {
    std::uint32_t next = get32(&pager.read(p)[4]);
    pager.free_page(p);
    p = next;
  }
}

}  // namespace tessera
