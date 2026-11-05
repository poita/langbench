/// The 147 SVG 1.1 colour keywords.
module svgraster.colors;

/// A named colour: lower-case keyword and its 0xRRGGBB value.
struct NamedColor
{
    string name;
    uint rgb;
}

/// All SVG 1.1 colour keywords, sorted by name.
immutable NamedColor[] namedColors = [
    NamedColor("aliceblue", 0xf0f8ff),
    NamedColor("antiquewhite", 0xfaebd7),
    NamedColor("aqua", 0x00ffff),
    NamedColor("aquamarine", 0x7fffd4),
    NamedColor("azure", 0xf0ffff),
    NamedColor("beige", 0xf5f5dc),
    NamedColor("bisque", 0xffe4c4),
    NamedColor("black", 0x000000),
    NamedColor("blanchedalmond", 0xffebcd),
    NamedColor("blue", 0x0000ff),
    NamedColor("blueviolet", 0x8a2be2),
    NamedColor("brown", 0xa52a2a),
    NamedColor("burlywood", 0xdeb887),
    NamedColor("cadetblue", 0x5f9ea0),
    NamedColor("chartreuse", 0x7fff00),
    NamedColor("chocolate", 0xd2691e),
    NamedColor("coral", 0xff7f50),
    NamedColor("cornflowerblue", 0x6495ed),
    NamedColor("cornsilk", 0xfff8dc),
    NamedColor("crimson", 0xdc143c),
    NamedColor("cyan", 0x00ffff),
    NamedColor("darkblue", 0x00008b),
    NamedColor("darkcyan", 0x008b8b),
    NamedColor("darkgoldenrod", 0xb8860b),
    NamedColor("darkgray", 0xa9a9a9),
    NamedColor("darkgreen", 0x006400),
    NamedColor("darkgrey", 0xa9a9a9),
    NamedColor("darkkhaki", 0xbdb76b),
    NamedColor("darkmagenta", 0x8b008b),
    NamedColor("darkolivegreen", 0x556b2f),
    NamedColor("darkorange", 0xff8c00),
    NamedColor("darkorchid", 0x9932cc),
    NamedColor("darkred", 0x8b0000),
    NamedColor("darksalmon", 0xe9967a),
    NamedColor("darkseagreen", 0x8fbc8f),
    NamedColor("darkslateblue", 0x483d8b),
    NamedColor("darkslategray", 0x2f4f4f),
    NamedColor("darkslategrey", 0x2f4f4f),
    NamedColor("darkturquoise", 0x00ced1),
    NamedColor("darkviolet", 0x9400d3),
    NamedColor("deeppink", 0xff1493),
    NamedColor("deepskyblue", 0x00bfff),
    NamedColor("dimgray", 0x696969),
    NamedColor("dimgrey", 0x696969),
    NamedColor("dodgerblue", 0x1e90ff),
    NamedColor("firebrick", 0xb22222),
    NamedColor("floralwhite", 0xfffaf0),
    NamedColor("forestgreen", 0x228b22),
    NamedColor("fuchsia", 0xff00ff),
    NamedColor("gainsboro", 0xdcdcdc),
    NamedColor("ghostwhite", 0xf8f8ff),
    NamedColor("gold", 0xffd700),
    NamedColor("goldenrod", 0xdaa520),
    NamedColor("gray", 0x808080),
    NamedColor("green", 0x008000),
    NamedColor("greenyellow", 0xadff2f),
    NamedColor("grey", 0x808080),
    NamedColor("honeydew", 0xf0fff0),
    NamedColor("hotpink", 0xff69b4),
    NamedColor("indianred", 0xcd5c5c),
    NamedColor("indigo", 0x4b0082),
    NamedColor("ivory", 0xfffff0),
    NamedColor("khaki", 0xf0e68c),
    NamedColor("lavender", 0xe6e6fa),
    NamedColor("lavenderblush", 0xfff0f5),
    NamedColor("lawngreen", 0x7cfc00),
    NamedColor("lemonchiffon", 0xfffacd),
    NamedColor("lightblue", 0xadd8e6),
    NamedColor("lightcoral", 0xf08080),
    NamedColor("lightcyan", 0xe0ffff),
    NamedColor("lightgoldenrodyellow", 0xfafad2),
    NamedColor("lightgray", 0xd3d3d3),
    NamedColor("lightgreen", 0x90ee90),
    NamedColor("lightgrey", 0xd3d3d3),
    NamedColor("lightpink", 0xffb6c1),
    NamedColor("lightsalmon", 0xffa07a),
    NamedColor("lightseagreen", 0x20b2aa),
    NamedColor("lightskyblue", 0x87cefa),
    NamedColor("lightslategray", 0x778899),
    NamedColor("lightslategrey", 0x778899),
    NamedColor("lightsteelblue", 0xb0c4de),
    NamedColor("lightyellow", 0xffffe0),
    NamedColor("lime", 0x00ff00),
    NamedColor("limegreen", 0x32cd32),
    NamedColor("linen", 0xfaf0e6),
    NamedColor("magenta", 0xff00ff),
    NamedColor("maroon", 0x800000),
    NamedColor("mediumaquamarine", 0x66cdaa),
    NamedColor("mediumblue", 0x0000cd),
    NamedColor("mediumorchid", 0xba55d3),
    NamedColor("mediumpurple", 0x9370db),
    NamedColor("mediumseagreen", 0x3cb371),
    NamedColor("mediumslateblue", 0x7b68ee),
    NamedColor("mediumspringgreen", 0x00fa9a),
    NamedColor("mediumturquoise", 0x48d1cc),
    NamedColor("mediumvioletred", 0xc71585),
    NamedColor("midnightblue", 0x191970),
    NamedColor("mintcream", 0xf5fffa),
    NamedColor("mistyrose", 0xffe4e1),
    NamedColor("moccasin", 0xffe4b5),
    NamedColor("navajowhite", 0xffdead),
    NamedColor("navy", 0x000080),
    NamedColor("oldlace", 0xfdf5e6),
    NamedColor("olive", 0x808000),
    NamedColor("olivedrab", 0x6b8e23),
    NamedColor("orange", 0xffa500),
    NamedColor("orangered", 0xff4500),
    NamedColor("orchid", 0xda70d6),
    NamedColor("palegoldenrod", 0xeee8aa),
    NamedColor("palegreen", 0x98fb98),
    NamedColor("paleturquoise", 0xafeeee),
    NamedColor("palevioletred", 0xdb7093),
    NamedColor("papayawhip", 0xffefd5),
    NamedColor("peachpuff", 0xffdab9),
    NamedColor("peru", 0xcd853f),
    NamedColor("pink", 0xffc0cb),
    NamedColor("plum", 0xdda0dd),
    NamedColor("powderblue", 0xb0e0e6),
    NamedColor("purple", 0x800080),
    NamedColor("red", 0xff0000),
    NamedColor("rosybrown", 0xbc8f8f),
    NamedColor("royalblue", 0x4169e1),
    NamedColor("saddlebrown", 0x8b4513),
    NamedColor("salmon", 0xfa8072),
    NamedColor("sandybrown", 0xf4a460),
    NamedColor("seagreen", 0x2e8b57),
    NamedColor("seashell", 0xfff5ee),
    NamedColor("sienna", 0xa0522d),
    NamedColor("silver", 0xc0c0c0),
    NamedColor("skyblue", 0x87ceeb),
    NamedColor("slateblue", 0x6a5acd),
    NamedColor("slategray", 0x708090),
    NamedColor("slategrey", 0x708090),
    NamedColor("snow", 0xfffafa),
    NamedColor("springgreen", 0x00ff7f),
    NamedColor("steelblue", 0x4682b4),
    NamedColor("tan", 0xd2b48c),
    NamedColor("teal", 0x008080),
    NamedColor("thistle", 0xd8bfd8),
    NamedColor("tomato", 0xff6347),
    NamedColor("turquoise", 0x40e0d0),
    NamedColor("violet", 0xee82ee),
    NamedColor("wheat", 0xf5deb3),
    NamedColor("white", 0xffffff),
    NamedColor("whitesmoke", 0xf5f5f5),
    NamedColor("yellow", 0xffff00),
    NamedColor("yellowgreen", 0x9acd32),
];

/// Look up a colour keyword. `lower` must already be lower case. Returns
/// `true` and sets `rgb` (0xRRGGBB) when the keyword is known.
bool lookupColor(const(char)[] lower, out uint rgb) pure nothrow @nogc @safe
{
    size_t lo = 0, hi = namedColors.length;
    while (lo < hi)
    {
        immutable mid = (lo + hi) / 2;
        immutable cmp = compare(namedColors[mid].name, lower);
        if (cmp == 0)
        {
            rgb = namedColors[mid].rgb;
            return true;
        }
        if (cmp < 0)
            lo = mid + 1;
        else
            hi = mid;
    }
    return false;
}

private int compare(const(char)[] a, const(char)[] b) pure nothrow @nogc @safe
{
    immutable n = a.length < b.length ? a.length : b.length;
    foreach (i; 0 .. n)
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    return a.length < b.length ? -1 : (a.length > b.length ? 1 : 0);
}
