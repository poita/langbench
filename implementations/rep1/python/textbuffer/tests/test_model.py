"""Randomised comparison against a deliberately naive offset-based model."""

import random

from textbuffer import TextBuffer


class Model:
    """Straight transcription of SPEC.md on a flat string with offsets."""

    def __init__(self, text):
        self.s = text
        self.cur = [dict(h=0, a=None, p=True, g=0)]
        self.undo, self.redo = [], []

    def pos(self, off):
        before = self.s[:off]
        return before.count("\n"), off - (before.rfind("\n") + 1)

    def off(self, line, col):
        ls = self.s.split("\n")
        line = max(0, min(line, len(ls) - 1))
        col = max(0, min(col, len(ls[line])))
        return sum(len(x) + 1 for x in ls[:line]) + col

    @staticmethod
    def rng(c):
        if c["a"] is None:
            return c["h"], c["h"]
        return min(c["h"], c["a"]), max(c["h"], c["a"])

    def goals(self):
        for c in self.cur:
            c["g"] = self.pos(c["h"])[1]

    def norm(self):
        cs = sorted(self.cur, key=lambda c: (self.rng(c)[0], -self.rng(c)[1]))
        out = []
        for c in cs:
            if out:
                cu = out[-1]
                (cs_, ce), (s, e) = self.rng(cu), self.rng(c)
                sel = cu["a"] is not None and c["a"] is not None
                if (s < ce) if sel else (s <= ce):
                    ne = max(ce, e)
                    back = cu["a"] is not None and cu["h"] == cs_
                    if ne == cs_:
                        cu["h"], cu["a"] = ne, None
                    elif back:
                        cu["h"], cu["a"] = cs_, ne
                    else:
                        cu["h"], cu["a"] = ne, cs_
                    cu["p"] = cu["p"] or c["p"]
                    continue
            out.append(dict(c))
        self.cur = out

    def snap(self):
        return [(c["h"], c["a"], c["p"]) for c in self.cur]

    def load(self, snap):
        self.cur = [dict(h=h, a=a, p=p, g=0) for h, a, p in snap]

    def edit(self, kind, text=""):
        before = self.snap()
        old = self.s
        changed = False
        cs = list(self.cur)
        for i, c in enumerate(cs):
            s, e = self.rng(c)
            ins = text
            if s == e and kind == "del":
                if s == 0:
                    continue
                s, ins = s - 1, ""
            elif s == e and kind == "fwd":
                if e == len(self.s):
                    continue
                e, ins = e + 1, ""
            elif kind != "ins":
                ins = ""
            changed = changed or bool(ins) or e > s
            self.s = self.s[:s] + ins + self.s[e:]
            delta = s + len(ins) - e
            c["h"], c["a"] = s + len(ins), None
            for d in cs[i + 1:]:
                d["h"] += delta
                if d["a"] is not None:
                    d["a"] += delta
        self.goals()
        self.norm()
        if changed:  # a non-trivial replacement, even if the text is unchanged
            self.undo.append((before, self.snap(), old, self.s))
            self.redo.clear()

    def move(self, d, select):
        for c in self.cur:
            h = c["h"]
            line, col = self.pos(h)
            ls = self.s.split("\n")
            if not select and c["a"] is not None and d in ("left", "right"):
                s, e = self.rng(c)
                c["h"], c["a"] = (s if d == "left" else e), None
                continue
            a = c["a"] if select and c["a"] is not None else (h if select else None)
            if d == "left":
                nh = max(h - 1, 0)
            elif d == "right":
                nh = min(h + 1, len(self.s))
            elif d == "home":
                nh = self.off(line, 0)
            elif d == "end":
                nh = self.off(line, 10**9)
            elif d == "up":
                if line == 0:
                    nh, c["g"] = 0, 0
                else:
                    nh = self.off(line - 1, c["g"])
            else:
                if line == len(ls) - 1:
                    nh = len(self.s)
                    c["g"] = len(ls[-1])
                else:
                    nh = self.off(line + 1, c["g"])
            c["h"], c["a"] = nh, (None if a == nh else a)
        self.norm()
        if d not in ("up", "down"):
            self.goals()

    def do_undo(self):
        if self.undo:
            e = self.undo.pop()
            self.s = e[2]
            self.load(e[0])
            self.redo.append(e)
        self.goals()

    def do_redo(self):
        if self.redo:
            e = self.redo.pop()
            self.s = e[3]
            self.load(e[1])
            self.undo.append(e)
        self.goals()

    def state(self):
        out = []
        for c in self.cur:
            a = None if c["a"] is None else self.pos(c["a"])
            out.append((self.pos(c["h"]), a, c["p"], c["g"]))
        return self.s, out


def buf_state(buf):
    return buf.text, [(c.head, c.anchor, c.primary, c.goal) for c in buf.cursors]


def test_random_against_model():
    for seed in range(60):
        rnd = random.Random(seed)
        text = "\n".join("".join(rnd.choice("ab c") for _ in range(rnd.randint(0, 6))) for _ in range(rnd.randint(1, 5)))
        buf, model = TextBuffer(text), Model(text)
        for step in range(150):
            r = rnd.random()
            if r < 0.2:
                t = "".join(rnd.choice("xy\n") for _ in range(rnd.randint(1, 3)))
                buf.insert(t)
                model.edit("ins", t)
            elif r < 0.3:
                buf.delete()
                model.edit("del")
            elif r < 0.4:
                buf.delete_forward()
                model.edit("fwd")
            elif r < 0.65:
                d = rnd.choice(["left", "right", "up", "down", "home", "end"])
                sel = rnd.random() < 0.4
                buf.move(d, sel)
                model.move(d, sel)
            elif r < 0.75:
                l, c = rnd.randint(0, 6), rnd.randint(0, 8)
                buf.add_cursor(l, c)
                model.cur.append(dict(h=model.off(l, c), a=None, p=False, g=0))
                model.goals()
                model.norm()
            elif r < 0.78:
                l, c = rnd.randint(0, 6), rnd.randint(0, 8)
                buf.goto(l, c)
                model.cur = [dict(h=model.off(l, c), a=None, p=True, g=0)]
                model.goals()
            elif r < 0.81:
                buf.clear_cursors()
                model.cur = [c for c in model.cur if c["p"]]
                model.goals()
            elif r < 0.91:
                buf.undo()
                model.do_undo()
            else:
                buf.redo()
                model.do_redo()
            assert buf_state(buf) == model.state(), (seed, step)
