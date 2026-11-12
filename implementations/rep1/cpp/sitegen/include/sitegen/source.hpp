/// @file source.hpp
/// The source of a site: configuration, content files and templates, plus
/// readers for the on-disk layout.
#pragma once

#include <filesystem>
#include <stdexcept>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "sitegen/toml.hpp"

namespace sitegen {

/// Thrown for a site source that is missing something or is malformed.
class SiteError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A blog post as written in `content/posts/*.md`.
struct Post {
  std::string title;
  std::string slug;
  std::string date;  ///< `YYYY-MM-DD`
  std::vector<std::string> tags;
  bool draft = false;
  std::string body;  ///< Markdown, after the front matter
};

/// A standalone page as written in `content/pages/*.md`.
struct Page {
  std::string title;
  std::string slug;
  bool draft = false;
  std::string body;
};

/// Everything the generator reads. It can be loaded from a directory with
/// `load_site_source` or assembled in memory.
struct SiteSource {
  /// The parsed `site.toml`. Must contain `title`, `base_url`, `author` and
  /// `posts_per_page`; any other keys are passed through to templates.
  toml::Document config;
  std::vector<Post> posts;  ///< including drafts, in any order
  std::vector<Page> pages;  ///< including drafts, in any order
  /// Template name (file name including `.html`) and source text.
  std::vector<std::pair<std::string, std::string>> templates;
};

/// Parses a post file. `file_stem` (the file name without `.md`) is the
/// default slug.
/// @throws SiteError / toml::ParseError
Post parse_post(std::string_view file_stem, std::string_view file_contents);

/// Parses a page file; see `parse_post`.
Page parse_page(std::string_view file_stem, std::string_view file_contents);

/// Reads `<dir>/site.toml`, `<dir>/content/{posts,pages}/*.md` and
/// `<dir>/templates/*.html`. A template's source is the file's contents with
/// one trailing LF removed.
/// @throws SiteError if a required file is missing or malformed
SiteSource load_site_source(const std::filesystem::path& dir);

}  // namespace sitegen
