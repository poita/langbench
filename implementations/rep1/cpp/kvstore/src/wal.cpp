#include "tessera/wal.hpp"

#include <algorithm>
#include <cstring>

#include "tessera/crc32.hpp"

namespace tessera {
namespace {

std::vector<std::uint8_t> make_header() {
  std::vector<std::uint8_t> h(Wal::kHeaderSize, 0);
  std::memcpy(h.data(), "TESSWAL1", 8);
  put16(&h[8], 1);
  put16(&h[10], kPageSize);
  put32(&h[28], crc32(h.data(), 28));
  return h;
}

bool header_valid(std::span<const std::uint8_t> b) {
  if (b.size() < Wal::kHeaderSize) return false;
  if (std::memcmp(b.data(), "TESSWAL1", 8) != 0) return false;
  if (get16(&b[8]) != 1 || get16(&b[10]) != kPageSize) return false;
  for (std::size_t i = 12; i < 28; ++i)
    if (b[i] != 0) return false;
  return get32(&b[28]) == crc32(b.data(), 28);
}

void append_record(std::vector<std::uint8_t>& out, std::uint8_t type, std::uint64_t txn_id,
                   std::uint32_t field, const std::uint8_t* payload, std::uint32_t payload_len) {
  std::size_t at = out.size();
  out.resize(at + Wal::kRecordHeaderSize, 0);
  std::uint8_t* h = &out[at];
  h[0] = type;
  put64(h + 4, txn_id);
  put32(h + 12, field);
  put32(h + 16, payload_len);
  std::uint32_t c = crc32_update(crc32_init(), h, 20);
  if (payload_len) c = crc32_update(c, payload, payload_len);
  put32(h + 20, crc32_final(c));
  if (payload_len) out.insert(out.end(), payload, payload + payload_len);
}

}  // namespace

Wal::Wal() : bytes_(make_header()) {}

void Wal::reset() { bytes_ = make_header(); }

void Wal::append_commit(std::uint64_t txn_id, const std::map<std::uint32_t, Page>& pages) {
  for (const auto& [no, img] : pages)
    append_record(bytes_, 1, txn_id, no, img.data(), static_cast<std::uint32_t>(kPageSize));
  append_record(bytes_, 2, txn_id, static_cast<std::uint32_t>(pages.size()), nullptr, 0);
}

WalRecovery Wal::recover(std::span<const std::uint8_t> bytes) {
  WalRecovery result;
  if (!header_valid(bytes)) return result;

  std::size_t off = kHeaderSize;
  std::size_t valid_end = kHeaderSize;
  bool open = false;
  std::uint64_t open_txn = 0;
  std::vector<std::pair<std::uint32_t, Page>> group;

  while (true) {
    std::size_t rem = bytes.size() - off;
    if (rem < kRecordHeaderSize) break;
    const std::uint8_t* h = &bytes[off];
    std::uint8_t type = h[0];
    if (type != 1 && type != 2) break;
    if (h[1] || h[2] || h[3]) break;
    std::uint64_t txn = get64(h + 4);
    std::uint32_t field = get32(h + 12);
    std::uint32_t payload_len = get32(h + 16);
    if (payload_len != (type == 1 ? kPageSize : 0)) break;
    if (field < 1) break;
    if (rem < kRecordHeaderSize + payload_len) break;
    std::uint32_t c = crc32_update(crc32_init(), h, 20);
    if (payload_len) c = crc32_update(c, h + kRecordHeaderSize, payload_len);
    if (crc32_final(c) != get32(h + 20)) break;

    if (type == 1) {
      if (open && open_txn != txn) break;
      if (!open) {
        open = true;
        open_txn = txn;
        group.clear();
      }
      Page img;
      std::memcpy(img.data(), h + kRecordHeaderSize, kPageSize);
      group.emplace_back(field, img);
      off += kRecordHeaderSize + kPageSize;
    } else {
      if (!open || open_txn != txn || group.size() != field) break;
      for (auto& g : group) result.images.push_back(std::move(g));
      group.clear();
      open = false;
      off += kRecordHeaderSize;
      valid_end = off;
    }
  }
  result.wal.bytes_.assign(bytes.begin(), bytes.begin() + static_cast<std::ptrdiff_t>(valid_end));
  return result;
}

}  // namespace tessera
