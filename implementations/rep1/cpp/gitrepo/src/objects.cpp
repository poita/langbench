#include "gitrepo/objects.hpp"

#include <utility>

#include "gitrepo/error.hpp"

namespace gitrepo {

namespace {

bool is_space(char c) {
  return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f';
}

std::string_view rstrip(std::string_view s) {
  while (!s.empty() && is_space(s.back())) s.remove_suffix(1);
  return s;
}

/// The header block of a commit or tag, with continuation lines skipped.
struct Headers {
  std::vector<std::pair<std::string_view, std::string_view>> fields;
  std::string_view message;
};

Headers split_headers(std::string_view payload) {
  Headers h;
  std::size_t pos = 0;
  while (pos < payload.size()) {
    std::size_t eol = payload.find('\n', pos);
    std::size_t next = eol == std::string_view::npos ? payload.size() : eol + 1;
    std::string_view line = payload.substr(pos, (eol == std::string_view::npos ? payload.size() : eol) - pos);
    pos = next;
    if (line.empty()) {
      h.message = payload.substr(next);
      return h;
    }
    if (line[0] == ' ') continue;  // continuation of the previous header
    std::size_t sp = line.find(' ');
    if (sp == std::string_view::npos) {
      h.fields.emplace_back(line, std::string_view());
    } else {
      h.fields.emplace_back(line.substr(0, sp), line.substr(sp + 1));
    }
  }
  return h;
}

Ident parse_ident(std::string_view value) {
  Ident ident;
  std::size_t lt = value.find('<');
  ident.name = std::string(rstrip(value.substr(0, lt)));
  if (lt == std::string_view::npos) return ident;
  std::size_t gt = value.find('>', lt);
  if (gt == std::string_view::npos) return ident;
  std::size_t i = gt + 1;
  while (i < value.size() && value[i] == ' ') ++i;
  if (i < value.size() && (value[i] == '+' || value[i] == '-')) ++i;
  std::uint64_t ts = 0;
  for (; i < value.size() && value[i] >= '0' && value[i] <= '9'; ++i) {
    ts = ts * 10 + std::uint64_t(value[i] - '0');
  }
  ident.timestamp = ts;
  return ident;
}

ObjectId parse_id(std::string_view hex, const char* what) {
  auto id = ObjectId::from_hex(hex);
  if (!id) throw Error(std::string("malformed ") + what + " id");
  return *id;
}

}  // namespace

std::string commit_subject(std::string_view message) {
  std::string subject;
  bool in_paragraph = false;
  std::size_t pos = 0;
  while (pos <= message.size()) {
    std::size_t eol = message.find('\n', pos);
    std::string_view line = message.substr(pos, eol == std::string_view::npos ? std::string_view::npos : eol - pos);
    line = rstrip(line);
    if (line.empty()) {
      if (in_paragraph) break;
    } else {
      if (in_paragraph) subject += ' ';
      subject.append(line);
      in_paragraph = true;
    }
    if (eol == std::string_view::npos) break;
    pos = eol + 1;
  }
  return subject;
}

Commit parse_commit(std::string_view payload) {
  Headers h = split_headers(payload);
  Commit c;
  bool has_tree = false;
  for (const auto& [key, value] : h.fields) {
    if (key == "tree") {
      c.tree = parse_id(value, "tree");
      has_tree = true;
    } else if (key == "parent") {
      c.parents.push_back(parse_id(value, "parent"));
    } else if (key == "author") {
      c.author = parse_ident(value);
    } else if (key == "committer") {
      c.committer = parse_ident(value);
    }
  }
  if (!has_tree) throw Error("commit has no tree header");
  c.message = std::string(h.message);
  c.subject = commit_subject(h.message);
  return c;
}

Tag parse_tag(std::string_view payload) {
  Headers h = split_headers(payload);
  std::optional<ObjectId> target;
  for (const auto& [key, value] : h.fields) {
    if (key == "object") target = parse_id(value, "tag object");
  }
  if (!target) throw Error("tag has no object header");
  return Tag{*target};
}

ObjectType TreeEntry::type() const {
  switch (mode & 0170000) {
    case 0040000: return ObjectType::Tree;
    case 0160000: return ObjectType::Commit;
    default: return ObjectType::Blob;
  }
}

Tree parse_tree(std::string_view payload) {
  Tree t;
  std::size_t pos = 0;
  while (pos < payload.size()) {
    std::size_t sp = payload.find(' ', pos);
    if (sp == std::string_view::npos || sp == pos || sp - pos > 10) throw Error("malformed tree entry");
    std::uint32_t mode = 0;
    for (std::size_t i = pos; i < sp; ++i) {
      if (payload[i] < '0' || payload[i] > '7') throw Error("malformed tree mode");
      mode = mode * 8 + std::uint32_t(payload[i] - '0');
    }
    std::size_t nul = payload.find('\0', sp + 1);
    if (nul == std::string_view::npos || nul == sp + 1) throw Error("malformed tree entry name");
    if (payload.size() - (nul + 1) < ObjectId::kSize) throw Error("truncated tree entry");
    TreeEntry e;
    e.mode = mode;
    e.name = std::string(payload.substr(sp + 1, nul - sp - 1));
    e.id = ObjectId::from_raw(payload.data() + nul + 1);
    t.entries.push_back(std::move(e));
    pos = nul + 1 + ObjectId::kSize;
  }
  return t;
}

}  // namespace gitrepo
