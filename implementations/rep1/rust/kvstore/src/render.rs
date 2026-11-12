//! Formatting of result blocks (spec §19).

use crate::db::PutOutcome;
use crate::error::Result;
use crate::exec::Response;
use crate::value::render_string;

fn render_key(key: &[u8], out: &mut String) {
    render_string(&String::from_utf8_lossy(key), out);
}

/// Renders the block for command line number `line_no` (1-based): a status
/// line followed by indented payload lines, every line ending in LF.
pub fn render_block(line_no: usize, result: &Result<Response>) -> String {
    let mut out = format!("[{line_no}] ");
    let mut payload: Vec<String> = Vec::new();
    match result {
        Err(e) => out.push_str(&format!("error {}", e.name())),
        Ok(resp) => match resp {
            Response::Begin => out.push_str("ok begin"),
            Response::Commit { txn_id, frames } => out.push_str(&format!("ok commit {txn_id} frames {frames}")),
            Response::Rollback => out.push_str("ok rollback"),
            Response::Checkpoint { pages } => out.push_str(&format!("ok checkpoint pages {pages}")),
            Response::Put(PutOutcome::Created) => out.push_str("ok put created"),
            Response::Put(PutOutcome::Replaced) => out.push_str("ok put replaced"),
            Response::Get(v) => {
                out.push_str("ok get value");
                payload.push(v.render());
            }
            Response::Delete => out.push_str("ok delete removed"),
            Response::Update => out.push_str("ok update updated"),
            Response::Unset => out.push_str("ok unset updated"),
            Response::Scan(rows) => {
                out.push_str(&format!("ok scan {}", rows.len()));
                for (k, v) in rows {
                    let mut line = String::new();
                    render_key(k, &mut line);
                    if let Some(v) = v {
                        line.push_str(" = ");
                        v.render_into(&mut line);
                    }
                    payload.push(line);
                }
            }
            Response::Find(r) => {
                out.push_str(&format!("ok find {} plan {}", r.rows.len(), r.plan.describe()));
                for (k, v) in &r.rows {
                    let mut line = String::new();
                    render_key(k, &mut line);
                    line.push_str(" = ");
                    v.render_into(&mut line);
                    payload.push(line);
                }
            }
            Response::CreateIndex { path, entries } => {
                out.push_str(&format!("ok create index {path} entries {entries}"))
            }
            Response::DropIndex { path, pages } => out.push_str(&format!("ok drop index {path} pages {pages}")),
            Response::Indexes(list) => {
                out.push_str(&format!("ok indexes {}", list.len()));
                for i in list {
                    payload.push(format!("{} {} root {} entries {}", i.slot, i.path, i.root, i.entries));
                }
            }
            Response::Stat(s) => {
                out.push_str("ok stat");
                payload.push(format!("pages {}", s.pages));
                payload.push(format!("free {}", s.free));
                payload.push(format!("freehead {}", s.freehead));
                payload.push(format!("docs {}", s.docs));
                payload.push(format!("root {}", s.root));
                payload.push(format!("height {}", s.height));
                payload.push(format!("commits {}", s.commits));
                payload.push(format!("indexes {}", s.indexes));
                payload.push(format!("wal {}", s.wal));
            }
        },
    }
    out.push('\n');
    for line in payload {
        out.push_str("  ");
        out.push_str(&line);
        out.push('\n');
    }
    out
}
