#include "sitegen/model.hpp"

#include <algorithm>
#include <unordered_map>

#include "sitegen/markdown.hpp"

namespace sitegen {

std::string slugify_tag(std::string_view name) {
  std::string out;
  for (const char ch : name) {
    char c = ch;
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    const bool keep = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    if (keep) {
      out.push_back(c);
    } else if (!out.empty() && out.back() != '-') {
      out.push_back('-');
    }
  }
  while (!out.empty() && out.back() == '-') out.pop_back();
  return out;
}

std::string format_long_date(std::string_view iso) {
  static const char* const kMonths[] = {"January", "February", "March",     "April",   "May",      "June",
                                         "July",    "August",   "September", "October", "November", "December"};
  if (iso.size() != 10) return std::string(iso);
  const int month = (iso[5] - '0') * 10 + (iso[6] - '0');
  const int day = (iso[8] - '0') * 10 + (iso[9] - '0');
  if (month < 1 || month > 12) return std::string(iso);
  return std::string(kMonths[month - 1]) + " " + std::to_string(day) + ", " + std::string(iso.substr(0, 4));
}

std::string excerpt_source(std::string_view body) {
  auto is_blank = [](std::string_view line) {
    return line.find_first_not_of(" \t") == std::string_view::npos;
  };
  std::size_t pos = 0;
  std::string out;
  bool started = false;
  while (pos <= body.size()) {
    std::size_t nl = body.find('\n', pos);
    if (nl == std::string_view::npos) nl = body.size();
    const std::string_view line = body.substr(pos, nl - pos);
    if (is_blank(line)) {
      if (started) break;
    } else {
      if (started) out.push_back('\n');
      out.append(line);
      started = true;
    }
    if (nl >= body.size()) break;
    pos = nl + 1;
  }
  return out;
}

namespace {

Value to_value(const toml::Value& v) {
  switch (v.type()) {
    case toml::Value::Type::String: return Value::string(v.as_string());
    case toml::Value::Type::Integer: return Value::integer(v.as_integer());
    case toml::Value::Type::Boolean: return Value::boolean(v.as_boolean());
    case toml::Value::Type::Array: {
      List items;
      for (const std::string& s : v.as_array()) items.push_back(Value::string(s));
      return Value::list(std::move(items));
    }
  }
  return Value::undefined();
}

Value make_dict(std::initializer_list<std::pair<const char*, Value>> members) {
  Dict d;
  for (const auto& m : members) d.set(m.first, m.second);
  return Value::dict(std::move(d));
}

std::string require_config_string(const toml::Document& doc, const char* key) {
  const toml::Value* v = doc.find(key);
  if (v == nullptr || !v->is_string()) {
    throw SiteError(std::string("site.toml: missing string key '") + key + "'");
  }
  return v->as_string();
}

}  // namespace

std::string SiteModel::index_url(std::size_t number) {
  return number <= 1 ? "/" : "/page/" + std::to_string(number) + "/";
}

std::size_t SiteModel::total_pages() const {
  const std::size_t per = static_cast<std::size_t>(config_.posts_per_page);
  return std::max<std::size_t>(1, (posts_.size() + per - 1) / per);
}

SiteModel SiteModel::build(const SiteSource& source) {
  SiteModel m;
  const toml::Document& cfg = source.config;
  m.config_.title = require_config_string(cfg, "title");
  m.config_.base_url = require_config_string(cfg, "base_url");
  m.config_.author = require_config_string(cfg, "author");
  const toml::Value* ppp = cfg.find("posts_per_page");
  if (ppp == nullptr || !ppp->is_integer() || ppp->as_integer() < 1) {
    throw SiteError("site.toml: 'posts_per_page' must be an integer >= 1");
  }
  m.config_.posts_per_page = ppp->as_integer();

  Dict site;
  for (const toml::Entry& e : cfg.entries()) site.set(e.key, to_value(e.value));
  m.site_value_ = Value::dict(std::move(site));

  // --- Published posts in canonical order ---------------------------------
  std::vector<const Post*> published;
  for (const Post& p : source.posts) {
    if (!p.draft) published.push_back(&p);
  }
  std::sort(published.begin(), published.end(), [](const Post* a, const Post* b) {
    if (a->date != b->date) return a->date > b->date;
    return a->slug < b->slug;
  });

  // --- Tags: O(K + T log T) -------------------------------------------------
  struct RawTag {
    std::string name;
    std::string slug;
    std::vector<std::size_t> posts;
  };
  std::vector<RawTag> raw_tags;
  std::unordered_map<std::string, std::size_t> tag_ids;
  std::vector<std::vector<std::size_t>> post_raw_tags(published.size());
  for (std::size_t i = 0; i < published.size(); ++i) {
    for (const std::string& name : published[i]->tags) {
      auto it = tag_ids.find(name);
      if (it == tag_ids.end()) {
        it = tag_ids.emplace(name, raw_tags.size()).first;
        raw_tags.push_back(RawTag{name, slugify_tag(name), {}});
      }
      std::vector<std::size_t>& mine = post_raw_tags[i];
      if (std::find(mine.begin(), mine.end(), it->second) != mine.end()) continue;  // repeated tag
      mine.push_back(it->second);
      raw_tags[it->second].posts.push_back(i);
    }
  }
  std::vector<std::size_t> order(raw_tags.size());
  for (std::size_t i = 0; i < order.size(); ++i) order[i] = i;
  std::sort(order.begin(), order.end(),
            [&](std::size_t a, std::size_t b) { return raw_tags[a].slug < raw_tags[b].slug; });
  std::vector<std::size_t> rank(raw_tags.size());
  for (std::size_t r = 0; r < order.size(); ++r) rank[order[r]] = r;

  m.tags_.resize(raw_tags.size());
  List tag_links;
  for (std::size_t r = 0; r < order.size(); ++r) {
    RawTag& raw = raw_tags[order[r]];
    TagEntry& t = m.tags_[r];
    t.name = raw.name;
    t.slug = raw.slug;
    t.url = "/tags/" + t.slug + "/";
    t.post_indices = std::move(raw.posts);
    t.link = make_dict({{"name", Value::string(t.name)},
                        {"slug", Value::string(t.slug)},
                        {"url", Value::string(t.url)},
                        {"post_count", Value::integer(static_cast<std::int64_t>(t.post_indices.size()))}});
    tag_links.push_back(t.link);
  }
  m.tag_links_ = Value::list(std::move(tag_links));

  // --- Posts ---------------------------------------------------------------
  const std::size_t n = published.size();
  m.posts_.resize(n);
  for (std::size_t i = 0; i < n; ++i) {
    const Post& p = *published[i];
    PostEntry& e = m.posts_[i];
    e.title = p.title;
    e.slug = p.slug;
    e.url = "/posts/" + p.slug + "/";
    e.permalink = m.config_.base_url + e.url;
    e.date = p.date;
    e.date_long = format_long_date(p.date);
    e.content_html = markdown_to_html(p.body);
    e.excerpt_html = markdown_to_html(excerpt_source(p.body));
    for (const std::size_t raw : post_raw_tags[i]) e.tag_indices.push_back(rank[raw]);
    e.link = make_dict({{"title", Value::string(e.title)},
                        {"slug", Value::string(e.slug)},
                        {"url", Value::string(e.url)},
                        {"permalink", Value::string(e.permalink)},
                        {"date", Value::string(e.date)},
                        {"date_long", Value::string(e.date_long)}});
  }
  for (std::size_t i = 0; i < n; ++i) {
    PostEntry& e = m.posts_[i];
    List tags;
    for (const std::size_t t : e.tag_indices) tags.push_back(m.tags_[t].link);
    e.value = make_dict({{"title", Value::string(e.title)},
                         {"slug", Value::string(e.slug)},
                         {"url", Value::string(e.url)},
                         {"permalink", Value::string(e.permalink)},
                         {"date", Value::string(e.date)},
                         {"date_long", Value::string(e.date_long)},
                         {"tags", Value::list(std::move(tags))},
                         {"content", Value::string(e.content_html)},
                         {"excerpt", Value::string(e.excerpt_html)},
                         {"older", i + 1 < n ? m.posts_[i + 1].link : Value::none()},
                         {"newer", i > 0 ? m.posts_[i - 1].link : Value::none()}});
  }

  // --- Tag objects (need the post objects) ---------------------------------
  for (TagEntry& t : m.tags_) {
    List posts;
    for (const std::size_t pi : t.post_indices) posts.push_back(m.posts_[pi].value);
    t.value = make_dict({{"name", Value::string(t.name)},
                         {"slug", Value::string(t.slug)},
                         {"url", Value::string(t.url)},
                         {"post_count", Value::integer(static_cast<std::int64_t>(t.post_indices.size()))},
                         {"posts", Value::list(std::move(posts))}});
  }

  // --- Pages ---------------------------------------------------------------
  std::vector<const Page*> pages;
  for (const Page& p : source.pages) {
    if (!p.draft) pages.push_back(&p);
  }
  std::sort(pages.begin(), pages.end(), [](const Page* a, const Page* b) { return a->slug < b->slug; });
  List page_links;
  for (const Page* p : pages) {
    PageEntry e;
    e.title = p->title;
    e.slug = p->slug;
    e.url = "/" + p->slug + "/";
    e.permalink = m.config_.base_url + e.url;
    e.content_html = markdown_to_html(p->body);
    e.link = make_dict({{"title", Value::string(e.title)},
                        {"slug", Value::string(e.slug)},
                        {"url", Value::string(e.url)}});
    e.value = make_dict({{"title", Value::string(e.title)},
                         {"slug", Value::string(e.slug)},
                         {"url", Value::string(e.url)},
                         {"permalink", Value::string(e.permalink)},
                         {"content", Value::string(e.content_html)}});
    page_links.push_back(e.link);
    m.pages_.push_back(std::move(e));
  }
  m.page_links_ = Value::list(std::move(page_links));
  return m;
}

Value SiteModel::index_posts(std::size_t number) const {
  const std::size_t per = static_cast<std::size_t>(config_.posts_per_page);
  const std::size_t begin = std::min(posts_.size(), (number - 1) * per);
  const std::size_t end = std::min(posts_.size(), number * per);
  List items;
  items.reserve(end - begin);
  for (std::size_t i = begin; i < end; ++i) items.push_back(posts_[i].value);
  return Value::list(std::move(items));
}

Value SiteModel::pagination(std::size_t number) const {
  const std::size_t total = total_pages();
  List links;
  links.reserve(total);
  for (std::size_t i = 1; i <= total; ++i) {
    links.push_back(make_dict({{"number", Value::integer(static_cast<std::int64_t>(i))},
                               {"url", Value::string(index_url(i))},
                               {"current", Value::boolean(i == number)}}));
  }
  return make_dict(
      {{"number", Value::integer(static_cast<std::int64_t>(number))},
       {"total_pages", Value::integer(static_cast<std::int64_t>(total))},
       {"total_posts", Value::integer(static_cast<std::int64_t>(posts_.size()))},
       {"has_prev", Value::boolean(number > 1)},
       {"has_next", Value::boolean(number < total)},
       {"prev_url", number > 1 ? Value::string(index_url(number - 1)) : Value::none()},
       {"next_url", number < total ? Value::string(index_url(number + 1)) : Value::none()},
       {"links", Value::list(std::move(links))}});
}

}  // namespace sitegen
