"""Command execution and the result blocks of SPEC.md §19."""

import tvalue as V
from tengine import Store, TessError
from tlang import parse


def _path_text(b):
    return b.decode("ascii")


def execute(store, cmd):
    """Run one parsed command; return (status text, payload lines)."""
    name = cmd.name
    if name == "begin":
        store.begin()
        return "ok begin", []
    if name == "commit":
        txn_id, frames = store.commit()
        return "ok commit %d frames %d" % (txn_id, frames), []
    if name == "rollback":
        store.rollback()
        return "ok rollback", []
    if name == "checkpoint":
        n = store.checkpoint()
        return "ok checkpoint pages %d" % n, []
    if name == "stat":
        return "ok stat", ["%s %d" % (k, v) for k, v in store.stat()]
    if name == "indexes":
        rows = store.list_indexes()
        payload = ["%d %s root %d entries %d" % (slot, _path_text(path), root, entries)
                   for slot, path, root, entries in rows]
        return "ok indexes %d" % len(rows), payload
    if name == "put":
        what = store.put(cmd.key, cmd.value)
        return "ok put %s" % what, []
    if name == "get":
        doc = store.get(cmd.key)
        return "ok get value", [V.render(doc)]
    if name == "delete":
        store.delete(cmd.key)
        return "ok delete removed", []
    if name == "update":
        store.update(cmd.key, cmd.segs, cmd.value)
        return "ok update updated", []
    if name == "unset":
        store.unset(cmd.key, cmd.segs)
        return "ok unset updated", []
    if name == "scan":
        rows = store.scan(cmd.frm, cmd.to, cmd.limit, cmd.reverse, cmd.keys)
        if cmd.keys:
            payload = [V.render_string(key) for key, _doc in rows]
        else:
            payload = ["%s = %s" % (V.render_string(key), V.render(doc))
                       for key, doc in rows]
        return "ok scan %d" % len(rows), payload
    if name == "find":
        plan, rows = store.find(cmd.pred, cmd.limit)
        plan_text = "scan" if plan is None else "index " + _path_text(plan)
        payload = ["%s = %s" % (V.render_string(key), V.render(doc))
                   for key, doc in rows]
        return "ok find %d plan %s" % (len(rows), plan_text), payload
    if name == "create index":
        n = store.create_index(cmd.path)
        return "ok create index %s entries %d" % (_path_text(cmd.path), n), []
    if name == "drop index":
        n = store.drop_index(cmd.path)
        return "ok drop index %s pages %d" % (_path_text(cmd.path), n), []
    raise AssertionError("unhandled command %r" % name)


def split_lines(text):
    """The command lines of commands.txt (§2.1): LF separated, with no empty
    final line when the file ends with LF."""
    if text == "":
        return []
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def run_script(store, text):
    """Run every command line; return the lines of results.txt."""
    out = []
    for number, line in enumerate(split_lines(text), 1):
        try:
            cmd = parse(line)
            status, payload = execute(store, cmd)
        except TessError as err:
            status, payload = "error %s" % err.kind, []
        out.append("[%d] %s" % (number, status))
        for p in payload:
            out.append("  " + p)
    store.end_of_script()
    return out


def run_directory(in_dir, out_dir):
    """The I/O contract of §2: read the input directory, write the three
    output files."""
    import os

    def read(name):
        path = os.path.join(in_dir, name)
        if not os.path.exists(path):
            return None
        with open(path, "rb") as f:
            return f.read()

    commands = read("commands.txt")
    if commands is None:
        commands = b""
    store = Store()
    store.open(read("main.tdb"), read("main.twal"))
    lines = run_script(store, commands.decode("utf-8", "surrogateescape"))
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    with open(os.path.join(out_dir, "results.txt"), "wb") as f:
        if lines:
            f.write(("\n".join(lines) + "\n").encode("utf-8", "surrogateescape"))
    with open(os.path.join(out_dir, "main.tdb"), "wb") as f:
        f.write(store.main_bytes())
    with open(os.path.join(out_dir, "main.twal"), "wb") as f:
        f.write(store.wal_bytes())
