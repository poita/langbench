/// @file model.hpp
/// The content model: published posts and pages in canonical order, tags,
/// pagination, and the template values built from them.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "sitegen/source.hpp"
#include "sitegen/value.hpp"

namespace sitegen {

/// Lower-cases ASCII letters, turns every other non-`[a-z0-9]` character into
/// `-`, collapses runs of `-` and strips them from both ends.
/// `"Web Development"` becomes `web-development`.
std::string slugify_tag(std::string_view name);

/// `2024-03-05` becomes `March 5, 2024`.
std::string format_long_date(std::string_view iso_date);

/// The text of a body's first block: leading blank lines skipped, then the
/// following run of non-blank lines joined with LF.
std::string excerpt_source(std::string_view body);

/// A published post with everything derived from it.
struct PostEntry {
  std::string title, slug, url, permalink, date, date_long;
  std::string content_html;  ///< Markdown of the whole body
  std::string excerpt_html;  ///< Markdown of the first block
  std::vector<std::size_t> tag_indices;  ///< into `SiteModel::tags`, in the post's own order
  Value link;   ///< "post link" template object
  Value value;  ///< "post" template object
};

struct PageEntry {
  std::string title, slug, url, permalink;
  std::string content_html;
  Value link;   ///< "page link" template object
  Value value;  ///< "page" template object
};

struct TagEntry {
  std::string name, slug, url;
  std::vector<std::size_t> post_indices;  ///< canonical order
  Value link;   ///< "tag link" template object
  Value value;  ///< "tag" template object, including its posts
};

/// The site's `site.toml` essentials.
struct SiteConfig {
  std::string title, base_url, author;
  std::int64_t posts_per_page = 1;
};

/// A fully built site model. Every body and excerpt has been converted to HTML
/// exactly once, and every post, page and tag template object has been built
/// once and is shared by every page that shows it.
class SiteModel {
 public:
  /// Builds the model from a source.
  /// @throws SiteError for missing or invalid configuration
  static SiteModel build(const SiteSource& source);

  const SiteConfig& config() const { return config_; }
  /// Published posts, newest first (ties by slug ascending).
  const std::vector<PostEntry>& posts() const { return posts_; }
  /// Published pages by slug.
  const std::vector<PageEntry>& pages() const { return pages_; }
  /// Existing tags by slug.
  const std::vector<TagEntry>& tags() const { return tags_; }

  /// `max(1, ceil(posts / posts_per_page))`.
  std::size_t total_pages() const;
  /// `/` for page 1, `/page/N/` otherwise.
  static std::string index_url(std::size_t number);

  /// The `site` template variable (the parsed `site.toml`, in file order).
  const Value& site_value() const { return site_value_; }
  /// The `tags` template variable (list of tag links).
  const Value& tag_links() const { return tag_links_; }
  /// The `pages` template variable (list of page links).
  const Value& page_links() const { return page_links_; }

  /// The `posts` list of index page `number` (1-based).
  Value index_posts(std::size_t number) const;
  /// The `pagination` object of index page `number` (1-based).
  Value pagination(std::size_t number) const;

 private:
  SiteConfig config_;
  std::vector<PostEntry> posts_;
  std::vector<PageEntry> pages_;
  std::vector<TagEntry> tags_;
  Value site_value_;
  Value tag_links_;
  Value page_links_;
};

}  // namespace sitegen
