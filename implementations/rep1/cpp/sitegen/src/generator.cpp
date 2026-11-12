#include "sitegen/generator.hpp"

#include <fstream>

namespace sitegen {

std::string xml_escape_text(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (const char c : s) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      default: out.push_back(c);
    }
  }
  return out;
}

std::string xml_escape_attribute(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (const char c : s) {
    switch (c) {
      case '&': out += "&amp;"; break;
      case '<': out += "&lt;"; break;
      case '>': out += "&gt;"; break;
      case '"': out += "&quot;"; break;
      default: out.push_back(c);
    }
  }
  return out;
}

std::string render_feed(const SiteModel& model) {
  const SiteConfig& cfg = model.config();
  const auto& posts = model.posts();
  const std::size_t count = std::min<std::size_t>(posts.size(), static_cast<std::size_t>(cfg.posts_per_page));
  const std::string root = cfg.base_url + "/";
  const std::string updated = (posts.empty() ? std::string("1970-01-01") : posts.front().date) + "T00:00:00Z";

  std::string out;
  out += "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
  out += "<feed xmlns=\"http://www.w3.org/2005/Atom\">\n";
  out += "  <title>" + xml_escape_text(cfg.title) + "</title>\n";
  out += "  <id>" + xml_escape_text(root) + "</id>\n";
  out += "  <updated>" + updated + "</updated>\n";
  out += "  <link href=\"" + xml_escape_attribute(root) + "\" rel=\"alternate\"/>\n";
  out += "  <link href=\"" + xml_escape_attribute(cfg.base_url + "/feed.xml") + "\" rel=\"self\"/>\n";
  out += "  <author>\n";
  out += "    <name>" + xml_escape_text(cfg.author) + "</name>\n";
  out += "  </author>\n";
  for (std::size_t i = 0; i < count; ++i) {
    const PostEntry& p = posts[i];
    out += "  <entry>\n";
    out += "    <title>" + xml_escape_text(p.title) + "</title>\n";
    out += "    <id>" + xml_escape_text(p.permalink) + "</id>\n";
    out += "    <updated>" + p.date + "T00:00:00Z</updated>\n";
    out += "    <link href=\"" + xml_escape_attribute(p.permalink) + "\" rel=\"alternate\"/>\n";
    out += "    <content type=\"html\">" + xml_escape_text(p.content_html) + "</content>\n";
    out += "  </entry>\n";
  }
  out += "</feed>\n";
  return out;
}

std::string render_sitemap(const SiteModel& model) {
  const std::string& base = model.config().base_url;
  std::string out;
  out += "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n";
  out += "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n";
  auto add = [&](const std::string& url, const std::string* lastmod) {
    out += "  <url>\n";
    out += "    <loc>" + xml_escape_text(url) + "</loc>\n";
    if (lastmod != nullptr) out += "    <lastmod>" + *lastmod + "</lastmod>\n";
    out += "  </url>\n";
  };
  for (std::size_t i = 1; i <= model.total_pages(); ++i) add(base + SiteModel::index_url(i), nullptr);
  for (const PostEntry& p : model.posts()) add(p.permalink, &p.date);
  for (const PageEntry& p : model.pages()) add(p.permalink, nullptr);
  add(base + "/tags/", nullptr);
  for (const TagEntry& t : model.tags()) add(base + t.url, nullptr);
  out += "</urlset>\n";
  return out;
}

TemplateEngine make_template_engine(const SiteSource& source) {
  TemplateEngine engine;
  for (const auto& [name, text] : source.templates) engine.add_template(name, text);
  return engine;
}

std::vector<OutputFile> render_site(const SiteModel& model, const TemplateEngine& templates) {
  std::vector<OutputFile> files;

  auto root_context = [&]() {
    Dict ctx;
    ctx.set("site", model.site_value());
    ctx.set("tags", model.tag_links());
    ctx.set("pages", model.page_links());
    return ctx;
  };

  // Index pages.
  for (std::size_t n = 1; n <= model.total_pages(); ++n) {
    Dict ctx = root_context();
    ctx.set("posts", model.index_posts(n));
    ctx.set("pagination", model.pagination(n));
    files.push_back({n == 1 ? "index.html" : "page/" + std::to_string(n) + "/index.html",
                     templates.render("index.html", ctx)});
  }
  for (const PostEntry& p : model.posts()) {
    Dict ctx = root_context();
    ctx.set("post", p.value);
    files.push_back({"posts/" + p.slug + "/index.html", templates.render("post.html", ctx)});
  }
  for (const PageEntry& p : model.pages()) {
    Dict ctx = root_context();
    ctx.set("page", p.value);
    files.push_back({p.slug + "/index.html", templates.render("page.html", ctx)});
  }
  files.push_back({"tags/index.html", templates.render("tags.html", root_context())});
  for (const TagEntry& t : model.tags()) {
    Dict ctx = root_context();
    ctx.set("tag", t.value);
    ctx.set("posts", t.value.as_dict().find("posts") != nullptr ? *t.value.as_dict().find("posts") : Value::list({}));
    files.push_back({"tags/" + t.slug + "/index.html", templates.render("tag.html", ctx)});
  }
  files.push_back({"feed.xml", render_feed(model)});
  files.push_back({"sitemap.xml", render_sitemap(model)});
  return files;
}

void write_files(const std::filesystem::path& output_dir, const std::vector<OutputFile>& files) {
  for (const OutputFile& f : files) {
    const std::filesystem::path target = output_dir / f.path;
    std::filesystem::create_directories(target.parent_path());
    std::ofstream out(target, std::ios::binary | std::ios::trunc);
    out.write(f.contents.data(), static_cast<std::streamsize>(f.contents.size()));
    if (!out) throw SiteError("cannot write " + target.string());
  }
}

void copy_static_files(const std::filesystem::path& static_dir, const std::filesystem::path& output_dir) {
  std::error_code ec;
  if (!std::filesystem::is_directory(static_dir, ec)) return;
  for (const auto& entry : std::filesystem::recursive_directory_iterator(static_dir)) {
    if (!entry.is_regular_file()) continue;
    const std::filesystem::path target = output_dir / std::filesystem::relative(entry.path(), static_dir);
    std::filesystem::create_directories(target.parent_path());
    std::filesystem::copy_file(entry.path(), target, std::filesystem::copy_options::overwrite_existing);
  }
}

void generate_site(const std::filesystem::path& input_dir, const std::filesystem::path& output_dir) {
  const SiteSource source = load_site_source(input_dir);
  const SiteModel model = SiteModel::build(source);
  const TemplateEngine engine = make_template_engine(source);
  const std::vector<OutputFile> files = render_site(model, engine);
  std::filesystem::create_directories(output_dir);
  write_files(output_dir, files);
  copy_static_files(input_dir / "static", output_dir);
}

}  // namespace sitegen
