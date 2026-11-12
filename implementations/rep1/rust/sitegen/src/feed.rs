//! `feed.xml` (Atom 1.0) and `sitemap.xml`.

use crate::context::index_url;
use crate::site::Site;

/// Escape `&`, `<` and `>`.
fn text(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Escape `&`, `<`, `>` and `"`.
fn attr(s: &str) -> String {
    text(s).replace('"', "&quot;")
}

/// The Atom feed: the first `posts_per_page` posts in canonical order.
///
/// The `updated` timestamp is the date of the newest post (or the epoch when
/// there is none), so the output never depends on the clock.
pub fn feed(site: &Site) -> String {
    let base = &site.config.base_url;
    let updated = match site.posts.first() {
        Some(p) => format!("{}T00:00:00Z", p.date),
        None => "1970-01-01T00:00:00Z".to_string(),
    };
    let mut out = String::new();
    out.push_str("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    out.push_str("<feed xmlns=\"http://www.w3.org/2005/Atom\">\n");
    out.push_str(&format!("  <title>{}</title>\n", text(&site.config.title)));
    out.push_str(&format!("  <id>{}</id>\n", text(&format!("{}/", base))));
    out.push_str(&format!("  <updated>{}</updated>\n", updated));
    out.push_str(&format!(
        "  <link href=\"{}\" rel=\"alternate\"/>\n",
        attr(&format!("{}/", base))
    ));
    out.push_str(&format!(
        "  <link href=\"{}\" rel=\"self\"/>\n",
        attr(&format!("{}/feed.xml", base))
    ));
    out.push_str("  <author>\n");
    out.push_str(&format!("    <name>{}</name>\n", text(&site.config.author)));
    out.push_str("  </author>\n");
    for p in site.posts.iter().take(site.config.posts_per_page) {
        out.push_str("  <entry>\n");
        out.push_str(&format!("    <title>{}</title>\n", text(&p.title)));
        out.push_str(&format!("    <id>{}</id>\n", text(&p.permalink)));
        out.push_str(&format!("    <updated>{}T00:00:00Z</updated>\n", p.date));
        out.push_str(&format!(
            "    <link href=\"{}\" rel=\"alternate\"/>\n",
            attr(&p.permalink)
        ));
        out.push_str(&format!(
            "    <content type=\"html\">{}</content>\n",
            text(&p.content)
        ));
        out.push_str("  </entry>\n");
    }
    out.push_str("</feed>\n");
    out
}

/// The sitemap: index pages, posts (with `lastmod`), pages, the tag index
/// and every tag.
pub fn sitemap(site: &Site) -> String {
    let base = &site.config.base_url;
    let mut out = String::new();
    out.push_str("<?xml version=\"1.0\" encoding=\"utf-8\"?>\n");
    out.push_str("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">\n");
    let url = |out: &mut String, loc: &str, lastmod: Option<&str>| {
        out.push_str("  <url>\n");
        out.push_str(&format!("    <loc>{}</loc>\n", text(loc)));
        if let Some(d) = lastmod {
            out.push_str(&format!("    <lastmod>{}</lastmod>\n", d));
        }
        out.push_str("  </url>\n");
    };
    for n in 1..=site.total_pages() {
        url(&mut out, &format!("{}{}", base, index_url(n)), None);
    }
    for p in &site.posts {
        url(&mut out, &p.permalink, Some(&p.date));
    }
    for p in &site.pages {
        url(&mut out, &p.permalink, None);
    }
    url(&mut out, &format!("{}/tags/", base), None);
    for t in &site.tags {
        url(&mut out, &format!("{}{}", base, t.url), None);
    }
    out.push_str("</urlset>\n");
    out
}
