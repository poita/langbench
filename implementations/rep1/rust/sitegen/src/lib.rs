//! # sitegen
//!
//! A small static site generator. It reads a site source directory
//! (`site.toml`, Markdown content with TOML front matter, templates, static
//! files) and produces a complete static website: post pages, pages, tag
//! pages, paginated index pages, an Atom feed and a sitemap.
//!
//! The three languages involved are implemented from scratch in this crate,
//! using only the standard library:
//!
//! * [`markdown`]: a CommonMark-subset to HTML converter,
//! * [`template`]: a Jinja-style template engine,
//! * [`toml`]: a reader for the TOML subset used by configuration and
//!   front matter.
//!
//! The site generator proper is built on them:
//!
//! * [`content`] reads a source directory into a [`content::Source`],
//! * [`site`] turns it into a [`site::Site`] model (published posts in
//!   canonical order, pages, tags, HTML bodies),
//! * [`context`] builds the values templates see,
//! * [`feed`] writes `feed.xml` and `sitemap.xml`,
//! * [`mod@generate`] ties it together: [`generate::build`] produces the output
//!   files in memory and [`generate::write`] puts them on disk.
//!
//! ## Example
//!
//! ```
//! use sitegen::content::{parse_config, parse_page, parse_post, Source};
//! use sitegen::generate::{build, Output};
//!
//! let source = Source {
//!     config: parse_config(
//!         "title = \"Pond Notes\"\nbase_url = \"https://pond.example\"\nauthor = \"R. Duck\"\nposts_per_page = 5\n",
//!     )
//!     .unwrap(),
//!     posts: vec![parse_post(
//!         "hello.md",
//!         "+++\ntitle = \"Hello\"\ndate = \"2024-01-10\"\ntags = [\"Meta\"]\n+++\nThe **first** post.\n",
//!     )
//!     .unwrap()],
//!     pages: vec![parse_page("about.md", "+++\ntitle = \"About\"\n+++\nNothing here.\n").unwrap()],
//!     templates: [
//!         ("index.html", "{% for p in posts %}<a href=\"{{ p.url }}\">{{ p.title }}</a>{% endfor %}"),
//!         ("post.html", "<h1>{{ post.title }}</h1>{{ post.content }}"),
//!         ("page.html", "{{ page.content }}"),
//!         ("tag.html", "{{ tag.name }}: {{ tag.post_count }}"),
//!         ("tags.html", "{% for t in tags %}{{ t.name }} {% endfor %}"),
//!     ]
//!     .iter()
//!     .map(|(n, s)| (n.to_string(), s.to_string()))
//!     .collect(),
//!     static_dir: None,
//! };
//!
//! let outputs = build(&source).unwrap();
//! let get = |path: &str| {
//!     outputs.iter().find_map(|o| match o {
//!         Output::Text { path: p, contents } if p == path => Some(contents.as_str()),
//!         _ => None,
//!     })
//! };
//! assert_eq!(get("index.html"), Some("<a href=\"/posts/hello/\">Hello</a>"));
//! assert_eq!(get("posts/hello/index.html"), Some("<h1>Hello</h1><p>The <strong>first</strong> post.</p>\n"));
//! assert_eq!(get("tags/meta/index.html"), Some("Meta: 1"));
//! assert!(get("feed.xml").unwrap().contains("<updated>2024-01-10T00:00:00Z</updated>"));
//! ```

pub mod content;
pub mod context;
mod error;
pub mod feed;
pub mod generate;
pub mod markdown;
pub mod site;
pub mod template;
pub mod toml;

pub use error::{Error, Result};
pub use generate::generate;

/// Compiles and runs the Rust examples of the README as doctests.
#[cfg(doctest)]
#[doc = include_str!("../README.md")]
struct ReadmeDoctests;
