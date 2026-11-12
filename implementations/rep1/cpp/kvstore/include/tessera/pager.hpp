#pragma once
/// \file pager.hpp
/// Page access: the main file, the committed-log overlay and the open
/// transaction's dirty pages; page allocation and the free list.

#include <cstdint>
#include <map>
#include <utility>
#include <vector>

#include "tessera/header.hpp"
#include "tessera/page.hpp"

namespace tessera {

class Pager {
 public:
  /// `main_file` is the bytes of `main.tdb`; empty means a fresh database.
  explicit Pager(std::vector<std::uint8_t> main_file);

  /// Installs recovered page images (later images of a page win) and reloads
  /// the header through the overlay.
  void apply_recovered(const std::vector<std::pair<std::uint32_t, Page>>& images);

  /// Reads a page: dirty set, then overlay, then main file, else zeros.
  Page read(std::uint32_t page_no) const;
  /// Writes a page into the open transaction's dirty set.
  void write(std::uint32_t page_no, const Page& page);

  /// Pops the free list or extends the file by one page. The caller must write
  /// the returned page.
  std::uint32_t allocate();
  /// Pushes `page_no` onto the free list (writing it as a free page).
  void free_page(std::uint32_t page_no);

  /// The engine's header fields (the contents of page 1). References into it
  /// stay valid for the pager's lifetime.
  Header& header() { return header_; }
  const Header& header() const { return header_; }

  /// Encodes the header into the dirty set as page 1.
  void stage_header();
  const std::map<std::uint32_t, Page>& dirty() const { return dirty_; }
  /// Moves the dirty set into the overlay.
  void commit_dirty();
  /// Drops the dirty set and restores the header from the committed state.
  void discard_dirty();

  /// Copies the overlay into the main file (spec 15.6); returns the number of
  /// pages copied.
  std::size_t checkpoint();

  const std::vector<std::uint8_t>& main_file() const { return main_; }

 private:
  Page committed_page(std::uint32_t page_no) const;

  std::vector<std::uint8_t> main_;
  std::map<std::uint32_t, Page> overlay_;
  std::map<std::uint32_t, Page> dirty_;
  Header header_;
};

}  // namespace tessera
