#include "gitrepo/commands.hpp"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <limits>
#include <queue>
#include <unordered_set>
#include <vector>

#include "gitrepo/error.hpp"
#include "gitrepo/quote.hpp"
#include "gitrepo/revision.hpp"
#include "gitrepo/sha1.hpp"

namespace gitrepo {

namespace {

using Args = std::vector<std::string_view>;

std::string octal6(std::uint32_t mode) {
  char buf[16];
  std::snprintf(buf, sizeof buf, "%06o", static_cast<unsigned>(mode));
  return buf;
}

void require_args(const Args& args, std::size_t min, std::size_t max) {
  if (args.size() < min || args.size() > max) throw Error("wrong number of arguments");
}

// ---------------------------------------------------------------- rev-parse

std::string cmd_rev_parse(Repository& repo, const Args& args) {
  require_args(args, 1, 1);
  return resolve_revision(repo, args[0]).hex() + "\n";
}

// ---------------------------------------------------------------- cat-file

std::string cmd_cat_file(Repository& repo, const Args& args) {
  require_args(args, 1, 1);
  ObjectId id = resolve_revision(repo, args[0]);
  ObjectPtr obj = repo.objects().read(id);
  if (hash_object(obj->type, obj->data) != id) throw Error("object fails SHA-1 check");
  std::string out(type_name(obj->type));
  out += ' ';
  out += std::to_string(obj->data.size());
  out += '\n';
  out += obj->data;
  return out;
}

// ---------------------------------------------------------------------- log

std::string cmd_log(Repository& repo, const Args& args) {
  require_args(args, 1, 2);
  std::uint64_t limit = std::numeric_limits<std::uint64_t>::max();
  if (args.size() == 2) {
    if (args[1].empty()) throw Error("bad count");
    limit = 0;
    for (char c : args[1]) {
      if (c < '0' || c > '9') throw Error("bad count");
      std::uint64_t d = std::uint64_t(c - '0');
      if (limit > (std::numeric_limits<std::uint64_t>::max() - d) / 10) {
        limit = std::numeric_limits<std::uint64_t>::max();
      } else {
        limit = limit * 10 + d;
      }
    }
  }
  ObjectId start = peel(repo, resolve_revision(repo, args[0]), PeelTarget::Commit);

  struct Pending {
    std::uint64_t date;
    std::uint64_t seq;  // discovery order
    ObjectId id;
  };
  // Highest date first; among equal dates, earliest discovered first.
  auto later = [](const Pending& a, const Pending& b) {
    return a.date != b.date ? a.date < b.date : a.seq > b.seq;
  };
  std::priority_queue<Pending, std::vector<Pending>, decltype(later)> queue(later);
  std::unordered_set<ObjectId, ObjectIdHash> seen;
  std::uint64_t next_seq = 0;

  queue.push({repo.commit(start).committer.timestamp, next_seq++, start});
  seen.insert(start);

  std::string out;
  for (std::uint64_t emitted = 0; !queue.empty() && emitted < limit; ++emitted) {
    ObjectId id = queue.top().id;
    queue.pop();
    const Commit& c = repo.commit(id);
    out += id.hex();
    out += ' ';
    out += c.author.name;
    out += ' ';
    out += std::to_string(c.author.timestamp);
    out += ' ';
    out += c.subject;
    out += '\n';
    for (const ObjectId& parent : c.parents) {
      if (seen.insert(parent).second) {
        queue.push({repo.commit(parent).committer.timestamp, next_seq++, parent});
      }
    }
  }
  return out;
}

// ------------------------------------------------------------------ ls-tree

std::string cmd_ls_tree(Repository& repo, const Args& args) {
  require_args(args, 1, 2);
  ObjectId id = peel(repo, resolve_revision(repo, args[0]), PeelTarget::Tree);

  if (args.size() == 2) {
    std::string_view path = args[1];
    std::size_t pos = 0;
    for (;;) {
      std::size_t slash = path.find('/', pos);
      std::string_view part = path.substr(pos, slash == std::string_view::npos ? std::string_view::npos : slash - pos);
      if (part.empty() || part == "." || part == "..") throw Error("bad path");
      if (slash == std::string_view::npos) break;
      pos = slash + 1;
    }
    pos = 0;
    for (;;) {
      std::size_t slash = path.find('/', pos);
      std::string_view part = path.substr(pos, slash == std::string_view::npos ? std::string_view::npos : slash - pos);
      const Tree& t = repo.tree(id);
      auto it = std::find_if(t.entries.begin(), t.entries.end(),
                             [&](const TreeEntry& e) { return e.name == part; });
      if (it == t.entries.end() || !it->is_tree()) throw Error("path is not a tree");
      id = it->id;
      if (slash == std::string_view::npos) break;
      pos = slash + 1;
    }
  }

  std::string out;
  for (const TreeEntry& e : repo.tree(id).entries) {
    out += octal6(e.mode);
    out += ' ';
    out += type_name(e.type());
    out += ' ';
    out += e.id.hex();
    out += '\t';
    out += quote_path(e.name);
    out += '\n';
  }
  return out;
}

// --------------------------------------------------------------------- diff

struct FlatEntry {
  std::string path;
  std::uint32_t mode;
  ObjectId id;
};

void flatten(Repository& repo, const ObjectId& tree, const std::string& prefix,
             std::vector<FlatEntry>& out) {
  for (const TreeEntry& e : repo.tree(tree).entries) {
    std::string path = prefix + e.name;
    if (e.is_tree()) {
      flatten(repo, e.id, path + "/", out);
    } else {
      out.push_back({std::move(path), e.mode, e.id});
    }
  }
}

std::vector<FlatEntry> flatten_sorted(Repository& repo, const ObjectId& tree) {
  std::vector<FlatEntry> entries;
  flatten(repo, tree, "", entries);
  std::stable_sort(entries.begin(), entries.end(),
                   [](const FlatEntry& a, const FlatEntry& b) { return a.path < b.path; });
  return entries;
}

std::string cmd_diff(Repository& repo, const Args& args) {
  require_args(args, 2, 2);
  ObjectId t1 = peel(repo, resolve_revision(repo, args[0]), PeelTarget::Tree);
  ObjectId t2 = peel(repo, resolve_revision(repo, args[1]), PeelTarget::Tree);
  std::vector<FlatEntry> a = flatten_sorted(repo, t1);
  std::vector<FlatEntry> b = flatten_sorted(repo, t2);

  const std::string zero_id(ObjectId::kHexSize, '0');
  std::string out;
  auto emit = [&](const FlatEntry* x, const FlatEntry* y) {
    char status;
    if (!x) status = 'A';
    else if (!y) status = 'D';
    else if ((x->mode & 0170000) == (y->mode & 0170000)) status = 'M';
    else status = 'T';
    out += ':';
    out += x ? octal6(x->mode) : "000000";
    out += ' ';
    out += y ? octal6(y->mode) : "000000";
    out += ' ';
    out += x ? x->id.hex() : zero_id;
    out += ' ';
    out += y ? y->id.hex() : zero_id;
    out += ' ';
    out += status;
    out += '\t';
    out += quote_path((x ? x : y)->path);
    out += '\n';
  };

  std::size_t i = 0, j = 0;
  while (i < a.size() || j < b.size()) {
    if (j == b.size() || (i < a.size() && a[i].path < b[j].path)) {
      emit(&a[i++], nullptr);
    } else if (i == a.size() || b[j].path < a[i].path) {
      emit(nullptr, &b[j++]);
    } else {
      if (a[i].mode != b[j].mode || a[i].id != b[j].id) emit(&a[i], &b[j]);
      ++i;
      ++j;
    }
  }
  return out;
}

// ------------------------------------------------------------ count-objects

std::string cmd_count_objects(Repository& repo, const Args& args) {
  require_args(args, 0, 0);
  const ObjectStore& s = repo.objects();
  return "loose: " + std::to_string(s.loose_count()) +
         "\nin-pack: " + std::to_string(s.packed_object_count()) +
         "\npacks: " + std::to_string(s.pack_count()) + "\n";
}

}  // namespace

std::string run_command(Repository& repo, std::string_view line) {
  Args tokens;
  std::size_t pos = 0;
  for (;;) {
    std::size_t sp = line.find(' ', pos);
    tokens.push_back(line.substr(pos, sp == std::string_view::npos ? std::string_view::npos : sp - pos));
    if (sp == std::string_view::npos) break;
    pos = sp + 1;
  }
  std::string_view name = tokens[0];
  Args args(tokens.begin() + 1, tokens.end());

  if (name == "log") return cmd_log(repo, args);
  if (name == "ls-tree") return cmd_ls_tree(repo, args);
  if (name == "cat-file") return cmd_cat_file(repo, args);
  if (name == "diff") return cmd_diff(repo, args);
  if (name == "rev-parse") return cmd_rev_parse(repo, args);
  if (name == "count-objects") return cmd_count_objects(repo, args);
  throw Error("unknown command");
}

std::string run_command_or_error(Repository& repo, std::string_view line) {
  try {
    return run_command(repo, line);
  } catch (const std::exception&) {
    return "error\n";
  }
}

}  // namespace gitrepo
