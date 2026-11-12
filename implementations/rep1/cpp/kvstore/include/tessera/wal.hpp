#pragma once
/// \file wal.hpp
/// The write-ahead log: record encoding, append, and recovery scan (spec 15, 16).

#include <cstdint>
#include <map>
#include <span>
#include <utility>
#include <vector>

#include "tessera/page.hpp"

namespace tessera {

struct WalRecovery;

class Wal {
 public:
  /// An empty log: just the 32-byte header.
  Wal();

  /// Scans `bytes` (spec 16.2-16.4). A damaged or empty header discards everything.
  static WalRecovery recover(std::span<const std::uint8_t> bytes);

  /// Appends one committed transaction: its page images in ascending page order
  /// followed by a commit record.
  void append_commit(std::uint64_t txn_id, const std::map<std::uint32_t, Page>& pages);
  /// Resets the log to its 32-byte header.
  void reset();

  std::size_t size() const { return bytes_.size(); }
  const std::vector<std::uint8_t>& bytes() const { return bytes_; }

  static constexpr std::size_t kHeaderSize = 32;
  static constexpr std::size_t kRecordHeaderSize = 24;

 private:
  std::vector<std::uint8_t> bytes_;
};

/// The result of scanning an existing log.
struct WalRecovery {
  Wal wal;  ///< the log trimmed to the end of its last committed transaction
  /// Page images of the committed transactions, in file order.
  std::vector<std::pair<std::uint32_t, Page>> images;
};

}  // namespace tessera
