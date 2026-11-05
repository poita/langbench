/// sitegen: a static site generator.
///
/// The library is split by responsibility:
///
/// $(UL
///   $(LI `sitegen.markdown` - CommonMark-subset Markdown to HTML)
///   $(LI `sitegen.templating` - Jinja-style template engine)
///   $(LI `sitegen.toml` - the TOML subset of `site.toml` and front matter)
///   $(LI `sitegen.frontmatter`, `sitegen.model` - content files and the content model)
///   $(LI `sitegen.render`, `sitegen.feed` - template values, pages, feed and sitemap)
///   $(LI `sitegen.generator` - reading a site directory and writing the output)
/// )
module sitegen;

public import sitegen.feed;
public import sitegen.frontmatter;
public import sitegen.generator;
public import sitegen.markdown;
public import sitegen.model;
public import sitegen.render;
public import sitegen.source_;
public import sitegen.templating;
public import sitegen.toml;
