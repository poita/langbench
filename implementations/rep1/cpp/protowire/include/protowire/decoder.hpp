// Wire bytes -> value tree.
#pragma once

#include <cstdint>
#include <span>

#include "protowire/value.hpp"

namespace protowire {

/// Decodes `bytes` as a message of type `descriptor` using proto3 semantics
/// (unknown fields skipped, repeated numerics accepted packed or unpacked,
/// repeated occurrences of a singular message merged). Throws WireError.
/// Runs in O(bytes) time.
Message decode(const MessageDescriptor& descriptor, std::span<const std::uint8_t> bytes);

}  // namespace protowire
