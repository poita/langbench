//! The generation pipeline: load, model, render, emit.

use std::fs;
use std::path::{Path, PathBuf};

use crate::content::{self, Source};
use crate::context::{index_url, Context};
use crate::error::{Error, Result};
use crate::feed;
use crate::site::Site;
use crate::template::{Dict, Environment};

/// One file of the generated site.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Output {
    /// A generated text file.
    Text {
        /// Path relative to the output directory, using `/` separators.
        path: String,
        /// File contents.
        contents: String,
    },
    /// A static file copied byte for byte.
    Copy {
        /// Path relative to the output directory, using `/` separators.
        path: String,
        /// The file to copy.
        from: PathBuf,
    },
}

impl Output {
    /// The path relative to the output directory.
    pub fn path(&self) -> &str {
        match self {
            Output::Text { path, .. } | Output::Copy { path, .. } => path,
        }
    }
}

/// The five entry-point templates every site must have.
pub const ENTRY_TEMPLATES: [&str; 5] = [
    "index.html",
    "post.html",
    "page.html",
    "tag.html",
    "tags.html",
];

/// Build every output file of the site described by `source`.
pub fn build(source: &Source) -> Result<Vec<Output>> {
    let site = Site::new(source);
    let ctx = Context::new(&site);

    let mut env = Environment::new();
    for (name, src) in &source.templates {
        // Like Jinja2's default, one trailing newline is not part of a template.
        env.add_template(name.as_str(), src.strip_suffix('\n').unwrap_or(src));
    }

    let mut out = Vec::new();
    let mut render = |template: &str, vars: Dict, path: String| -> Result<()> {
        let contents = env
            .render(template, &vars)
            .map_err(|source| Error::Template {
                template: template.to_string(),
                page: path.clone(),
                source,
            })?;
        out.push(Output::Text { path, contents });
        Ok(())
    };

    for n in 1..=site.total_pages() {
        let path = if n == 1 {
            "index.html".to_string()
        } else {
            format!("{}index.html", index_url(n).trim_start_matches('/'))
        };
        render("index.html", ctx.index_vars(n), path)?;
    }
    for (i, p) in site.posts.iter().enumerate() {
        render(
            "post.html",
            ctx.post_vars(i),
            format!("posts/{}/index.html", p.slug),
        )?;
    }
    for (i, p) in site.pages.iter().enumerate() {
        render(
            "page.html",
            ctx.page_vars(i),
            format!("{}/index.html", p.slug),
        )?;
    }
    render("tags.html", ctx.base.clone(), "tags/index.html".to_string())?;
    for (i, t) in site.tags.iter().enumerate() {
        render(
            "tag.html",
            ctx.tag_vars(i),
            format!("tags/{}/index.html", t.slug),
        )?;
    }

    out.push(Output::Text {
        path: "feed.xml".into(),
        contents: feed::feed(&site),
    });
    out.push(Output::Text {
        path: "sitemap.xml".into(),
        contents: feed::sitemap(&site),
    });

    if let Some(dir) = &source.static_dir {
        collect_static(dir, "", &mut out)?;
    }
    Ok(out)
}

/// Collect every file under `dir` (dotfiles included), at any depth.
fn collect_static(dir: &Path, prefix: &str, out: &mut Vec<Output>) -> Result<()> {
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir).map_err(|e| Error::io(dir, e))? {
        let entry = entry.map_err(|e| Error::io(dir, e))?;
        entries.push((
            entry.file_name().to_string_lossy().into_owned(),
            entry.path(),
        ));
    }
    entries.sort();
    for (name, path) in entries {
        let rel = format!("{}{}", prefix, name);
        let meta = fs::metadata(&path).map_err(|e| Error::io(&path, e))?;
        if meta.is_dir() {
            collect_static(&path, &format!("{}/", rel), out)?;
        } else if meta.is_file() {
            out.push(Output::Copy {
                path: rel,
                from: path,
            });
        }
    }
    Ok(())
}

/// Write outputs below `output_dir`, creating directories as needed.
pub fn write(outputs: &[Output], output_dir: &Path) -> Result<()> {
    fs::create_dir_all(output_dir).map_err(|e| Error::io(output_dir, e))?;
    for o in outputs {
        let dest = output_dir.join(o.path());
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent).map_err(|e| Error::io(parent, e))?;
        }
        match o {
            Output::Text { contents, .. } => {
                fs::write(&dest, contents).map_err(|e| Error::io(&dest, e))?
            }
            Output::Copy { from, .. } => {
                fs::copy(from, &dest).map_err(|e| Error::io(&dest, e))?;
            }
        }
    }
    Ok(())
}

/// Generate the site in `input` into `output`: read the source, build every
/// file and write them.
pub fn generate(input: &Path, output: &Path) -> Result<()> {
    let source = content::load(input)?;
    let outputs = build(&source)?;
    write(&outputs, output)
}
