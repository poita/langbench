#include "tessera/executor.hpp"

#include "tessera/error.hpp"

namespace tessera {

Outcome execute(Database& db, const Command& c) {
  using T = Command::Type;
  Outcome o;
  switch (c.type) {
    case T::Begin:
      db.begin();
      o.status = "ok begin";
      break;
    case T::Commit: {
      CommitInfo info = db.commit();
      o.status = "ok commit " + std::to_string(info.txn_id) + " frames " + std::to_string(info.frames);
      break;
    }
    case T::Rollback:
      db.rollback();
      o.status = "ok rollback";
      break;
    case T::Checkpoint:
      o.status = "ok checkpoint pages " + std::to_string(db.checkpoint());
      break;
    case T::Stat:
      o.status = "ok stat";
      o.payload = render_stats(db.stats());
      break;
    case T::Indexes: {
      auto list = db.indexes();
      o.status = "ok indexes " + std::to_string(list.size());
      o.payload = render_indexes(list);
      break;
    }
    case T::Put:
      o.status = db.put(c.key, c.value) ? "ok put created" : "ok put replaced";
      break;
    case T::Get: {
      auto doc = db.get(c.key);
      if (!doc) throw Error(ErrorKind::NotFound);
      o.status = "ok get value";
      o.payload.push_back(render(*doc));
      break;
    }
    case T::Delete:
      db.erase(c.key);
      o.status = "ok delete removed";
      break;
    case T::Update:
      db.update(c.key, c.path, c.value);
      o.status = "ok update updated";
      break;
    case T::Unset:
      db.unset(c.key, c.path);
      o.status = "ok unset updated";
      break;
    case T::Scan: {
      auto entries = db.scan(c.scan);
      o.status = "ok scan " + std::to_string(entries.size());
      o.payload = render_entries(entries);
      break;
    }
    case T::Find: {
      FindResult r = db.find(*c.predicate, c.limit);
      o.status = "ok find " + std::to_string(r.entries.size()) + " plan " + r.plan.describe();
      o.payload = render_entries(r.entries);
      break;
    }
    case T::CreateIndex: {
      std::uint32_t n = db.create_index(c.path);
      o.status = "ok create index " + path_text(c.path) + " entries " + std::to_string(n);
      break;
    }
    case T::DropIndex: {
      std::size_t n = db.drop_index(c.path);
      o.status = "ok drop index " + path_text(c.path) + " pages " + std::to_string(n);
      break;
    }
  }
  return o;
}

Outcome run_line(Database& db, std::string_view line) {
  try {
    return execute(db, parse_command(line));
  } catch (const Error& e) {
    return Outcome{std::string("error ") + error_name(e.kind()), {}};
  }
}

std::vector<std::string_view> split_lines(std::string_view script) {
  std::vector<std::string_view> lines;
  std::size_t start = 0;
  while (start < script.size()) {
    std::size_t nl = script.find('\n', start);
    if (nl == std::string_view::npos) {
      lines.push_back(script.substr(start));
      break;
    }
    lines.push_back(script.substr(start, nl - start));
    start = nl + 1;
  }
  return lines;
}

std::string run_script(Database& db, std::string_view script) {
  std::string results;
  std::size_t n = 0;
  for (std::string_view line : split_lines(script))
    results += format_block(++n, run_line(db, line));
  if (db.in_transaction()) db.rollback();
  return results;
}

}  // namespace tessera
