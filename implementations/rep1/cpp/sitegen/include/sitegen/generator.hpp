/// @file generator.hpp
/// Rendering a `SiteModel` into output files, and the one-call entry point
/// that goes from a source directory to an output directory.
#pragma once

#include <filesystem>
#include <string>
#include <vector>

#include "sitegen/model.hpp"
#include "sitegen/source.hpp"
#include "sitegen/template.hpp"

namespace sitegen {

/// A generated file: a path relative to the output directory (always with `/`
/// separators) and its contents.
struct OutputFile {
  std::string path;
  std::string contents;
};

/// Escapes `&`, `<` and `>` (in that order) for XML text.
std::string xml_escape_text(std::string_view s);
/// Like `xml_escape_text`, and `"` as well, for XML attribute values.
std::string xml_escape_attribute(std::string_view s);

/// The Atom feed (`feed.xml`): the first `posts_per_page` posts.
std::string render_feed(const SiteModel& model);

/// `sitemap.xml`: index pages, posts, pages, the tag index and tags.
std::string render_sitemap(const SiteModel& model);

/// Builds a template engine holding the source's templates.
TemplateEngine make_template_engine(const SiteSource& source);

/// Renders every generated file of the site (all pages, `feed.xml` and
/// `sitemap.xml`); static files are not included.
/// @throws TemplateError if a template fails
std::vector<OutputFile> render_site(const SiteModel& model, const TemplateEngine& templates);

/// Writes `files` below `output_dir`, creating directories as needed.
void write_files(const std::filesystem::path& output_dir, const std::vector<OutputFile>& files);

/// Copies every regular file below `static_dir` (if it exists) to the same
/// relative path below `output_dir`, byte for byte.
void copy_static_files(const std::filesystem::path& static_dir, const std::filesystem::path& output_dir);

/// Reads the site in `input_dir` and writes the finished website to
/// `output_dir` (created if missing).
/// @throws SiteError, toml::ParseError, TemplateError, std::filesystem::filesystem_error
void generate_site(const std::filesystem::path& input_dir, const std::filesystem::path& output_dir);

}  // namespace sitegen
