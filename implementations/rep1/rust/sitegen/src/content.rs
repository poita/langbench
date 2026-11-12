//! Reading a site source directory: configuration, content files and
//! templates.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{Error, Result};
use crate::toml::{self, Table};

/// The site configuration (`site.toml`).
#[derive(Clone, Debug)]
pub struct Config {
    /// The site title.
    pub title: String,
    /// The absolute base URL, without a trailing `/`.
    pub base_url: String,
    /// The default author name.
    pub author: String,
    /// Posts per index page (at least 1).
    pub posts_per_page: usize,
    /// The whole parsed document, in file order.
    pub table: Table,
}

/// A post as read from `content/posts`, drafts included.
#[derive(Clone, Debug)]
pub struct RawPost {
    /// Post title.
    pub title: String,
    /// URL slug (the `slug` key or the file name without `.md`).
    pub slug: String,
    /// Date as `YYYY-MM-DD`.
    pub date: String,
    /// Tag names in front-matter order, possibly with repeats.
    pub tags: Vec<String>,
    /// Whether the post is a draft.
    pub draft: bool,
    /// The Markdown body.
    pub body: String,
}

/// A page as read from `content/pages`, drafts included.
#[derive(Clone, Debug)]
pub struct RawPage {
    /// Page title.
    pub title: String,
    /// URL slug.
    pub slug: String,
    /// Whether the page is a draft.
    pub draft: bool,
    /// The Markdown body.
    pub body: String,
}

/// Everything read from a source directory.
#[derive(Clone, Debug)]
pub struct Source {
    /// `site.toml`.
    pub config: Config,
    /// Posts, in unspecified order.
    pub posts: Vec<RawPost>,
    /// Pages, in unspecified order.
    pub pages: Vec<RawPage>,
    /// Templates as `(file name, source)` pairs, source exactly as on disk.
    pub templates: Vec<(String, String)>,
    /// The `static` directory, if it exists.
    pub static_dir: Option<PathBuf>,
}

/// Split a content file into its front matter and body.
///
/// The file must start with `+++\n`; the front matter ends at the first
/// later line that is exactly `+++`.
pub fn split_front_matter(text: &str) -> Option<(&str, &str)> {
    let rest = text.strip_prefix("+++\n")?;
    let mut pos = 0;
    while pos <= rest.len() {
        let end = rest[pos..].find('\n').map_or(rest.len(), |i| pos + i);
        if &rest[pos..end] == "+++" {
            let body_start = (end + 1).min(rest.len());
            return Some((&rest[..pos], &rest[body_start..]));
        }
        if end >= rest.len() {
            break;
        }
        pos = end + 1;
    }
    None
}

fn read_to_string(path: &Path) -> Result<String> {
    fs::read_to_string(path).map_err(|e| Error::io(path, e))
}

fn parse_toml(file: &str, src: &str) -> Result<Table> {
    toml::parse(src).map_err(|e| Error::Toml {
        file: file.to_string(),
        line: e.line,
        message: e.message,
    })
}

fn required_string(table: &Table, file: &str, key: &str) -> Result<String> {
    match table.get(key) {
        Some(toml::Value::String(s)) => Ok(s.clone()),
        Some(_) => Err(Error::content(file, format!("`{}` must be a string", key))),
        None => Err(Error::content(
            file,
            format!("missing required key `{}`", key),
        )),
    }
}

fn optional_string(table: &Table, file: &str, key: &str) -> Result<Option<String>> {
    match table.get(key) {
        Some(toml::Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(Error::content(file, format!("`{}` must be a string", key))),
        None => Ok(None),
    }
}

fn optional_bool(table: &Table, file: &str, key: &str) -> Result<bool> {
    match table.get(key) {
        Some(toml::Value::Boolean(b)) => Ok(*b),
        Some(_) => Err(Error::content(file, format!("`{}` must be a boolean", key))),
        None => Ok(false),
    }
}

/// Parse the contents of `site.toml`.
pub fn parse_config(src: &str) -> Result<Config> {
    let file = "site.toml";
    let table = parse_toml(file, src)?;
    let title = required_string(&table, file, "title")?;
    let base_url = required_string(&table, file, "base_url")?;
    let author = required_string(&table, file, "author")?;
    let posts_per_page = match table.get("posts_per_page") {
        Some(toml::Value::Integer(n)) if *n >= 1 => *n as usize,
        Some(_) => {
            return Err(Error::content(
                file,
                "`posts_per_page` must be an integer of at least 1",
            ));
        }
        None => {
            return Err(Error::content(
                file,
                "missing required key `posts_per_page`",
            ))
        }
    };
    Ok(Config {
        title,
        base_url,
        author,
        posts_per_page,
        table,
    })
}

fn split_content<'a>(file: &str, text: &'a str) -> Result<(Table, &'a str)> {
    let (fm, body) = split_front_matter(text)
        .ok_or_else(|| Error::content(file, "missing or unterminated front matter"))?;
    Ok((parse_toml(file, fm)?, body))
}

fn default_slug(file_name: &str) -> String {
    file_name
        .strip_suffix(".md")
        .unwrap_or(file_name)
        .to_string()
}

/// Parse a post file. `file_name` is used for the default slug.
pub fn parse_post(file_name: &str, text: &str) -> Result<RawPost> {
    let (table, body) = split_content(file_name, text)?;
    let tags = match table.get("tags") {
        Some(toml::Value::Array(a)) => a.clone(),
        Some(_) => {
            return Err(Error::content(
                file_name,
                "`tags` must be an array of strings",
            ))
        }
        None => Vec::new(),
    };
    Ok(RawPost {
        title: required_string(&table, file_name, "title")?,
        date: required_string(&table, file_name, "date")?,
        slug: optional_string(&table, file_name, "slug")?
            .unwrap_or_else(|| default_slug(file_name)),
        tags,
        draft: optional_bool(&table, file_name, "draft")?,
        body: body.to_string(),
    })
}

/// Parse a page file. `file_name` is used for the default slug.
pub fn parse_page(file_name: &str, text: &str) -> Result<RawPage> {
    let (table, body) = split_content(file_name, text)?;
    Ok(RawPage {
        title: required_string(&table, file_name, "title")?,
        slug: optional_string(&table, file_name, "slug")?
            .unwrap_or_else(|| default_slug(file_name)),
        draft: optional_bool(&table, file_name, "draft")?,
        body: body.to_string(),
    })
}

/// The regular files directly inside `dir` whose names end with `suffix`,
/// sorted by name. A missing directory yields none.
fn list_files(dir: &Path, suffix: &str) -> Result<Vec<(String, PathBuf)>> {
    let rd = match fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(Error::io(dir, e)),
    };
    let mut files = Vec::new();
    for entry in rd {
        let entry = entry.map_err(|e| Error::io(dir, e))?;
        let name = match entry.file_name().into_string() {
            Ok(n) => n,
            Err(_) => continue,
        };
        if !name.ends_with(suffix) {
            continue;
        }
        let path = entry.path();
        let is_file = fs::metadata(&path).map(|m| m.is_file()).unwrap_or(false);
        if is_file {
            files.push((name, path));
        }
    }
    files.sort();
    Ok(files)
}

/// Read a site source directory.
pub fn load(input: &Path) -> Result<Source> {
    let config = parse_config(&read_to_string(&input.join("site.toml"))?)?;

    let mut posts = Vec::new();
    for (name, path) in list_files(&input.join("content").join("posts"), ".md")? {
        posts.push(parse_post(&name, &read_to_string(&path)?)?);
    }
    let mut pages = Vec::new();
    for (name, path) in list_files(&input.join("content").join("pages"), ".md")? {
        pages.push(parse_page(&name, &read_to_string(&path)?)?);
    }
    let mut templates = Vec::new();
    for (name, path) in list_files(&input.join("templates"), ".html")? {
        templates.push((name, read_to_string(&path)?));
    }
    let static_dir = input.join("static");
    let static_dir = if static_dir.is_dir() {
        Some(static_dir)
    } else {
        None
    };
    Ok(Source {
        config,
        posts,
        pages,
        templates,
        static_dir,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn front_matter_splitting() {
        assert_eq!(
            split_front_matter("+++\na = 1\n+++\nbody\n"),
            Some(("a = 1\n", "body\n"))
        );
        assert_eq!(split_front_matter("+++\na = 1\n+++"), Some(("a = 1\n", "")));
        assert_eq!(split_front_matter("+++\n+++\n"), Some(("", "")));
        // A `+++` that is part of a longer line, or of a string, ends nothing.
        assert_eq!(
            split_front_matter("+++\na = \"x +++\"\n+++ \n++++\n+++\n+++\n"),
            Some(("a = \"x +++\"\n+++ \n++++\n", "+++\n"))
        );
        assert_eq!(split_front_matter("+++\na = 1\n"), None);
        assert_eq!(split_front_matter("++\n"), None);
    }

    #[test]
    fn post_defaults() {
        let p = parse_post(
            "hello-world.md",
            "+++\ntitle = \"Hi\"\ndate = \"2024-01-02\"\n+++\nBody",
        )
        .unwrap();
        assert_eq!(p.slug, "hello-world");
        assert!(p.tags.is_empty());
        assert!(!p.draft);
        assert_eq!(p.body, "Body");
        let p = parse_post("x.md", "+++\ntitle = \"Hi\"\ndate = \"2024-01-02\"\nslug = \"s\"\ndraft = true\ntags = [\"a\", \"b\"]\n+++\n").unwrap();
        assert_eq!(
            (p.slug.as_str(), p.draft, p.tags.len(), p.body.as_str()),
            ("s", true, 2, "")
        );
    }

    #[test]
    fn missing_keys_are_errors() {
        assert!(parse_post("x.md", "+++\ntitle = \"Hi\"\n+++\n").is_err());
        assert!(parse_page("x.md", "+++\n+++\n").is_err());
        assert!(parse_config("title = \"t\"\n").is_err());
        assert!(
            parse_config("title=\"t\"\nbase_url=\"u\"\nauthor=\"a\"\nposts_per_page=0\n").is_err()
        );
    }
}
