/// @file corpus.hpp
/// Loading a corpus from the on-disk layout `<input>/docs/<id>.txt`.
#pragma once

#include <filesystem>
#include <string>
#include <vector>

#include "fulltext/index.hpp"

namespace fulltext {

/// Reads a whole file as bytes. Throws `std::runtime_error` on failure.
std::string read_file(const std::filesystem::path& path);

/// Loads every regular `*.txt` file directly inside `<input_dir>/docs`; the
/// document id is the file name without `.txt`. A missing `docs/` directory
/// gives an empty corpus. The result is ordered by id.
std::vector<Document> load_documents(const std::filesystem::path& input_dir);

}  // namespace fulltext
