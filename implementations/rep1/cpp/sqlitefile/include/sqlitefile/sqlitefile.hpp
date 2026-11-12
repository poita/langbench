#pragma once
/// \file sqlitefile.hpp
/// Umbrella header: includes the whole public API.
///
/// Layers, from the bottom up:
///  - value.hpp    values, ordering, affinity, formatting
///  - record.hpp   varints and records
///  - pager.hpp    the file in memory, header, pages
///  - btree.hpp    table/index B-tree walking and payload overflow
///  - ddl.hpp      CREATE TABLE / CREATE INDEX parsing
///  - schema.hpp   the catalog read from sqlite_schema
///  - query.hpp    the query language parser
///  - database.hpp the Database facade that ties it together

#include "sqlitefile/btree.hpp"
#include "sqlitefile/database.hpp"
#include "sqlitefile/ddl.hpp"
#include "sqlitefile/error.hpp"
#include "sqlitefile/pager.hpp"
#include "sqlitefile/query.hpp"
#include "sqlitefile/record.hpp"
#include "sqlitefile/schema.hpp"
#include "sqlitefile/value.hpp"
