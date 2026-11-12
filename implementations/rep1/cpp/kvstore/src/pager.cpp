#include "tessera/pager.hpp"

#include <algorithm>
#include <cstring>

namespace tessera {

Pager::Pager(std::vector<std::uint8_t> main_file) : main_(std::move(main_file)) {
  if (main_.empty()) {
    Header fresh;
    Page p = fresh.encode();
    main_.assign(p.begin(), p.end());
  }
  header_ = Header::decode(committed_page(1));
}

void Pager::apply_recovered(const std::vector<std::pair<std::uint32_t, Page>>& images) {
  for (const auto& [no, img] : images) overlay_[no] = img;
  header_ = Header::decode(committed_page(1));
}

Page Pager::committed_page(std::uint32_t page_no) const {
  auto o = overlay_.find(page_no);
  if (o != overlay_.end()) return o->second;
  Page p{};
  std::size_t off = (static_cast<std::size_t>(page_no) - 1) * kPageSize;
  if (page_no >= 1 && off + kPageSize <= main_.size())
    std::memcpy(p.data(), main_.data() + off, kPageSize);
  return p;
}

Page Pager::read(std::uint32_t page_no) const {
  auto d = dirty_.find(page_no);
  if (d != dirty_.end()) return d->second;
  return committed_page(page_no);
}

void Pager::write(std::uint32_t page_no, const Page& page) { dirty_[page_no] = page; }

std::uint32_t Pager::allocate() {
  if (header_.freelist_head != 0) {
    std::uint32_t p = header_.freelist_head;
    Page page = read(p);
    header_.freelist_head = get32(&page[4]);
    --header_.freelist_count;
    return p;
  }
  return ++header_.page_count;
}

void Pager::free_page(std::uint32_t page_no) {
  Page p{};
  put32(&p[4], header_.freelist_head);
  write(page_no, p);
  header_.freelist_head = page_no;
  ++header_.freelist_count;
}

void Pager::stage_header() { write(1, header_.encode()); }

void Pager::commit_dirty() {
  for (auto& [no, img] : dirty_) overlay_[no] = img;
  dirty_.clear();
}

void Pager::discard_dirty() {
  dirty_.clear();
  header_ = Header::decode(committed_page(1));
}

std::size_t Pager::checkpoint() {
  std::uint32_t page_count = get32(&committed_page(1)[12]);
  main_.resize(static_cast<std::size_t>(page_count) * kPageSize, 0);
  for (const auto& [no, img] : overlay_) {
    if (no < 1 || no > page_count) continue;
    std::memcpy(main_.data() + (static_cast<std::size_t>(no) - 1) * kPageSize, img.data(),
                kPageSize);
  }
  std::size_t n = overlay_.size();
  overlay_.clear();
  return n;
}

}  // namespace tessera
