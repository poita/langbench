//! The values handed to templates.
//!
//! Post, page and tag objects (and the links to them) are built once, when
//! the [`Context`] is created, and shared by every page that shows them. Only
//! each index page's `pagination` is built per page.

use crate::site::Site;
use crate::template::{Dict, Value};
use crate::toml;

fn dict<const N: usize>(members: [(&'static str, Value); N]) -> Value {
    Value::dict(members.into_iter().collect())
}

fn toml_value(v: &toml::Value) -> Value {
    match v {
        toml::Value::String(s) => Value::str(s),
        toml::Value::Integer(i) => Value::Int(*i),
        toml::Value::Boolean(b) => Value::Bool(*b),
        toml::Value::Array(a) => Value::list(a.iter().map(Value::str).collect()),
    }
}

/// Template values for every object of a site.
pub struct Context {
    /// The root variables shared by every rendering: `site`, `tags`, `pages`.
    pub base: Dict,
    /// Post objects, parallel to [`Site::posts`].
    pub posts: Vec<Value>,
    /// Page objects, parallel to [`Site::pages`].
    pub pages: Vec<Value>,
    /// Full tag objects, parallel to [`Site::tags`].
    pub tags: Vec<Value>,
    posts_per_page: usize,
    total_posts: usize,
    total_pages: usize,
}

impl Context {
    /// Build every shared value of `site`.
    pub fn new(site: &Site) -> Context {
        let site_value = Value::dict(
            site.config
                .table
                .iter()
                .map(|(k, v)| (k.to_string(), toml_value(v)))
                .collect(),
        );

        let tag_links: Vec<Value> = site
            .tags
            .iter()
            .map(|t| {
                dict([
                    ("name", Value::str(&t.name)),
                    ("slug", Value::str(&t.slug)),
                    ("url", Value::str(&t.url)),
                    ("post_count", Value::from(t.posts.len())),
                ])
            })
            .collect();

        let post_links: Vec<Value> = site
            .posts
            .iter()
            .map(|p| {
                dict([
                    ("title", Value::str(&p.title)),
                    ("slug", Value::str(&p.slug)),
                    ("url", Value::str(&p.url)),
                    ("permalink", Value::str(&p.permalink)),
                    ("date", Value::str(&p.date)),
                    ("date_long", Value::str(&p.date_long)),
                ])
            })
            .collect();

        let posts: Vec<Value> = site
            .posts
            .iter()
            .enumerate()
            .map(|(i, p)| {
                let newer = if i > 0 {
                    post_links[i - 1].clone()
                } else {
                    Value::None
                };
                let older = post_links.get(i + 1).cloned().unwrap_or(Value::None);
                dict([
                    ("title", Value::str(&p.title)),
                    ("slug", Value::str(&p.slug)),
                    ("url", Value::str(&p.url)),
                    ("permalink", Value::str(&p.permalink)),
                    ("date", Value::str(&p.date)),
                    ("date_long", Value::str(&p.date_long)),
                    (
                        "tags",
                        Value::list(p.tags.iter().map(|&t| tag_links[t].clone()).collect()),
                    ),
                    ("content", Value::str(&p.content)),
                    ("excerpt", Value::str(&p.excerpt)),
                    ("older", older),
                    ("newer", newer),
                ])
            })
            .collect();

        let tags: Vec<Value> = site
            .tags
            .iter()
            .map(|t| {
                dict([
                    ("name", Value::str(&t.name)),
                    ("slug", Value::str(&t.slug)),
                    ("url", Value::str(&t.url)),
                    ("post_count", Value::from(t.posts.len())),
                    (
                        "posts",
                        Value::list(t.posts.iter().map(|&p| posts[p].clone()).collect()),
                    ),
                ])
            })
            .collect();

        let pages: Vec<Value> = site
            .pages
            .iter()
            .map(|p| {
                dict([
                    ("title", Value::str(&p.title)),
                    ("slug", Value::str(&p.slug)),
                    ("url", Value::str(&p.url)),
                    ("permalink", Value::str(&p.permalink)),
                    ("content", Value::str(&p.content)),
                ])
            })
            .collect();

        let page_links: Vec<Value> = site
            .pages
            .iter()
            .map(|p| {
                dict([
                    ("title", Value::str(&p.title)),
                    ("slug", Value::str(&p.slug)),
                    ("url", Value::str(&p.url)),
                ])
            })
            .collect();

        let mut base = Dict::new();
        base.insert("site", site_value);
        base.insert("tags", Value::list(tag_links));
        base.insert("pages", Value::list(page_links));

        Context {
            base,
            posts,
            pages,
            tags,
            posts_per_page: site.config.posts_per_page,
            total_posts: site.posts.len(),
            total_pages: site.total_pages(),
        }
    }

    /// The root variables for the index page `number` (1-based).
    pub fn index_vars(&self, number: usize) -> Dict {
        let start = ((number - 1) * self.posts_per_page).min(self.posts.len());
        let end = (number * self.posts_per_page).min(self.posts.len());
        let url_of = |n: usize| index_url(n);
        let links = (1..=self.total_pages)
            .map(|n| {
                dict([
                    ("number", Value::from(n)),
                    ("url", Value::str(url_of(n))),
                    ("current", Value::Bool(n == number)),
                ])
            })
            .collect();
        let has_prev = number > 1;
        let has_next = number < self.total_pages;
        let pagination = dict([
            ("number", Value::from(number)),
            ("total_pages", Value::from(self.total_pages)),
            ("total_posts", Value::from(self.total_posts)),
            ("has_prev", Value::Bool(has_prev)),
            ("has_next", Value::Bool(has_next)),
            (
                "prev_url",
                if has_prev {
                    Value::str(url_of(number - 1))
                } else {
                    Value::None
                },
            ),
            (
                "next_url",
                if has_next {
                    Value::str(url_of(number + 1))
                } else {
                    Value::None
                },
            ),
            ("links", Value::list(links)),
        ]);
        let mut vars = self.base.clone();
        vars.insert("posts", Value::list(self.posts[start..end].to_vec()));
        vars.insert("pagination", pagination);
        vars
    }

    /// The root variables for the page of post number `index`.
    pub fn post_vars(&self, index: usize) -> Dict {
        let mut vars = self.base.clone();
        vars.insert("post", self.posts[index].clone());
        vars
    }

    /// The root variables for the page of page number `index`.
    pub fn page_vars(&self, index: usize) -> Dict {
        let mut vars = self.base.clone();
        vars.insert("page", self.pages[index].clone());
        vars
    }

    /// The root variables for the page of tag number `index`.
    pub fn tag_vars(&self, index: usize) -> Dict {
        let tag = self.tags[index].clone();
        let posts = match &tag {
            Value::Dict(d) => d.get("posts").cloned().unwrap_or(Value::Undefined),
            _ => Value::Undefined,
        };
        let mut vars = self.base.clone();
        vars.insert("tag", tag);
        vars.insert("posts", posts);
        vars
    }
}

/// The URL of index page `number`: `/` for the first, `/page/N/` otherwise.
pub fn index_url(number: usize) -> String {
    if number <= 1 {
        "/".to_string()
    } else {
        format!("/page/{}/", number)
    }
}
