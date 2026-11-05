#!/usr/bin/env python3
"""SVG subset rasteriser.

Usage: main.py <input directory> <output directory>

The input directory holds a render.txt listing "<file>.svg WIDTH HEIGHT" per
line; each named SVG is rendered at that pixel size, composited over opaque
white and written to <output>/<file>.ppm as a binary PPM (P6).
"""
import math
import os
import re
import sys

# ---------------------------------------------------------------------------
# XML
# ---------------------------------------------------------------------------


class Element:
    __slots__ = ('tag', 'attrs', 'children')

    def __init__(self, tag, attrs):
        self.tag = tag
        self.attrs = attrs
        self.children = []


_ENTITIES = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"}
_ATTR_RE = re.compile(r'([^\s=/>]+)\s*=\s*("([^"]*)"|\'([^\']*)\')\s*')


def unescape(text):
    if '&' not in text:
        return text
    out = []
    i = 0
    while True:
        j = text.find('&', i)
        if j < 0:
            out.append(text[i:])
            break
        out.append(text[i:j])
        k = text.find(';', j)
        if k < 0:
            out.append(text[j:])
            break
        name = text[j + 1:k]
        if name.startswith('#x') or name.startswith('#X'):
            out.append(chr(int(name[2:], 16)))
        elif name.startswith('#'):
            out.append(chr(int(name[1:])))
        elif name in _ENTITIES:
            out.append(_ENTITIES[name])
        else:
            out.append(text[j:k + 1])
        i = k + 1
    return ''.join(out)


def local_name(name):
    return name.split(':')[-1]


def parse_xml(text):
    """Return the root Element of an XML document (elements and attributes only)."""
    n = len(text)
    i = 0
    root = None
    stack = []
    while i < n:
        lt = text.find('<', i)
        if lt < 0:
            break
        i = lt
        if text.startswith('<!--', i):
            end = text.find('-->', i + 4)
            i = n if end < 0 else end + 3
            continue
        if text.startswith('<?', i):
            end = text.find('?>', i + 2)
            i = n if end < 0 else end + 2
            continue
        if text.startswith('<![CDATA[', i):
            end = text.find(']]>', i + 9)
            i = n if end < 0 else end + 3
            continue
        if text.startswith('<!', i):
            depth = 0
            j = i + 2
            while j < n:
                c = text[j]
                if c == '[':
                    depth += 1
                elif c == ']':
                    depth -= 1
                elif c == '>' and depth <= 0:
                    break
                j += 1
            i = j + 1
            continue
        if text.startswith('</', i):
            end = text.find('>', i)
            if end < 0:
                break
            if stack:
                stack.pop()
            i = end + 1
            continue
        # start tag
        j = i + 1
        while j < n and text[j] not in ' \t\r\n/>':
            j += 1
        tag = local_name(text[i + 1:j])
        # find the end of the tag, honouring quoted attribute values
        k = j
        quote = ''
        while k < n:
            c = text[k]
            if quote:
                if c == quote:
                    quote = ''
            elif c in '"\'':
                quote = c
            elif c == '>':
                break
            k += 1
        body = text[j:k]
        selfclose = body.rstrip().endswith('/')
        if selfclose:
            body = body.rstrip()[:-1]
        attrs = {}
        for m in _ATTR_RE.finditer(body):
            value = m.group(3) if m.group(3) is not None else m.group(4)
            attrs[local_name(m.group(1))] = unescape(value)
        el = Element(tag, attrs)
        if stack:
            stack[-1].children.append(el)
        elif root is None:
            root = el
        if not selfclose:
            stack.append(el)
        i = k + 1
    return root


# ---------------------------------------------------------------------------
# Numbers, colours, transforms, style
# ---------------------------------------------------------------------------

NUM_RE = re.compile(r'[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?')


def numbers(text):
    return [float(m.group(0)) for m in NUM_RE.finditer(text)]


def parse_length(text, default=0.0):
    """A coordinate or length: a number with an optional 'px' unit."""
    if text is None:
        return default
    m = NUM_RE.match(text.strip())
    if not m:
        return default
    return float(m.group(0))


NAMED_COLORS = {}


def _load_named_colors():
    table = (
        "aliceblue f0f8ff antiquewhite faebd7 aqua 00ffff aquamarine 7fffd4 azure f0ffff "
        "beige f5f5dc bisque ffe4c4 black 000000 blanchedalmond ffebcd blue 0000ff "
        "blueviolet 8a2be2 brown a52a2a burlywood deb887 cadetblue 5f9ea0 chartreuse 7fff00 "
        "chocolate d2691e coral ff7f50 cornflowerblue 6495ed cornsilk fff8dc crimson dc143c "
        "cyan 00ffff darkblue 00008b darkcyan 008b8b darkgoldenrod b8860b darkgray a9a9a9 "
        "darkgreen 006400 darkgrey a9a9a9 darkkhaki bdb76b darkmagenta 8b008b "
        "darkolivegreen 556b2f darkorange ff8c00 darkorchid 9932cc darkred 8b0000 "
        "darksalmon e9967a darkseagreen 8fbc8f darkslateblue 483d8b darkslategray 2f4f4f "
        "darkslategrey 2f4f4f darkturquoise 00ced1 darkviolet 9400d3 deeppink ff1493 "
        "deepskyblue 00bfff dimgray 696969 dimgrey 696969 dodgerblue 1e90ff firebrick b22222 "
        "floralwhite fffaf0 forestgreen 228b22 fuchsia ff00ff gainsboro dcdcdc "
        "ghostwhite f8f8ff gold ffd700 goldenrod daa520 gray 808080 grey 808080 green 008000 "
        "greenyellow adff2f honeydew f0fff0 hotpink ff69b4 indianred cd5c5c indigo 4b0082 "
        "ivory fffff0 khaki f0e68c lavender e6e6fa lavenderblush fff0f5 lawngreen 7cfc00 "
        "lemonchiffon fffacd lightblue add8e6 lightcoral f08080 lightcyan e0ffff "
        "lightgoldenrodyellow fafad2 lightgray d3d3d3 lightgreen 90ee90 lightgrey d3d3d3 "
        "lightpink ffb6c1 lightsalmon ffa07a lightseagreen 20b2aa lightskyblue 87cefa "
        "lightslategray 778899 lightslategrey 778899 lightsteelblue b0c4de lightyellow ffffe0 "
        "lime 00ff00 limegreen 32cd32 linen faf0e6 magenta ff00ff maroon 800000 "
        "mediumaquamarine 66cdaa mediumblue 0000cd mediumorchid ba55d3 mediumpurple 9370db "
        "mediumseagreen 3cb371 mediumslateblue 7b68ee mediumspringgreen 00fa9a "
        "mediumturquoise 48d1cc mediumvioletred c71585 midnightblue 191970 mintcream f5fffa "
        "mistyrose ffe4e1 moccasin ffe4b5 navajowhite ffdead navy 000080 oldlace fdf5e6 "
        "olive 808000 olivedrab 6b8e23 orange ffa500 orangered ff4500 orchid da70d6 "
        "palegoldenrod eee8aa palegreen 98fb98 paleturquoise afeeee palevioletred db7093 "
        "papayawhip ffefd5 peachpuff ffdab9 peru cd853f pink ffc0cb plum dda0dd "
        "powderblue b0e0e6 purple 800080 red ff0000 rosybrown bc8f8f royalblue 4169e1 "
        "saddlebrown 8b4513 salmon fa8072 sandybrown f4a460 seagreen 2e8b57 seashell fff5ee "
        "sienna a0522d silver c0c0c0 skyblue 87ceeb slateblue 6a5acd slategray 708090 "
        "slategrey 708090 snow fffafa springgreen 00ff7f steelblue 4682b4 tan d2b48c "
        "teal 008080 thistle d8bfd8 tomato ff6347 turquoise 40e0d0 violet ee82ee "
        "wheat f5deb3 white ffffff whitesmoke f5f5f5 yellow ffff00 yellowgreen 9acd32"
    ).split()
    for i in range(0, len(table), 2):
        h = table[i + 1]
        NAMED_COLORS[table[i]] = (int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0,
                                  int(h[4:6], 16) / 255.0)


_load_named_colors()


def parse_color(text, current_color):
    """Return an (r, g, b) triple of floats in [0, 1], or None for 'none'."""
    s = text.strip()
    low = s.lower()
    if low == 'none':
        return None
    if low == 'currentcolor':
        return current_color
    if s.startswith('#'):
        h = s[1:]
        if len(h) == 3:
            return (int(h[0] * 2, 16) / 255.0, int(h[1] * 2, 16) / 255.0, int(h[2] * 2, 16) / 255.0)
        return (int(h[0:2], 16) / 255.0, int(h[2:4], 16) / 255.0, int(h[4:6], 16) / 255.0)
    if low.startswith('rgb'):
        body = s[s.index('(') + 1:s.rindex(')')]
        parts = [p.strip() for p in re.split(r'[\s,]+', body.strip()) if p.strip()]
        vals = []
        for p in parts[:3]:
            if p.endswith('%'):
                v = min(100.0, max(0.0, float(p[:-1]))) * 255.0 / 100.0
            else:
                v = min(255.0, max(0.0, float(p)))
            vals.append(math.floor(v + 0.5) / 255.0)
        return tuple(vals)
    return NAMED_COLORS.get(low, (0.0, 0.0, 0.0))


def parse_opacity(text, default=1.0):
    """An opacity value: a number, or a number followed by '%'.

    A value that is not one of those is the property's initial value.
    """
    s = text.strip()
    m = NUM_RE.match(s)
    if not m or s[m.end():].strip() not in ('', '%'):
        return default
    v = float(m.group(0))
    if s[m.end():].strip() == '%':
        v /= 100.0
    return max(0.0, min(1.0, v))


IDENTITY = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)


def mat_mul(m, n):
    """Return the matrix that applies n first and then m."""
    a1, b1, c1, d1, e1, f1 = m
    a2, b2, c2, d2, e2, f2 = n
    return (a1 * a2 + c1 * b2,
            b1 * a2 + d1 * b2,
            a1 * c2 + c1 * d2,
            b1 * c2 + d1 * d2,
            a1 * e2 + c1 * f2 + e1,
            b1 * e2 + d1 * f2 + f1)


def mat_apply(m, x, y):
    a, b, c, d, e, f = m
    return (a * x + c * y + e, b * x + d * y + f)


def mat_scale(m):
    """An upper bound on the length change the matrix applies to a vector."""
    a, b, c, d = m[0], m[1], m[2], m[3]
    return math.sqrt(max(a * a + b * b, c * c + d * d))


TRANSFORM_RE = re.compile(r'([a-zA-Z]+)\s*\(([^)]*)\)')


def parse_transform(text):
    m = IDENTITY
    for match in TRANSFORM_RE.finditer(text):
        name = match.group(1).strip()
        args = numbers(match.group(2))
        if name == 'matrix':
            if len(args) < 6:
                continue
            t = tuple(args[:6])
        elif name == 'translate':
            if not args:
                continue
            t = (1.0, 0.0, 0.0, 1.0, args[0], args[1] if len(args) > 1 else 0.0)
        elif name == 'scale':
            if not args:
                continue
            sx = args[0]
            sy = args[1] if len(args) > 1 else sx
            t = (sx, 0.0, 0.0, sy, 0.0, 0.0)
        elif name == 'rotate':
            if not args:
                continue
            ang = math.radians(args[0])
            cos, sin = math.cos(ang), math.sin(ang)
            t = (cos, sin, -sin, cos, 0.0, 0.0)
            if len(args) >= 3:
                cx, cy = args[1], args[2]
                t = mat_mul(mat_mul((1.0, 0.0, 0.0, 1.0, cx, cy), t),
                            (1.0, 0.0, 0.0, 1.0, -cx, -cy))
        elif name == 'skewX':
            if not args:
                continue
            t = (1.0, 0.0, math.tan(math.radians(args[0])), 1.0, 0.0, 0.0)
        elif name == 'skewY':
            if not args:
                continue
            t = (1.0, math.tan(math.radians(args[0])), 0.0, 1.0, 0.0, 0.0)
        else:
            continue
        m = mat_mul(m, t)
    return m


def parse_style(text):
    out = {}
    for decl in text.split(';'):
        if ':' not in decl:
            continue
        key, _, value = decl.partition(':')
        key = key.strip().lower()
        value = value.strip()
        if key and value:
            out[key] = value
    return out


# ---------------------------------------------------------------------------
# Path construction
# ---------------------------------------------------------------------------
#
# A path is a flat list of commands in user units:
#   ('M', x, y) ('L', x, y) ('C', x1, y1, x2, y2, x, y) ('Z',)

class PathScanner:
    """A tokeniser for path data that knows which tokens are arc flags.

    Arc flags are single characters, so "a5 5 0 0110 10" means flags 0 and 1
    followed by the number 10; a plain number scan would read "0110" instead.
    """

    __slots__ = ('s', 'i', 'n')

    def __init__(self, s):
        self.s = s
        self.i = 0
        self.n = len(s)

    def skip(self):
        s, n = self.s, self.n
        i = self.i
        while i < n and s[i] in ' \t\r\n\f,':
            i += 1
        self.i = i

    def command(self):
        """Return the next command letter, or None when the next token is not one."""
        self.skip()
        if self.i < self.n and self.s[self.i] in 'MmLlHhVvCcSsQqTtAaZz':
            c = self.s[self.i]
            self.i += 1
            return c
        return None

    def number(self):
        """Return the next number, or None when the next token is not one."""
        self.skip()
        s, n = self.s, self.n
        i = start = self.i
        if i < n and s[i] in '+-':
            i += 1
        digits = False
        while i < n and s[i].isdigit():
            i += 1
            digits = True
        if i < n and s[i] == '.':
            i += 1
            while i < n and s[i].isdigit():
                i += 1
                digits = True
        if not digits:
            return None
        if i < n and s[i] in 'eE':
            j = i + 1
            if j < n and s[j] in '+-':
                j += 1
            if j < n and s[j].isdigit():
                while j < n and s[j].isdigit():
                    j += 1
                i = j
        self.i = i
        return float(s[start:i])

    def flag(self):
        """Return the next arc flag as 0.0 or 1.0, or None when there is none."""
        self.skip()
        if self.i < self.n and self.s[self.i] in '01':
            v = 1.0 if self.s[self.i] == '1' else 0.0
            self.i += 1
            return v
        return None


def arc_to_cubics(x0, y0, rx, ry, phi_deg, large_arc, sweep, x1, y1):
    """Convert an endpoint-parameterised elliptical arc to a list of cubic segments.

    Returns a list of (c1x, c1y, c2x, c2y, x, y) tuples; an empty list means the
    arc degenerates to nothing (the endpoints coincide).
    """
    if x0 == x1 and y0 == y1:
        return []
    rx, ry = abs(rx), abs(ry)
    if rx == 0.0 or ry == 0.0:
        return [(x0, y0, x1, y1, x1, y1)]
    phi = math.radians(phi_deg % 360.0)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    dx2 = (x0 - x1) / 2.0
    dy2 = (y0 - y1) / 2.0
    x1p = cos_phi * dx2 + sin_phi * dy2
    y1p = -sin_phi * dx2 + cos_phi * dy2
    lam = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
    if lam > 1.0:
        s = math.sqrt(lam)
        rx *= s
        ry *= s
    num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
    den = rx * rx * y1p * y1p + ry * ry * x1p * x1p
    if den == 0.0:
        return [(x0, y0, x1, y1, x1, y1)]
    coef = math.sqrt(max(0.0, num / den))
    if large_arc == sweep:
        coef = -coef
    cxp = coef * rx * y1p / ry
    cyp = -coef * ry * x1p / rx
    cx = cos_phi * cxp - sin_phi * cyp + (x0 + x1) / 2.0
    cy = sin_phi * cxp + cos_phi * cyp + (y0 + y1) / 2.0
    ux = (x1p - cxp) / rx
    uy = (y1p - cyp) / ry
    vx = (-x1p - cxp) / rx
    vy = (-y1p - cyp) / ry
    theta1 = math.atan2(uy, ux)
    dtheta = math.atan2(ux * vy - uy * vx, ux * vx + uy * vy)
    if not sweep and dtheta > 0.0:
        dtheta -= 2.0 * math.pi
    elif sweep and dtheta < 0.0:
        dtheta += 2.0 * math.pi
    nseg = max(1, int(math.ceil(abs(dtheta) / (math.pi / 4.0) - 1e-12)))
    delta = dtheta / nseg
    k = 4.0 / 3.0 * math.tan(delta / 4.0)
    out = []
    theta = theta1
    px = x0
    py = y0
    for _ in range(nseg):
        theta2 = theta + delta
        cos1, sin1 = math.cos(theta), math.sin(theta)
        cos2, sin2 = math.cos(theta2), math.sin(theta2)
        # point and derivative of the unit-circle parameterisation, mapped back
        ex = cx + cos_phi * rx * cos2 - sin_phi * ry * sin2
        ey = cy + sin_phi * rx * cos2 + cos_phi * ry * sin2
        d1x = -rx * sin1
        d1y = ry * cos1
        d2x = -rx * sin2
        d2y = ry * cos2
        c1x = px + k * (cos_phi * d1x - sin_phi * d1y)
        c1y = py + k * (sin_phi * d1x + cos_phi * d1y)
        c2x = ex - k * (cos_phi * d2x - sin_phi * d2y)
        c2y = ey - k * (sin_phi * d2x + cos_phi * d2y)
        out.append((c1x, c1y, c2x, c2y, ex, ey))
        px, py = ex, ey
        theta = theta2
    if out:
        last = out[-1]
        out[-1] = (last[0], last[1], last[2], last[3], x1, y1)
    return out


PARAM_COUNT = {'M': 2, 'L': 2, 'H': 1, 'V': 1, 'C': 6, 'S': 4, 'Q': 4, 'T': 2, 'A': 7}


def parse_path_data(d):
    """Parse path data into the flat command list.

    Parsing stops at the first malformed token; everything before it is kept.
    """
    sc = PathScanner(d)
    cmds = []
    cmd = None
    x = y = 0.0
    sx = sy = 0.0
    last_ctrl = None       # second control point of the previous C/S command
    last_qctrl = None      # control point of the previous Q/T command
    started = False
    while True:
        letter = sc.command()
        if letter is not None:
            cmd = letter
            if cmd in 'Zz':
                if started:
                    cmds.append(('Z',))
                    x, y = sx, sy
                last_ctrl = last_qctrl = None
                continue
        elif cmd is None:
            break
        elif cmd in 'Mm':
            # repeated coordinate pairs after a moveto are implicit linetos
            cmd = 'L' if cmd == 'M' else 'l'
        sc.skip()
        if sc.i >= sc.n:
            break
        rel = cmd.islower()
        c = cmd.upper()
        count = PARAM_COUNT.get(c)
        if count is None:
            break      # a number after 'Z': not the expected kind of token
        v = []
        ok = True
        for k in range(count):
            token = sc.flag() if (c == 'A' and k in (3, 4)) else sc.number()
            if token is None:
                ok = False
                break
            v.append(token)
        if not ok:
            break
        if c == 'M':
            x = x + v[0] if rel else v[0]
            y = y + v[1] if rel else v[1]
            cmds.append(('M', x, y))
            sx, sy = x, y
            started = True
            last_ctrl = last_qctrl = None
        elif c == 'L':
            x = x + v[0] if rel else v[0]
            y = y + v[1] if rel else v[1]
            cmds.append(('L', x, y))
            last_ctrl = last_qctrl = None
        elif c == 'H':
            x = x + v[0] if rel else v[0]
            cmds.append(('L', x, y))
            last_ctrl = last_qctrl = None
        elif c == 'V':
            y = y + v[0] if rel else v[0]
            cmds.append(('L', x, y))
            last_ctrl = last_qctrl = None
        elif c == 'C':
            bx, by = (x, y) if rel else (0.0, 0.0)
            x1, y1 = bx + v[0], by + v[1]
            x2, y2 = bx + v[2], by + v[3]
            x, y = bx + v[4], by + v[5]
            cmds.append(('C', x1, y1, x2, y2, x, y))
            last_ctrl = (x2, y2)
            last_qctrl = None
        elif c == 'S':
            bx, by = (x, y) if rel else (0.0, 0.0)
            if last_ctrl is None:
                x1, y1 = x, y
            else:
                x1, y1 = 2.0 * x - last_ctrl[0], 2.0 * y - last_ctrl[1]
            x2, y2 = bx + v[0], by + v[1]
            x, y = bx + v[2], by + v[3]
            cmds.append(('C', x1, y1, x2, y2, x, y))
            last_ctrl = (x2, y2)
            last_qctrl = None
        elif c == 'Q':
            bx, by = (x, y) if rel else (0.0, 0.0)
            qx, qy = bx + v[0], by + v[1]
            nx, ny = bx + v[2], by + v[3]
            cmds.append(('C', x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y),
                         nx + 2.0 / 3.0 * (qx - nx), ny + 2.0 / 3.0 * (qy - ny), nx, ny))
            x, y = nx, ny
            last_qctrl = (qx, qy)
            last_ctrl = None
        elif c == 'T':
            bx, by = (x, y) if rel else (0.0, 0.0)
            if last_qctrl is None:
                qx, qy = x, y
            else:
                qx, qy = 2.0 * x - last_qctrl[0], 2.0 * y - last_qctrl[1]
            nx, ny = bx + v[0], by + v[1]
            cmds.append(('C', x + 2.0 / 3.0 * (qx - x), y + 2.0 / 3.0 * (qy - y),
                         nx + 2.0 / 3.0 * (qx - nx), ny + 2.0 / 3.0 * (qy - ny), nx, ny))
            x, y = nx, ny
            last_qctrl = (qx, qy)
            last_ctrl = None
        else:  # 'A'
            bx, by = (x, y) if rel else (0.0, 0.0)
            nx, ny = bx + v[5], by + v[6]
            for seg in arc_to_cubics(x, y, v[0], v[1], v[2], v[3] != 0.0, v[4] != 0.0, nx, ny):
                cmds.append(('C',) + seg)
            x, y = nx, ny
            last_ctrl = last_qctrl = None
    return cmds


def ellipse_path(cx, cy, rx, ry):
    """The four-arc ellipse of the SVG shape definitions."""
    cmds = [('M', cx + rx, cy)]
    for seg in arc_to_cubics(cx + rx, cy, rx, ry, 0.0, False, True, cx, cy + ry):
        cmds.append(('C',) + seg)
    for seg in arc_to_cubics(cx, cy + ry, rx, ry, 0.0, False, True, cx - rx, cy):
        cmds.append(('C',) + seg)
    for seg in arc_to_cubics(cx - rx, cy, rx, ry, 0.0, False, True, cx, cy - ry):
        cmds.append(('C',) + seg)
    for seg in arc_to_cubics(cx, cy - ry, rx, ry, 0.0, False, True, cx + rx, cy):
        cmds.append(('C',) + seg)
    cmds.append(('Z',))
    return cmds


def rect_path(x, y, w, h, rx, ry):
    if rx <= 0.0 or ry <= 0.0:
        return [('M', x, y), ('L', x + w, y), ('L', x + w, y + h), ('L', x, y + h), ('Z',)]
    rx = min(rx, w / 2.0)
    ry = min(ry, h / 2.0)
    cmds = [('M', x + rx, y), ('L', x + w - rx, y)]
    for seg in arc_to_cubics(x + w - rx, y, rx, ry, 0.0, False, True, x + w, y + ry):
        cmds.append(('C',) + seg)
    cmds.append(('L', x + w, y + h - ry))
    for seg in arc_to_cubics(x + w, y + h - ry, rx, ry, 0.0, False, True, x + w - rx, y + h):
        cmds.append(('C',) + seg)
    cmds.append(('L', x + rx, y + h))
    for seg in arc_to_cubics(x + rx, y + h, rx, ry, 0.0, False, True, x, y + h - ry):
        cmds.append(('C',) + seg)
    cmds.append(('L', x, y + ry))
    for seg in arc_to_cubics(x, y + ry, rx, ry, 0.0, False, True, x + rx, y):
        cmds.append(('C',) + seg)
    cmds.append(('Z',))
    return cmds


def points_path(text, close):
    vals = numbers(text)
    count = len(vals) // 2
    if count == 0:
        return []
    cmds = [('M', vals[0], vals[1])]
    for i in range(1, count):
        cmds.append(('L', vals[2 * i], vals[2 * i + 1]))
    if close:
        cmds.append(('Z',))
    return cmds


# ---------------------------------------------------------------------------
# Flattening
# ---------------------------------------------------------------------------

def flatten(cmds, mat, tol):
    """Flatten a command list into subpaths of straight segments.

    Control points are mapped through `mat` first, so `tol` is a chord
    deviation in the target coordinate system. Returns a list of
    (points, closed) pairs, points being a list of (x, y) tuples.
    """
    subpaths = []
    pts = None
    start = None
    cx = cy = 0.0
    for cmd in cmds:
        op = cmd[0]
        if op == 'M':
            x, y = mat_apply(mat, cmd[1], cmd[2])
            pts = [(x, y)]
            subpaths.append([pts, False])
            start = (x, y)
            cx, cy = x, y
        elif op == 'L':
            x, y = mat_apply(mat, cmd[1], cmd[2])
            if pts is None:
                pts = [(cx, cy)]
                subpaths.append([pts, False])
            pts.append((x, y))
            cx, cy = x, y
        elif op == 'C':
            x1, y1 = mat_apply(mat, cmd[1], cmd[2])
            x2, y2 = mat_apply(mat, cmd[3], cmd[4])
            x3, y3 = mat_apply(mat, cmd[5], cmd[6])
            if pts is None:
                pts = [(cx, cy)]
                subpaths.append([pts, False])
            x0, y0 = cx, cy
            ax = x0 - 2.0 * x1 + x2
            ay = y0 - 2.0 * y1 + y2
            bx = x1 - 2.0 * x2 + x3
            by = y1 - 2.0 * y2 + y3
            m = max(ax * ax + ay * ay, bx * bx + by * by)
            n = 1 if m <= 0.0 else int(math.ceil(math.sqrt(0.75 * math.sqrt(m) / tol)))
            if n < 1:
                n = 1
            elif n > 1000:
                n = 1000
            for i in range(1, n + 1):
                t = i / n
                u = 1.0 - t
                a = u * u * u
                b = 3.0 * u * u * t
                c = 3.0 * u * t * t
                d = t * t * t
                pts.append((a * x0 + b * x1 + c * x2 + d * x3,
                            a * y0 + b * y1 + c * y2 + d * y3))
            cx, cy = x3, y3
        elif op == 'Z':
            if pts is not None:
                subpaths[-1][1] = True
            if start is not None:
                cx, cy = start
            pts = None
    return [(p, c) for p, c in subpaths if len(p) >= 2 or c]


# ---------------------------------------------------------------------------
# Stroking
# ---------------------------------------------------------------------------

def _arc_step(r, tol):
    """The largest arc angle whose chord deviates from the circle by at most tol."""
    ratio = 1.0 - tol / r
    if ratio <= -1.0:
        return math.pi
    if ratio >= 1.0:
        return 2.0 * math.pi / 1000.0
    return 2.0 * math.acos(ratio)


def _circle_points(cx, cy, r, tol):
    if r <= 0.0:
        return []
    n = max(4, min(2000, int(math.ceil(2.0 * math.pi / _arc_step(r, tol)))))
    return [(cx + r * math.cos(2.0 * math.pi * i / n),
             cy + r * math.sin(2.0 * math.pi * i / n)) for i in range(n)]


def _arc_points(cx, cy, ax, ay, r, delta, tol):
    """Points of the arc of radius r about (cx, cy) starting at (ax, ay) and
    turning by the signed angle delta, endpoints included."""
    n = max(1, min(2000, int(math.ceil(abs(delta) / _arc_step(r, tol)))))
    a0 = math.atan2(ay - cy, ax - cx)
    return [(cx + r * math.cos(a0 + delta * i / n), cy + r * math.sin(a0 + delta * i / n))
            for i in range(n + 1)]


def _add(polys, poly):
    """Append a polygon, normalising it to positive signed area."""
    if len(poly) < 3:
        return
    area = 0.0
    n = len(poly)
    for i in range(n):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % n]
        area += x0 * y1 - x1 * y0
    if area < 0.0:
        poly = poly[::-1]
    polys.append(poly)


def stroke_polygons(subpaths, width, cap, join, miterlimit, tol):
    """Build the pieces whose nonzero union is the stroke of the subpaths."""
    r = width / 2.0
    polys = []
    for raw, closed in subpaths:
        pts = []
        for p in raw:
            if not pts or abs(p[0] - pts[-1][0]) > 1e-12 or abs(p[1] - pts[-1][1]) > 1e-12:
                pts.append(p)
        if closed and len(pts) > 1 and abs(pts[0][0] - pts[-1][0]) <= 1e-12 \
                and abs(pts[0][1] - pts[-1][1]) <= 1e-12:
            pts.pop()
        if len(pts) < 2:
            if pts and cap == 'round':
                _add(polys, _circle_points(pts[0][0], pts[0][1], r, tol))
            elif pts and cap == 'square':
                x, y = pts[0]
                _add(polys, [(x - r, y - r), (x + r, y - r), (x + r, y + r), (x - r, y + r)])
            continue
        n = len(pts)
        count = n if closed else n - 1
        dirs = []
        for i in range(count):
            x0, y0 = pts[i]
            x1, y1 = pts[(i + 1) % n]
            dx, dy = x1 - x0, y1 - y0
            length = math.hypot(dx, dy)
            if length <= 0.0:
                dirs.append(None)
                continue
            ux, uy = dx / length, dy / length
            nx, ny = -uy * r, ux * r
            _add(polys, [(x0 + nx, y0 + ny), (x1 + nx, y1 + ny),
                         (x1 - nx, y1 - ny), (x0 - nx, y0 - ny)])
            dirs.append((ux, uy))
        joints = range(count) if closed else range(1, count)
        for i in joints:
            d0 = dirs[i - 1]
            d1 = dirs[i]
            if d0 is None or d1 is None:
                continue
            px, py = pts[i]
            cross = d0[0] * d1[1] - d0[1] * d1[0]
            dot = d0[0] * d1[0] + d0[1] * d1[1]
            if cross == 0.0 and dot > 0.0:
                continue
            s = 1.0 if cross > 0.0 else -1.0
            ax = px + s * d0[1] * r
            ay = py - s * d0[0] * r
            bx = px + s * d1[1] * r
            by = py - s * d1[0] * r
            if join == 'round':
                if cross == 0.0:
                    # an exact reversal: the arc sweeps half a turn through the
                    # incoming direction, which is the side the segments miss
                    delta = s * math.pi
                else:
                    delta = math.atan2((ax - px) * (by - py) - (ay - py) * (bx - px),
                                       (ax - px) * (bx - px) + (ay - py) * (by - py))
                wedge = [(px, py)] + _arc_points(px, py, ax, ay, r, delta, tol)
                _add(polys, wedge)
                continue
            wedge = None
            if join == 'miter' and dot > -1.0:
                ratio = 1.0 / math.sqrt(max(1e-30, (1.0 + dot) / 2.0))
                if ratio <= miterlimit and cross != 0.0:
                    t = ((bx - ax) * d1[1] - (by - ay) * d1[0]) / cross
                    wedge = [(px, py), (ax, ay), (ax + d0[0] * t, ay + d0[1] * t), (bx, by)]
            if wedge is None:
                wedge = [(px, py), (ax, ay), (bx, by)]
            _add(polys, wedge)
        if not closed and cap != 'butt':
            ends = ((pts[0], dirs[0], -1.0), (pts[-1], dirs[count - 1], 1.0))
            for (px, py), d, sign in ends:
                if d is None:
                    continue
                ux, uy = d[0] * sign, d[1] * sign
                nx, ny = -uy * r, ux * r
                if cap == 'round':
                    _add(polys, _arc_points(px, py, px + nx, py + ny, r, -math.pi, tol))
                else:
                    _add(polys, [(px + nx, py + ny), (px + nx + ux * r, py + ny + uy * r),
                                 (px - nx + ux * r, py - ny + uy * r), (px - nx, py - ny)])
    return polys


# ---------------------------------------------------------------------------
# Rasterising and compositing
# ---------------------------------------------------------------------------

SUB = 64          # sub-scanlines per pixel row
FILL_TOL = 0.01   # chord deviation allowed when flattening, in device pixels


class Canvas:
    """A premultiplied straight-alpha float RGBA image."""

    def __init__(self, w, h):
        self.w = w
        self.h = h
        size = w * h
        self.r = [0.0] * size
        self.g = [0.0] * size
        self.b = [0.0] * size
        self.a = [0.0] * size
        self.y0 = h
        self.y1 = 0

    def fill(self, polys, evenodd, color, alpha):
        if alpha <= 0.0 or not polys:
            return
        w, h = self.w, self.h
        total = h * SUB
        rows = {}
        for poly in polys:
            n = len(poly)
            for i in range(n):
                x0, y0 = poly[i]
                x1, y1 = poly[(i + 1) % n]
                if y0 == y1:
                    continue
                wind = 1
                if y0 > y1:
                    x0, y0, x1, y1 = x1, y1, x0, y0
                    wind = -1
                dxdy = (x1 - x0) / (y1 - y0)
                klo = int(math.ceil(y0 * SUB - 0.5))
                if klo < 0:
                    klo = 0
                khi = int(math.ceil(y1 * SUB - 0.5)) - 1
                if khi >= total:
                    khi = total - 1
                if khi < klo:
                    continue
                ys = (klo + 0.5) / SUB
                x = x0 + (ys - y0) * dxdy
                step = dxdy / SUB
                for k in range(klo, khi + 1):
                    row = k // SUB
                    entry = rows.get(row)
                    if entry is None:
                        entry = rows[row] = []
                    entry.append((k - row * SUB, x, wind))
                    x += step
        if not rows:
            return
        weight = 1.0 / SUB
        cr, cg, cb = color
        R, G, B, A = self.r, self.g, self.b, self.a
        for y in sorted(rows):
            crossings = rows[y]
            buckets = {}
            for k, x, wind in crossings:
                lst = buckets.get(k)
                if lst is None:
                    lst = buckets[k] = []
                lst.append((x, wind))
            part = [0.0] * (w + 2)
            diff = [0.0] * (w + 2)
            xlo = w
            xhi = 0
            for lst in buckets.values():
                if len(lst) < 2:
                    continue
                lst.sort()
                spans = []
                if evenodd:
                    for i in range(0, len(lst) - 1, 2):
                        spans.append((lst[i][0], lst[i + 1][0]))
                else:
                    wind = 0
                    for i in range(len(lst) - 1):
                        wind += lst[i][1]
                        if wind != 0:
                            spans.append((lst[i][0], lst[i + 1][0]))
                for xa, xb in spans:
                    if xb <= 0.0 or xa >= w:
                        continue
                    if xa < 0.0:
                        xa = 0.0
                    if xb > w:
                        xb = float(w)
                    if xb <= xa:
                        continue
                    ia = int(xa)
                    ib = int(xb)
                    if ib >= w:
                        ib = w - 1
                    if ia == ib:
                        part[ia] += (xb - xa) * weight
                    else:
                        part[ia] += (ia + 1 - xa) * weight
                        part[ib] += (xb - ib) * weight
                        if ib > ia + 1:
                            diff[ia + 1] += weight
                            diff[ib] -= weight
                    if ia < xlo:
                        xlo = ia
                    if ib > xhi:
                        xhi = ib
            if xlo > xhi:
                continue
            base = y * w
            run = 0.0
            for x in range(xlo, xhi + 1):
                run += diff[x]
                cov = part[x] + run
                if cov <= 0.0009:
                    continue
                if cov > 1.0:
                    cov = 1.0
                ca = alpha * cov
                inv = 1.0 - ca
                idx = base + x
                R[idx] = cr * ca + R[idx] * inv
                G[idx] = cg * ca + G[idx] * inv
                B[idx] = cb * ca + B[idx] * inv
                A[idx] = ca + A[idx] * inv
            if y < self.y0:
                self.y0 = y
            if y + 1 > self.y1:
                self.y1 = y + 1

    def composite(self, src, opacity):
        """Composite `src` (a Canvas of the same size) over self with a group opacity."""
        if opacity <= 0.0 or src.y1 <= src.y0:
            return
        R, G, B, A = self.r, self.g, self.b, self.a
        sr, sg, sb, sa = src.r, src.g, src.b, src.a
        for idx in range(src.y0 * self.w, src.y1 * self.w):
            av = sa[idx]
            if av <= 0.0:
                continue
            inv = 1.0 - av * opacity
            R[idx] = sr[idx] * opacity + R[idx] * inv
            G[idx] = sg[idx] * opacity + G[idx] * inv
            B[idx] = sb[idx] * opacity + B[idx] * inv
            A[idx] = av * opacity + A[idx] * inv
        if src.y0 < self.y0:
            self.y0 = src.y0
        if src.y1 > self.y1:
            self.y1 = src.y1

    def to_ppm(self):
        out = bytearray()
        out += b'P6\n%d %d\n255\n' % (self.w, self.h)
        R, G, B, A = self.r, self.g, self.b, self.a
        data = bytearray(self.w * self.h * 3)
        j = 0
        for i in range(self.w * self.h):
            back = 1.0 - A[i]
            v = R[i] + back
            data[j] = 0 if v <= 0.0 else (255 if v >= 1.0 else int(v * 255.0 + 0.5))
            v = G[i] + back
            data[j + 1] = 0 if v <= 0.0 else (255 if v >= 1.0 else int(v * 255.0 + 0.5))
            v = B[i] + back
            data[j + 2] = 0 if v <= 0.0 else (255 if v >= 1.0 else int(v * 255.0 + 0.5))
            j += 3
        out += data
        return bytes(out)


# ---------------------------------------------------------------------------
# Rendering the element tree
# ---------------------------------------------------------------------------

INHERITED = ('fill', 'fill-opacity', 'fill-rule', 'stroke', 'stroke-width',
             'stroke-linecap', 'stroke-linejoin', 'stroke-miterlimit',
             'stroke-opacity', 'color')

DEFAULT_PROPS = {
    'fill': 'black',
    'fill-opacity': '1',
    'fill-rule': 'nonzero',
    'stroke': 'none',
    'stroke-width': '1',
    'stroke-linecap': 'butt',
    'stroke-linejoin': 'miter',
    'stroke-miterlimit': '4',
    'stroke-opacity': '1',
    'color': 'black',
}

MAX_DEPTH = 64

SHAPES = ('path', 'rect', 'circle', 'ellipse', 'line', 'polyline', 'polygon')
CONTAINERS = ('svg', 'g')


def element_props(el, parent):
    props = parent
    style = el.attrs.get('style')
    decls = parse_style(style) if style else None
    changed = False
    for key in INHERITED:
        value = el.attrs.get(key)
        if decls and key in decls:
            value = decls[key]
        if value is not None:
            if not changed:
                props = dict(parent)
                changed = True
            props[key] = value
    return props


def element_opacity(el):
    value = el.attrs.get('opacity')
    style = el.attrs.get('style')
    if style and 'opacity' in style:
        decls = parse_style(style)
        if 'opacity' in decls:
            value = decls['opacity']
    return 1.0 if value is None else parse_opacity(value)


def is_hidden(el):
    value = el.attrs.get('display')
    style = el.attrs.get('style')
    if style and 'display' in style:
        decls = parse_style(style)
        if 'display' in decls:
            value = decls['display']
    return value is not None and value.strip() == 'none'


def shape_path(el):
    a = el.attrs
    tag = el.tag
    if tag == 'path':
        return parse_path_data(a.get('d', ''))
    if tag == 'rect':
        w = parse_length(a.get('width'))
        h = parse_length(a.get('height'))
        if w <= 0.0 or h <= 0.0:
            return []
        x = parse_length(a.get('x'))
        y = parse_length(a.get('y'))
        rx_attr = a.get('rx')
        ry_attr = a.get('ry')
        rx = parse_length(rx_attr) if rx_attr not in (None, 'auto') else None
        ry = parse_length(ry_attr) if ry_attr not in (None, 'auto') else None
        if rx is None and ry is None:
            rx = ry = 0.0
        elif rx is None:
            rx = ry
        elif ry is None:
            ry = rx
        return rect_path(x, y, w, h, max(0.0, rx), max(0.0, ry))
    if tag == 'circle':
        r = parse_length(a.get('r'))
        if r <= 0.0:
            return []
        return ellipse_path(parse_length(a.get('cx')), parse_length(a.get('cy')), r, r)
    if tag == 'ellipse':
        rx = parse_length(a.get('rx'))
        ry = parse_length(a.get('ry'))
        if rx <= 0.0 or ry <= 0.0:
            return []
        return ellipse_path(parse_length(a.get('cx')), parse_length(a.get('cy')), rx, ry)
    if tag == 'line':
        return [('M', parse_length(a.get('x1')), parse_length(a.get('y1'))),
                ('L', parse_length(a.get('x2')), parse_length(a.get('y2')))]
    if tag == 'polyline':
        return points_path(a.get('points', ''), False)
    if tag == 'polygon':
        return points_path(a.get('points', ''), True)
    return []


def paint_shape(cmds, ctm, props, canvas):
    if not cmds:
        return
    current = parse_color(props['color'], (0.0, 0.0, 0.0))
    fill = parse_color(props['fill'], current)
    if fill is not None:
        alpha = parse_opacity(props['fill-opacity'])
        if alpha > 0.0:
            subpaths = flatten(cmds, ctm, FILL_TOL)
            polys = [p for p, _ in subpaths if len(p) >= 3]
            evenodd = props['fill-rule'].strip() == 'evenodd'
            canvas.fill(polys, evenodd, fill, alpha)
    stroke = parse_color(props['stroke'], current)
    if stroke is None:
        return
    width = parse_length(props['stroke-width'], 1.0)
    alpha = parse_opacity(props['stroke-opacity'])
    if width <= 0.0 or alpha <= 0.0:
        return
    scale = mat_scale(ctm)
    if scale <= 0.0:
        return
    tol = FILL_TOL / scale
    subpaths = flatten(cmds, IDENTITY, tol)
    cap = props['stroke-linecap'].strip()
    join = props['stroke-linejoin'].strip()
    if cap not in ('butt', 'round', 'square'):
        cap = 'butt'
    if join not in ('miter', 'round', 'bevel'):
        join = 'miter'
    limit = parse_length(props['stroke-miterlimit'], 4.0)
    polys = stroke_polygons(subpaths, width, cap, join, max(1.0, limit), tol)
    a, b, c, d, e, f = ctm
    device = [[(a * x + c * y + e, b * x + d * y + f) for x, y in poly] for poly in polys]
    canvas.fill(device, False, stroke, alpha)


def render_element(el, ctm, props, canvas, ids, depth=0):
    tag = el.tag
    if tag in ('defs', 'title', 'desc', 'style', 'metadata', 'symbol', 'clipPath', 'mask'):
        return
    if depth > MAX_DEPTH or is_hidden(el):
        return
    props = element_props(el, props)
    transform = el.attrs.get('transform')
    if transform:
        ctm = mat_mul(ctm, parse_transform(transform))
    opacity = element_opacity(el)
    if opacity <= 0.0:
        return
    target = canvas
    if opacity < 1.0:
        target = Canvas(canvas.w, canvas.h)
    if tag in CONTAINERS:
        for child in el.children:
            render_element(child, ctm, props, target, ids, depth + 1)
    elif tag == 'use':
        ref = el.attrs.get('href', '')
        referenced = ids.get(ref[1:]) if ref.startswith('#') else None
        if referenced is not None:
            x = parse_length(el.attrs.get('x'))
            y = parse_length(el.attrs.get('y'))
            if x != 0.0 or y != 0.0:
                ctm = mat_mul(ctm, (1.0, 0.0, 0.0, 1.0, x, y))
            render_element(referenced, ctm, props, target, ids, depth + 1)
    elif tag in SHAPES:
        paint_shape(shape_path(el), ctm, props, target)
    if target is not canvas:
        canvas.composite(target, opacity)


def collect_ids(el, ids):
    ident = el.attrs.get('id')
    if ident and ident not in ids:
        ids[ident] = el
    for child in el.children:
        collect_ids(child, ids)


def render_svg(root, width, height):
    vb = root.attrs.get('viewBox')
    box = None
    if vb:
        vals = numbers(vb)
        if len(vals) >= 4 and vals[2] > 0.0 and vals[3] > 0.0:
            box = vals[:4]
    if box is None:
        w = parse_length(root.attrs.get('width'), 0.0)
        h = parse_length(root.attrs.get('height'), 0.0)
        if w <= 0.0 or h <= 0.0:
            w, h = float(width), float(height)
        box = [0.0, 0.0, w, h]
    sx = width / box[2]
    sy = height / box[3]
    ctm = (sx, 0.0, 0.0, sy, -box[0] * sx, -box[1] * sy)
    canvas = Canvas(width, height)
    ids = {}
    collect_ids(root, ids)
    props = dict(DEFAULT_PROPS)
    render_element(root, ctm, props, canvas, ids)
    return canvas


def main(argv):
    if len(argv) != 3:
        sys.stderr.write('usage: main.py <input dir> <output dir>\n')
        return 2
    in_dir, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(in_dir, 'render.txt'), 'r', encoding='utf-8') as fh:
        lines = fh.read().split('\n')
    for line in lines:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        name, width, height = parts[0], int(parts[1]), int(parts[2])
        with open(os.path.join(in_dir, name), 'r', encoding='utf-8') as fh:
            text = fh.read()
        root = parse_xml(text)
        canvas = render_svg(root, width, height)
        stem = name[:-4] if name.lower().endswith('.svg') else name
        with open(os.path.join(out_dir, stem + '.ppm'), 'wb') as fh:
            fh.write(canvas.to_ppm())
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
