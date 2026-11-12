#pragma once
/// \file matrix_market.hpp
/// Reading Matrix Market files (coordinate/array; real/integer/pattern;
/// general/symmetric/skew-symmetric) and writing `array real general`.

#include <iosfwd>
#include <stdexcept>
#include <string>
#include <string_view>

#include "linalg/matrix.hpp"

namespace linalg {

/// Thrown for malformed Matrix Market text.
class ParseError : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

/// Parses Matrix Market text into a dense matrix (symmetric storage is expanded).
Matrix parse_matrix_market(std::string_view text);

/// Reads and parses a Matrix Market file. Throws ParseError on failure.
Matrix read_matrix_market_file(const std::string& path);

/// Formats one value as `printf("%.10e")`, writing negative zero as positive zero.
std::string format_value(double v);

/// Serialises `m` as `array real general`: banner, size line, then one
/// `%.10e` value per line in column-major order, with a trailing newline.
std::string to_matrix_market(const Matrix& m);

/// Writes to_matrix_market(m) to `path`. Throws std::runtime_error on I/O failure.
void write_matrix_market_file(const std::string& path, const Matrix& m);

}  // namespace linalg
