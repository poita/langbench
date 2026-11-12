#pragma once
/// \file inflate.hpp
/// Public API: decode a raw DEFLATE (RFC 1951) stream.
///
/// ```cpp
/// std::vector<std::uint8_t> compressed = ...;
/// inflate::Result r = inflate::inflate(compressed);
/// if (r) use(r.data); else std::cerr << inflate::to_string(r.error);
/// ```
///
/// The decoder is strict: it rejects every malformation listed in SPEC.md,
/// including whole bytes left over after the final block.

#include <cstddef>
#include <cstdint>
#include <limits>
#include <vector>

#include "inflate/error.hpp"

namespace inflate {

/// Decoder options.
struct Options {
  /// Fail with Error::OutputLimitExceeded rather than produce more than this
  /// many bytes (a guard against decompression bombs). Default: unlimited.
  std::size_t max_output = std::numeric_limits<std::size_t>::max();
};

/// Outcome of a decode: the output on success, or the reason for failure.
struct Result {
  Error error = Error::None;
  std::vector<std::uint8_t> data;  ///< Empty when `error != Error::None`.

  bool ok() const noexcept { return error == Error::None; }
  explicit operator bool() const noexcept { return ok(); }
};

/// Decode a raw DEFLATE stream (no zlib/gzip wrapper).
///
/// On return `out` holds the decompressed bytes (it is cleared first). If an
/// error is returned, `out` holds whatever was produced before the error was
/// detected and must not be treated as a valid result.
Error inflate(const std::uint8_t* data, std::size_t size, std::vector<std::uint8_t>& out,
              const Options& options = {});

/// Convenience overload returning a Result; `data` is empty on failure.
Result inflate(const std::uint8_t* data, std::size_t size, const Options& options = {});
Result inflate(const std::vector<std::uint8_t>& stream, const Options& options = {});

}  // namespace inflate
