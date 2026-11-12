//! The content model: published posts, pages and tags, in the orders the
//! output requires, with Markdown already converted.

use std::collections::HashMap;

use crate::content::{Config, Source};
use crate::markdown;

/// A published post.
#[derive(Clone, Debug)]
pub struct Post {
    /// Title.
    pub title: String,
    /// Slug, used verbatim in the URL.
    pub slug: String,
    /// `YYYY-MM-DD`.
    pub date: String,
    /// `March 5, 2024`.
    pub date_long: String,
    /// `/posts/<slug>/`.
    pub url: String,
    /// `base_url` + `url`.
    pub permalink: String,
    /// Indices into [`Site::tags`], in the post's own tag order, repeats removed.
    pub tags: Vec<usize>,
    /// HTML of the whole body.
    pub content: String,
    /// HTML of the body's first block.
    pub excerpt: String,
}

/// A published page.
#[derive(Clone, Debug)]
pub struct Page {
    /// Title.
    pub title: String,
    /// Slug.
    pub slug: String,
    /// `/<slug>/`.
    pub url: String,
    /// `base_url` + `url`.
    pub permalink: String,
    /// HTML of the whole body.
    pub content: String,
}

/// A tag that at least one published post carries.
#[derive(Clone, Debug)]
pub struct Tag {
    /// The tag name as written.
    pub name: String,
    /// Slug derived from the name.
    pub slug: String,
    /// `/tags/<slug>/`.
    pub url: String,
    /// Indices into [`Site::posts`] in canonical order.
    pub posts: Vec<usize>,
}

/// The whole site, ready to be rendered.
#[derive(Clone, Debug)]
pub struct Site {
    /// The configuration.
    pub config: Config,
    /// Published posts in canonical order: newest first, ties by slug.
    pub posts: Vec<Post>,
    /// Published pages ordered by slug.
    pub pages: Vec<Page>,
    /// Existing tags ordered by slug.
    pub tags: Vec<Tag>,
}

/// The slug of a tag name: ASCII lower-cased, every other character that is
/// not `a-z` or `0-9` replaced by `-`, runs of `-` collapsed, and leading and
/// trailing `-` removed.
///
/// ```
/// assert_eq!(sitegen::site::tag_slug("Web Development"), "web-development");
/// assert_eq!(sitegen::site::tag_slug("C++"), "c");
/// ```
pub fn tag_slug(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    for c in name.chars() {
        let c = c.to_ascii_lowercase();
        let c = if c.is_ascii_lowercase() || c.is_ascii_digit() {
            c
        } else {
            '-'
        };
        if c == '-' && out.ends_with('-') {
            continue;
        }
        out.push(c);
    }
    out.trim_matches('-').to_string()
}

const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
];

/// Render `YYYY-MM-DD` as `<Month> <D>, <YYYY>`; anything that is not of that
/// shape is returned unchanged.
///
/// ```
/// assert_eq!(sitegen::site::date_long("2024-03-05"), "March 5, 2024");
/// ```
pub fn date_long(date: &str) -> String {
    let parts: Vec<&str> = date.split('-').collect();
    if let [y, m, d] = parts.as_slice() {
        if let (Ok(m), Ok(d)) = (m.parse::<usize>(), d.parse::<u32>()) {
            if (1..=12).contains(&m) {
                return format!("{} {}, {}", MONTHS[m - 1], d, y);
            }
        }
    }
    date.to_string()
}

/// The Markdown of a body's first block: skip leading blank lines, then take
/// the following run of non-blank lines.
///
/// The rule is purely textual and knows nothing about Markdown structure.
pub fn first_block(body: &str) -> String {
    let is_blank = |l: &&str| l.chars().all(|c| c == ' ' || c == '\t');
    let mut lines = body.split('\n').skip_while(|l| is_blank(l));
    let mut out = String::new();
    for (i, line) in lines.by_ref().take_while(|l| !is_blank(l)).enumerate() {
        if i > 0 {
            out.push('\n');
        }
        out.push_str(line);
    }
    out
}

impl Site {
    /// Build the model from a source: drop drafts, sort, collect tags and
    /// convert every body (and every excerpt) to HTML once.
    pub fn new(source: &Source) -> Site {
        let config = source.config.clone();

        let mut raw_posts: Vec<_> = source.posts.iter().filter(|p| !p.draft).collect();
        raw_posts.sort_by(|a, b| b.date.cmp(&a.date).then_with(|| a.slug.cmp(&b.slug)));

        // Collect tags in O(K + T log T): one pass over the posts in canonical
        // order, so each tag's post list is already in canonical order.
        let mut tag_ids: HashMap<&str, usize> = HashMap::new();
        let mut tags: Vec<Tag> = Vec::new();
        let mut posts = Vec::with_capacity(raw_posts.len());
        for (pi, p) in raw_posts.iter().enumerate() {
            let mut own: Vec<usize> = Vec::new();
            for name in &p.tags {
                let id = *tag_ids.entry(name.as_str()).or_insert_with(|| {
                    let slug = tag_slug(name);
                    tags.push(Tag {
                        name: name.clone(),
                        url: format!("/tags/{}/", slug),
                        slug,
                        posts: Vec::new(),
                    });
                    tags.len() - 1
                });
                if own.contains(&id) {
                    continue;
                }
                own.push(id);
                tags[id].posts.push(pi);
            }
            let url = format!("/posts/{}/", p.slug);
            posts.push(Post {
                title: p.title.clone(),
                slug: p.slug.clone(),
                date: p.date.clone(),
                date_long: date_long(&p.date),
                permalink: format!("{}{}", config.base_url, url),
                url,
                tags: own,
                content: markdown::to_html(&p.body),
                excerpt: markdown::to_html(&first_block(&p.body)),
            });
        }

        // Order the tags by slug, and renumber the posts' tag indices.
        let mut order: Vec<usize> = (0..tags.len()).collect();
        order.sort_by(|&a, &b| tags[a].slug.cmp(&tags[b].slug));
        let mut new_index = vec![0; tags.len()];
        for (new, &old) in order.iter().enumerate() {
            new_index[old] = new;
        }
        let mut slots: Vec<Option<Tag>> = tags.into_iter().map(Some).collect();
        let tags: Vec<Tag> = order
            .iter()
            .map(|&old| slots[old].take().unwrap())
            .collect();
        for p in &mut posts {
            for t in &mut p.tags {
                *t = new_index[*t];
            }
        }

        let mut raw_pages: Vec<_> = source.pages.iter().filter(|p| !p.draft).collect();
        raw_pages.sort_by(|a, b| a.slug.cmp(&b.slug));
        let pages = raw_pages
            .iter()
            .map(|p| {
                let url = format!("/{}/", p.slug);
                Page {
                    title: p.title.clone(),
                    slug: p.slug.clone(),
                    permalink: format!("{}{}", config.base_url, url),
                    url,
                    content: markdown::to_html(&p.body),
                }
            })
            .collect();

        Site {
            config,
            posts,
            pages,
            tags,
        }
    }

    /// The number of index pages: `max(1, ceil(posts / posts_per_page))`.
    pub fn total_pages(&self) -> usize {
        self.posts.len().div_ceil(self.config.posts_per_page).max(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs() {
        assert_eq!(tag_slug("Web Development"), "web-development");
        assert_eq!(tag_slug("C++"), "c");
        assert_eq!(tag_slug("Rust 2024"), "rust-2024");
        assert_eq!(tag_slug("--a__b--"), "a-b");
        assert_eq!(tag_slug("Ünï"), "n");
    }

    #[test]
    fn long_dates() {
        assert_eq!(date_long("2024-03-05"), "March 5, 2024");
        assert_eq!(date_long("1999-12-25"), "December 25, 1999");
        assert_eq!(date_long("0999-01-10"), "January 10, 0999");
    }

    #[test]
    fn excerpts() {
        assert_eq!(
            first_block("\n  \nPara one\nstill\n\nPara two\n"),
            "Para one\nstill"
        );
        assert_eq!(first_block("# Title\nmore"), "# Title\nmore");
        assert_eq!(first_block(" \t\n\n"), "");
        assert_eq!(first_block(""), "");
        assert_eq!(first_block("```\ncode\n\nmore\n```\n"), "```\ncode");
    }
}
