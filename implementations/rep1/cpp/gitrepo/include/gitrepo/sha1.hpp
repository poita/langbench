// SHA-1 (FIPS 180-4), implemented from scratch.
#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string_view>

#include "gitrepo/object_id.hpp"

namespace gitrepo {

/// Incremental SHA-1 hasher.
///
///     Sha1 h;
///     h.update("blob 9\0", 7);
///     h.update("one file\n");
///     ObjectId id = h.finish();
class Sha1 {
 public:
  Sha1();

  void update(const void* data, std::size_t size);
  void update(std::string_view data) { update(data.data(), data.size()); }

  /// Finalises the hash. The hasher must not be used afterwards.
  ObjectId finish();

 private:
  void process_block(const std::uint8_t* block);

  std::array<std::uint32_t, 5> state_;
  std::array<std::uint8_t, 64> buffer_;
  std::size_t buffered_ = 0;
  std::uint64_t total_ = 0;
};

/// One-shot convenience wrapper.
ObjectId sha1(std::string_view data);

}  // namespace gitrepo
