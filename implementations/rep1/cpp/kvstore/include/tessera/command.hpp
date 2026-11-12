#pragma once
/// \file command.hpp
/// The parsed form of one command line.

#include <cstdint>
#include <memory>
#include <optional>
#include <string>

#include "tessera/query.hpp"
#include "tessera/scan_options.hpp"
#include "tessera/value.hpp"

namespace tessera {

struct Command {
  enum class Type {
    Begin, Commit, Rollback, Checkpoint, Stat, Indexes,
    Put, Get, Delete, Update, Unset, Scan, Find, CreateIndex, DropIndex,
  };
  Type type = Type::Begin;
  std::string key;                       ///< put, get, delete, update, unset
  Value value;                           ///< put, update
  Path path;                             ///< update, unset, create/drop index
  ScanOptions scan;                      ///< scan
  std::unique_ptr<Predicate> predicate;  ///< find
  std::optional<std::int64_t> limit;     ///< find
};

/// Parses a command line (spec 6, error order of 18.2). Throws `Error`.
Command parse_command(std::string_view line);

/// Parses a single value literal (spec 6.3), e.g. `{name:"ada",age:36}`.
Value parse_value_literal(std::string_view text);

}  // namespace tessera
