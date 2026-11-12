#include "gitrepo/revision.hpp"

#include <cstdint>
#include <limits>
#include <string>

#include "gitrepo/error.hpp"

namespace gitrepo {

namespace {

bool is_digit(char c) { return c >= '0' && c <= '9'; }

std::uint64_t parse_count(std::string_view digits) {
  if (digits.empty()) return 1;
  std::uint64_t n = 0;
  for (char c : digits) {
    std::uint64_t d = std::uint64_t(c - '0');
    if (n > (std::numeric_limits<std::uint64_t>::max() - d) / 10) {
      return std::numeric_limits<std::uint64_t>::max();
    }
    n = n * 10 + d;
  }
  return n;
}

PeelTarget peel_target_from_name(std::string_view name) {
  if (name.empty()) return PeelTarget::Any;
  if (name == "commit") return PeelTarget::Commit;
  if (name == "tree") return PeelTarget::Tree;
  if (name == "blob") return PeelTarget::Blob;
  if (name == "tag") return PeelTarget::Tag;
  throw Error("unknown peel target");
}

std::optional<ObjectId> resolve_name(Repository& repo, std::string_view name) {
  struct Pattern {
    const char* prefix;
    const char* suffix;
  };
  static constexpr Pattern kPatterns[] = {
      {"", ""},
      {"refs/", ""},
      {"refs/tags/", ""},
      {"refs/heads/", ""},
      {"refs/remotes/", ""},
      {"refs/remotes/", "/HEAD"},
  };
  for (const Pattern& p : kPatterns) {
    std::string candidate = p.prefix;
    candidate.append(name);
    candidate += p.suffix;
    if (auto id = repo.refs().resolve(candidate)) return id;
  }
  return std::nullopt;
}

ObjectId resolve_object_id(Repository& repo, std::string_view rev) {
  if (rev.size() < 4 || rev.size() > ObjectId::kHexSize) throw Error("unknown revision");
  std::string lower;
  for (char c : rev) {
    if (c >= 'A' && c <= 'F') c = static_cast<char>(c - 'A' + 'a');
    if (!is_lower_hex(c)) throw Error("unknown revision");
    lower += c;
  }
  if (lower.size() == ObjectId::kHexSize) {
    ObjectId id = *ObjectId::from_hex(lower);
    if (!repo.objects().contains(id)) throw Error("no such object");
    return id;
  }
  auto matches = repo.objects().find_by_prefix(lower, 2);
  if (matches.size() != 1) throw Error("abbreviation is missing or ambiguous");
  return matches[0];
}

}  // namespace

ObjectId peel(Repository& repo, const ObjectId& start, PeelTarget target) {
  ObjectId id = start;
  for (;;) {
    ObjectPtr obj = repo.objects().read(id);
    switch (target) {
      case PeelTarget::Any:
        if (obj->type != ObjectType::Tag) return id;
        id = parse_tag(obj->data).target;
        continue;
      case PeelTarget::Commit:
      case PeelTarget::Tree:
      case PeelTarget::Blob:
      case PeelTarget::Tag: {
        ObjectType want = target == PeelTarget::Commit ? ObjectType::Commit
                        : target == PeelTarget::Tree   ? ObjectType::Tree
                        : target == PeelTarget::Blob   ? ObjectType::Blob
                                                       : ObjectType::Tag;
        if (obj->type == want) return id;
        if (obj->type == ObjectType::Tag) {
          id = parse_tag(obj->data).target;
        } else if (obj->type == ObjectType::Commit) {
          id = repo.commit(id).tree;
        } else {
          throw Error("cannot peel object");
        }
        continue;
      }
    }
  }
}

ObjectId resolve_revision(Repository& repo, std::string_view rev) {
  // Rule 1: `<rev>^{<peel>}`.
  if (!rev.empty() && rev.back() == '}') {
    std::size_t p = rev.rfind("^{");
    if (p != std::string_view::npos && p != 0) {
      std::string_view name = rev.substr(p + 2, rev.size() - p - 3);
      PeelTarget target = name == "object" ? PeelTarget::Any : peel_target_from_name(name);
      ObjectId base = resolve_revision(repo, rev.substr(0, p));
      if (name == "object") {
        if (!repo.objects().contains(base)) throw Error("object not present");
        return base;
      }
      return peel(repo, base, target);
    }
  }

  // Rule 2: `<rev>^<n>` and `<rev>~<n>`.
  std::size_t digits = rev.size();
  while (digits > 0 && is_digit(rev[digits - 1])) --digits;
  if (digits >= 2 && (rev[digits - 1] == '^' || rev[digits - 1] == '~')) {
    char op = rev[digits - 1];
    std::uint64_t n = parse_count(rev.substr(digits));
    ObjectId commit_id = peel(repo, resolve_revision(repo, rev.substr(0, digits - 1)), PeelTarget::Commit);
    if (n == 0) return commit_id;
    if (op == '^') {
      const Commit& c = repo.commit(commit_id);
      if (n > c.parents.size()) throw Error("no such parent");
      return c.parents[static_cast<std::size_t>(n - 1)];
    }
    for (std::uint64_t i = 0; i < n; ++i) {
      const Commit& c = repo.commit(commit_id);
      if (c.parents.empty()) throw Error("no such ancestor");
      commit_id = c.parents[0];
    }
    return commit_id;
  }

  // Rule 3: a ref name.
  if (auto id = resolve_name(repo, rev)) return *id;

  // Rules 4 and 5: an object id or abbreviation, else failure.
  return resolve_object_id(repo, rev);
}

}  // namespace gitrepo
