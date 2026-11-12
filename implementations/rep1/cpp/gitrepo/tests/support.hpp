// Helpers for building throw-away repositories in the tests.
#pragma once

#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <utility>
#include <vector>

#include "gitrepo/inflate.hpp"
#include "gitrepo/object_store.hpp"
#include "gitrepo/sha1.hpp"

namespace testing_support {

namespace fs = std::filesystem;
using gitrepo::ObjectId;
using gitrepo::ObjectType;

class TempDir {
 public:
  TempDir() {
    static int counter = 0;
    path_ = fs::temp_directory_path() /
            ("gitrepo-test-" + std::to_string(::getpid()) + "-" + std::to_string(counter++));
    fs::create_directories(path_);
  }
  ~TempDir() {
    std::error_code ec;
    fs::remove_all(path_, ec);
  }
  TempDir(const TempDir&) = delete;
  TempDir& operator=(const TempDir&) = delete;
  const fs::path& path() const { return path_; }

 private:
  fs::path path_;
};

inline void write_file(const fs::path& path, const std::string& data) {
  fs::create_directories(path.parent_path());
  std::ofstream out(path, std::ios::binary);
  out.write(data.data(), static_cast<std::streamsize>(data.size()));
}

inline void put32(std::string& s, std::uint32_t v) {
  for (int i = 3; i >= 0; --i) s += static_cast<char>((v >> (8 * i)) & 0xff);
}

/// A valid zlib stream made of stored (uncompressed) blocks.
inline std::string zlib_store(const std::string& data) {
  std::string out = "\x78\x01";
  std::size_t pos = 0;
  do {
    std::size_t n = std::min<std::size_t>(65535, data.size() - pos);
    bool last = pos + n == data.size();
    out += static_cast<char>(last ? 1 : 0);
    out += static_cast<char>(n & 0xff);
    out += static_cast<char>(n >> 8);
    out += static_cast<char>(~n & 0xff);
    out += static_cast<char>((~n >> 8) & 0xff);
    out.append(data, pos, n);
    pos += n;
  } while (pos < data.size());
  put32(out, gitrepo::adler32(data));
  return out;
}

inline std::string raw(const ObjectId& id) { return std::string(id.raw()); }

struct TreeItem {
  std::string mode;  // e.g. "100644"
  std::string name;
  ObjectId id;
};

/// Builds a repository directory object by object.
class RepoBuilder {
 public:
  const fs::path& git_dir() const { return dir_.path(); }

  ObjectId loose(ObjectType type, const std::string& payload) {
    ObjectId id = gitrepo::hash_object(type, payload);
    std::string hex = id.hex();
    std::string stored = std::string(gitrepo::type_name(type)) + " " +
                         std::to_string(payload.size()) + '\0' + payload;
    write_file(git_dir() / "objects" / hex.substr(0, 2) / hex.substr(2), zlib_store(stored));
    return id;
  }

  ObjectId blob(const std::string& content) { return loose(ObjectType::Blob, content); }

  static std::string tree_payload(const std::vector<TreeItem>& items) {
    std::string payload;
    for (const auto& it : items) payload += it.mode + " " + it.name + '\0' + raw(it.id);
    return payload;
  }
  ObjectId tree(const std::vector<TreeItem>& items) {
    return loose(ObjectType::Tree, tree_payload(items));
  }

  static std::string commit_payload(const ObjectId& tree, const std::vector<ObjectId>& parents,
                                    const std::string& message, std::uint64_t author_ts,
                                    std::uint64_t committer_ts) {
    std::string p = "tree " + tree.hex() + "\n";
    for (const auto& parent : parents) p += "parent " + parent.hex() + "\n";
    p += "author Ada Lovelace <ada@example.com> " + std::to_string(author_ts) + " +0000\n";
    p += "committer Bob <bob@example.com> " + std::to_string(committer_ts) + " +0000\n\n";
    return p + message;
  }
  ObjectId commit(const ObjectId& tree, const std::vector<ObjectId>& parents,
                  const std::string& message, std::uint64_t ts) {
    return loose(ObjectType::Commit, commit_payload(tree, parents, message, ts, ts));
  }

  ObjectId tag(const ObjectId& target, const std::string& type, const std::string& name) {
    return loose(ObjectType::Tag, "object " + target.hex() + "\ntype " + type + "\ntag " + name +
                                      "\ntagger T <t@example.com> 1 +0000\n\nmsg\n");
  }

  void ref(const std::string& name, const std::string& content) {
    write_file(git_dir() / name, content);
  }
  void packed_refs(const std::string& text) { write_file(git_dir() / "packed-refs", text); }

 private:
  TempDir dir_;
};

/// Writes a version 2 pack and index.
class PackBuilder {
 public:
  /// Appends a whole object; returns its id.
  ObjectId add(ObjectType type, const std::string& payload) {
    ObjectId id = gitrepo::hash_object(type, payload);
    offsets_.emplace_back(id, pack_.size() + 12);
    pack_ += header(static_cast<int>(type), payload.size());
    pack_ += zlib_store(payload);
    return id;
  }

  /// Appends `base + suffix` as a delta against an earlier object.
  ObjectId add_delta(const ObjectId& base_id, const std::string& base, const std::string& suffix,
                     ObjectType type, bool ref_delta) {
    std::string result = base + suffix;
    std::string delta = varint(base.size()) + varint(result.size());
    // copy the whole base (offset 0, explicit 3-byte size), then insert the suffix
    delta += static_cast<char>(0x80 | 0x10 | 0x20 | 0x40);
    delta += static_cast<char>(base.size() & 0xff);
    delta += static_cast<char>((base.size() >> 8) & 0xff);
    delta += static_cast<char>((base.size() >> 16) & 0xff);
    for (std::size_t i = 0; i < suffix.size(); i += 100) {
      std::size_t n = std::min<std::size_t>(100, suffix.size() - i);
      delta += static_cast<char>(n);
      delta.append(suffix, i, n);
    }
    ObjectId id = gitrepo::hash_object(type, result);
    std::uint64_t here = pack_.size() + 12;
    offsets_.emplace_back(id, here);
    pack_ += header(ref_delta ? 7 : 6, delta.size());
    if (ref_delta) {
      pack_ += raw(base_id);
    } else {
      std::uint64_t back = here - base_offset(base_id);
      std::string enc(1, static_cast<char>(back & 0x7f));
      back >>= 7;
      while (back) {
        --back;
        enc.insert(enc.begin(), static_cast<char>(0x80 | (back & 0x7f)));
        back >>= 7;
      }
      pack_ += enc;
    }
    pack_ += zlib_store(delta);
    return id;
  }

  void write(const fs::path& git_dir, const std::string& name) const {
    std::string pack = "PACK";
    put32(pack, 2);
    put32(pack, static_cast<std::uint32_t>(offsets_.size()));
    pack += pack_;
    pack += raw(gitrepo::sha1(pack));

    auto sorted = offsets_;
    std::sort(sorted.begin(), sorted.end());
    std::string idx = "\xff" "tOc";
    put32(idx, 2);
    std::uint32_t cumulative = 0;
    std::size_t k = 0;
    for (int b = 0; b < 256; ++b) {
      while (k < sorted.size() && sorted[k].first.bytes[0] == b) ++k, ++cumulative;
      put32(idx, cumulative);
    }
    for (const auto& e : sorted) idx += raw(e.first);
    for (std::size_t i = 0; i < sorted.size(); ++i) put32(idx, 0);  // CRCs (unused)
    for (const auto& e : sorted) put32(idx, static_cast<std::uint32_t>(e.second));
    idx += raw(gitrepo::sha1(pack));
    idx += raw(gitrepo::sha1(idx));

    write_file(git_dir / "objects" / "pack" / (name + ".pack"), pack);
    write_file(git_dir / "objects" / "pack" / (name + ".idx"), idx);
  }

 private:
  static std::string header(int type, std::size_t size) {
    std::string h;
    unsigned char c = static_cast<unsigned char>((type << 4) | (size & 15));
    size >>= 4;
    while (size) {
      h += static_cast<char>(c | 0x80);
      c = size & 0x7f;
      size >>= 7;
    }
    h += static_cast<char>(c);
    return h;
  }
  static std::string varint(std::size_t v) {
    std::string s;
    do {
      unsigned char c = v & 0x7f;
      v >>= 7;
      if (v) c |= 0x80;
      s += static_cast<char>(c);
    } while (v);
    return s;
  }
  std::uint64_t base_offset(const ObjectId& id) const {
    for (const auto& e : offsets_) if (e.first == id) return e.second;
    throw std::runtime_error("unknown base");
  }

  std::string pack_;
  std::vector<std::pair<ObjectId, std::uint64_t>> offsets_;
};

}  // namespace testing_support
