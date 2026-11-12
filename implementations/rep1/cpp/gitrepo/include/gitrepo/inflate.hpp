// zlib (RFC 1950) / DEFLATE (RFC 1951) decompression, implemented from scratch.
#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <string_view>

namespace gitrepo {

/// Adler-32 checksum (RFC 1950) of `data`.
std::uint32_t adler32(std::string_view data);

/// Decompresses one zlib stream found at the start of `input`, appending the
/// plaintext to `out`.
///
/// The stream's end is found by decoding it, so `input` may contain further
/// data after it (as in a packfile). Returns the number of input bytes the
/// stream occupied, including the 4-byte Adler-32 trailer.
///
/// Throws gitrepo::Error if the header is invalid, the DEFLATE data is
/// malformed or truncated, the Adler-32 does not match, or the plaintext
/// would exceed `max_output` bytes.
std::size_t zlib_inflate(
    std::string_view input, std::string& out,
    std::size_t max_output = std::numeric_limits<std::size_t>::max());

}  // namespace gitrepo
