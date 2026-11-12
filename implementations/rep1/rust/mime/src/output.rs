//! Rendering of the text dumps and writing of the output tree.

use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::Path;

use crate::checksum::adler32_hex;
use crate::mailbox::RawMessage;
use crate::message::{Message, ADDRESS_HEADERS};
use crate::part::Kind;

/// Escapes a string for the dump format (without surrounding quotes).
pub fn esc(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '"' => out.push_str("\\\""),
            c if (c as u32) < 0x20 || c as u32 == 0x7F || (0x80..=0x9F).contains(&(c as u32)) => {
                let _ = write!(out, "\\x{:02x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out
}

/// Escapes and double-quotes a string.
pub fn q(s: &str) -> String {
    format!("\"{}\"", esc(s))
}

/// Formats a message number as four decimal digits.
pub fn message_number(n: usize) -> String {
    format!("{n:04}")
}

/// Relative path of an attachment file below the output directory.
pub fn attachment_path(number: usize, part: usize) -> String {
    format!("parts/{}/{:03}.bin", message_number(number), part)
}

/// Renders the `messages/NNNN.txt` dump of message number `number`.
pub fn render_message(number: usize, source: &str, msg: &Message) -> String {
    let id = message_number(number);
    let mut s = String::new();

    let _ = write!(s, "[message]\nid {id}\nsource {}\n\n", q(source));

    s.push_str("[headers]\n");
    for f in msg.headers() {
        let _ = writeln!(s, "{}: {}", f.key(), q(&f.display_value()));
    }

    s.push_str("\n[addresses]\n");
    for name in ADDRESS_HEADERS {
        for (k, a) in msg.addresses(name).iter().enumerate() {
            let _ = writeln!(s, "{name} {k} display={} spec={}", q(&a.display), q(&a.spec));
        }
    }

    s.push_str("\n[date]\n");
    match msg.date() {
        None => s.push_str("none\n"),
        Some(d) => {
            let _ = writeln!(s, "raw {}", q(&d.raw));
            match d.parsed {
                None => s.push_str("valid no\n"),
                Some(p) => {
                    let _ = write!(
                        s,
                        "valid yes\nutc {}\noffset {}\nepoch {}\n",
                        p.utc(),
                        p.offset(),
                        p.epoch
                    );
                }
            }
        }
    }

    s.push_str("\n[structure]\n");
    for p in &msg.parts {
        let _ = write!(s, "{}{} {}", "  ".repeat(p.depth), p.index, p.media_type());
        if let Some(cs) = &p.charset {
            let _ = write!(s, " charset={cs}");
        }
        let _ = write!(s, " cte={}", p.encoding);
        if let Some(d) = &p.disposition {
            let _ = write!(s, " disposition={d}");
        }
        if let Some(f) = &p.filename {
            let _ = write!(s, " filename={}", q(f));
        }
        match &p.kind {
            Kind::Multipart { boundary, preamble, epilogue } => {
                let _ = write!(s, " boundary={} parts={} preamble={preamble}", q(boundary), p.children);
                match epilogue {
                    Some(n) => {
                        let _ = write!(s, " epilogue={n}");
                    }
                    None => s.push_str(" epilogue=none"),
                }
            }
            Kind::Message => {
                let _ = write!(s, " parts={}", p.children);
            }
            Kind::Leaf => {
                let _ = write!(
                    s,
                    " size={} adler32={} role={}",
                    p.content.len(),
                    adler32_hex(&p.content),
                    msg.role(p.index).unwrap_or("attachment")
                );
            }
        }
        s.push('\n');
    }

    s.push_str("\n[body]\n");
    for (label, index) in [("text", msg.text_body), ("html", msg.html_body)] {
        match index {
            None => {
                let _ = writeln!(s, "{label} none");
            }
            Some(i) => {
                let text = msg.parts[i].text.as_deref().unwrap_or("");
                let _ = writeln!(s, "{label} {i} chars {}", text.chars().count());
                let mut lines: Vec<&str> = text.split('\n').collect();
                if lines.last() == Some(&"") {
                    lines.pop();
                }
                for line in lines {
                    let _ = writeln!(s, "| {}", esc(line));
                }
            }
        }
    }

    s.push_str("\n[attachments]\n");
    for &i in &msg.attachments {
        let p = &msg.parts[i];
        let filename = p.filename.as_deref().map_or_else(|| "-".to_string(), q);
        let _ = writeln!(
            s,
            "{i} type={} filename={filename} size={} adler32={} file={}",
            p.media_type(),
            p.content.len(),
            adler32_hex(&p.content),
            attachment_path(number, i)
        );
    }
    s
}

/// Renders `summary.txt` for the parsed messages (with their source ids).
pub fn render_summary(items: &[(String, Message)]) -> String {
    let mut s = format!("messages {}\n", items.len());
    for (k, (source, m)) in items.iter().enumerate() {
        let idx = |o: Option<usize>| o.map_or_else(|| "-".to_string(), |i| i.to_string());
        let _ = writeln!(
            s,
            "{} source={} bytes={} parts={} attachments={} text={} html={}",
            message_number(k + 1),
            q(source),
            m.size,
            m.parts.len(),
            m.attachments.len(),
            idx(m.text_body),
            idx(m.html_body)
        );
    }
    s
}

/// Parses every message and writes the whole output tree into `out_dir`.
pub fn write_output(messages: &[RawMessage], out_dir: &Path) -> io::Result<()> {
    fs::create_dir_all(out_dir.join("messages"))?;
    let mut parsed = Vec::with_capacity(messages.len());
    for (k, raw) in messages.iter().enumerate() {
        let number = k + 1;
        let msg = Message::parse(&raw.data);
        fs::write(
            out_dir.join("messages").join(format!("{}.txt", message_number(number))),
            render_message(number, &raw.source, &msg),
        )?;
        if !msg.attachments.is_empty() {
            let dir = out_dir.join("parts").join(message_number(number));
            fs::create_dir_all(&dir)?;
            for &i in &msg.attachments {
                fs::write(dir.join(format!("{i:03}.bin")), &msg.parts[i].content)?;
            }
        }
        parsed.push((raw.source.clone(), msg));
    }
    fs::write(out_dir.join("summary.txt"), render_summary(&parsed))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn escaping() {
        assert_eq!(esc("a\\b\n\r\t\"\u{1}\u{7f}\u{85}é"), "a\\\\b\\n\\r\\t\\\"\\x01\\x7f\\x85é");
        assert_eq!(q("x"), "\"x\"");
    }
}
