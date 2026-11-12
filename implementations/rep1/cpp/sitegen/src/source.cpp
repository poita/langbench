#include "sitegen/source.hpp"

#include <algorithm>
#include <fstream>
#include <sstream>

namespace sitegen {

namespace {

std::string read_file(const std::filesystem::path& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) throw SiteError("cannot read " + path.string());
  std::ostringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

std::string require_string(const toml::Document& doc, const char* key, const std::string& where) {
  const toml::Value* v = doc.find(key);
  if (v == nullptr || !v->is_string()) {
    throw SiteError(where + ": missing string key '" + key + "'");
  }
  return v->as_string();
}

/// Regular files directly inside `dir` whose names end with `suffix`, sorted
/// by name. A missing directory yields an empty list.
std::vector<std::filesystem::path> list_files(const std::filesystem::path& dir,
                                              std::string_view suffix) {
  std::vector<std::filesystem::path> out;
  std::error_code ec;
  if (!std::filesystem::is_directory(dir, ec)) return out;
  for (const auto& entry : std::filesystem::directory_iterator(dir, ec)) {
    if (!entry.is_regular_file()) continue;
    const std::string name = entry.path().filename().string();
    if (name.size() >= suffix.size() && name.compare(name.size() - suffix.size(), suffix.size(), suffix) == 0) {
      out.push_back(entry.path());
    }
  }
  std::sort(out.begin(), out.end());
  return out;
}

std::string stem_of(const std::filesystem::path& p) {
  const std::string name = p.filename().string();
  return name.substr(0, name.size() - 3);  // strip ".md"
}

}  // namespace

Post parse_post(std::string_view file_stem, std::string_view file_contents) {
  const std::string where = "post '" + std::string(file_stem) + "'";
  toml::FrontMatter fm = toml::split_front_matter(file_contents);
  Post post;
  post.title = require_string(fm.meta, "title", where);
  post.date = require_string(fm.meta, "date", where);
  post.slug = fm.meta.get_string("slug", std::string(file_stem));
  post.tags = fm.meta.get_array("tags");
  post.draft = fm.meta.get_boolean("draft", false);
  post.body = std::move(fm.body);
  return post;
}

Page parse_page(std::string_view file_stem, std::string_view file_contents) {
  const std::string where = "page '" + std::string(file_stem) + "'";
  toml::FrontMatter fm = toml::split_front_matter(file_contents);
  Page page;
  page.title = require_string(fm.meta, "title", where);
  page.slug = fm.meta.get_string("slug", std::string(file_stem));
  page.draft = fm.meta.get_boolean("draft", false);
  page.body = std::move(fm.body);
  return page;
}

SiteSource load_site_source(const std::filesystem::path& dir) {
  SiteSource src;
  try {
    src.config = toml::parse(read_file(dir / "site.toml"));
    for (const auto& path : list_files(dir / "content" / "posts", ".md")) {
      src.posts.push_back(parse_post(stem_of(path), read_file(path)));
    }
    for (const auto& path : list_files(dir / "content" / "pages", ".md")) {
      src.pages.push_back(parse_page(stem_of(path), read_file(path)));
    }
  } catch (const toml::ParseError& e) {
    throw SiteError(std::string("invalid TOML: ") + e.what());
  }
  for (const auto& path : list_files(dir / "templates", ".html")) {
    std::string text = read_file(path);
    if (!text.empty() && text.back() == '\n') text.pop_back();
    src.templates.emplace_back(path.filename().string(), std::move(text));
  }
  return src;
}

}  // namespace sitegen
