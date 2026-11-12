/// The 147 colour keywords of SVG 1.1 (§4.4).
module svgraster.colors;

/// An 8-bit sRGB colour.
struct Rgb
{
    ubyte r, g, b;
}

private struct Named
{
    string name;
    uint rgb;
}

private immutable Named[] namedColors = [
    Named("aliceblue", 0xf0f8ff), Named("antiquewhite", 0xfaebd7), Named("aqua", 0x00ffff),
    Named("aquamarine", 0x7fffd4), Named("azure", 0xf0ffff), Named("beige", 0xf5f5dc),
    Named("bisque", 0xffe4c4), Named("black", 0x000000), Named("blanchedalmond", 0xffebcd),
    Named("blue", 0x0000ff), Named("blueviolet", 0x8a2be2), Named("brown", 0xa52a2a),
    Named("burlywood", 0xdeb887), Named("cadetblue", 0x5f9ea0), Named("chartreuse", 0x7fff00),
    Named("chocolate", 0xd2691e), Named("coral", 0xff7f50), Named("cornflowerblue", 0x6495ed),
    Named("cornsilk", 0xfff8dc), Named("crimson", 0xdc143c), Named("cyan", 0x00ffff),
    Named("darkblue", 0x00008b), Named("darkcyan", 0x008b8b), Named("darkgoldenrod", 0xb8860b),
    Named("darkgray", 0xa9a9a9), Named("darkgreen", 0x006400), Named("darkgrey", 0xa9a9a9),
    Named("darkkhaki", 0xbdb76b), Named("darkmagenta", 0x8b008b), Named("darkolivegreen", 0x556b2f),
    Named("darkorange", 0xff8c00), Named("darkorchid", 0x9932cc), Named("darkred", 0x8b0000),
    Named("darksalmon", 0xe9967a), Named("darkseagreen", 0x8fbc8f), Named("darkslateblue", 0x483d8b),
    Named("darkslategray", 0x2f4f4f), Named("darkslategrey", 0x2f4f4f), Named("darkturquoise", 0x00ced1),
    Named("darkviolet", 0x9400d3), Named("deeppink", 0xff1493), Named("deepskyblue", 0x00bfff),
    Named("dimgray", 0x696969), Named("dimgrey", 0x696969), Named("dodgerblue", 0x1e90ff),
    Named("firebrick", 0xb22222), Named("floralwhite", 0xfffaf0), Named("forestgreen", 0x228b22),
    Named("fuchsia", 0xff00ff), Named("gainsboro", 0xdcdcdc), Named("ghostwhite", 0xf8f8ff),
    Named("gold", 0xffd700), Named("goldenrod", 0xdaa520), Named("gray", 0x808080),
    Named("grey", 0x808080), Named("green", 0x008000), Named("greenyellow", 0xadff2f),
    Named("honeydew", 0xf0fff0), Named("hotpink", 0xff69b4), Named("indianred", 0xcd5c5c),
    Named("indigo", 0x4b0082), Named("ivory", 0xfffff0), Named("khaki", 0xf0e68c),
    Named("lavender", 0xe6e6fa), Named("lavenderblush", 0xfff0f5), Named("lawngreen", 0x7cfc00),
    Named("lemonchiffon", 0xfffacd), Named("lightblue", 0xadd8e6), Named("lightcoral", 0xf08080),
    Named("lightcyan", 0xe0ffff), Named("lightgoldenrodyellow", 0xfafad2), Named("lightgray", 0xd3d3d3),
    Named("lightgreen", 0x90ee90), Named("lightgrey", 0xd3d3d3), Named("lightpink", 0xffb6c1),
    Named("lightsalmon", 0xffa07a), Named("lightseagreen", 0x20b2aa), Named("lightskyblue", 0x87cefa),
    Named("lightslategray", 0x778899), Named("lightslategrey", 0x778899), Named("lightsteelblue", 0xb0c4de),
    Named("lightyellow", 0xffffe0), Named("lime", 0x00ff00), Named("limegreen", 0x32cd32),
    Named("linen", 0xfaf0e6), Named("magenta", 0xff00ff), Named("maroon", 0x800000),
    Named("mediumaquamarine", 0x66cdaa), Named("mediumblue", 0x0000cd), Named("mediumorchid", 0xba55d3),
    Named("mediumpurple", 0x9370db), Named("mediumseagreen", 0x3cb371), Named("mediumslateblue", 0x7b68ee),
    Named("mediumspringgreen", 0x00fa9a), Named("mediumturquoise", 0x48d1cc), Named("mediumvioletred", 0xc71585),
    Named("midnightblue", 0x191970), Named("mintcream", 0xf5fffa), Named("mistyrose", 0xffe4e1),
    Named("moccasin", 0xffe4b5), Named("navajowhite", 0xffdead), Named("navy", 0x000080),
    Named("oldlace", 0xfdf5e6), Named("olive", 0x808000), Named("olivedrab", 0x6b8e23),
    Named("orange", 0xffa500), Named("orangered", 0xff4500), Named("orchid", 0xda70d6),
    Named("palegoldenrod", 0xeee8aa), Named("palegreen", 0x98fb98), Named("paleturquoise", 0xafeeee),
    Named("palevioletred", 0xdb7093), Named("papayawhip", 0xffefd5), Named("peachpuff", 0xffdab9),
    Named("peru", 0xcd853f), Named("pink", 0xffc0cb), Named("plum", 0xdda0dd),
    Named("powderblue", 0xb0e0e6), Named("purple", 0x800080), Named("red", 0xff0000),
    Named("rosybrown", 0xbc8f8f), Named("royalblue", 0x4169e1), Named("saddlebrown", 0x8b4513),
    Named("salmon", 0xfa8072), Named("sandybrown", 0xf4a460), Named("seagreen", 0x2e8b57),
    Named("seashell", 0xfff5ee), Named("sienna", 0xa0522d), Named("silver", 0xc0c0c0),
    Named("skyblue", 0x87ceeb), Named("slateblue", 0x6a5acd), Named("slategray", 0x708090),
    Named("slategrey", 0x708090), Named("snow", 0xfffafa), Named("springgreen", 0x00ff7f),
    Named("steelblue", 0x4682b4), Named("tan", 0xd2b48c), Named("teal", 0x008080),
    Named("thistle", 0xd8bfd8), Named("tomato", 0xff6347), Named("turquoise", 0x40e0d0),
    Named("violet", 0xee82ee), Named("wheat", 0xf5deb3), Named("white", 0xffffff),
    Named("whitesmoke", 0xf5f5f5), Named("yellow", 0xffff00), Named("yellowgreen", 0x9acd32),
];

/// Look up a colour keyword. `name` must already be lower case.
/// Returns: `true` and sets `c` if `name` is one of the 147 keywords.
bool lookupColorName(const(char)[] name, out Rgb c)
{
    foreach (ref e; namedColors)
    {
        if (e.name == name)
        {
            c = Rgb((e.rgb >> 16) & 0xff, (e.rgb >> 8) & 0xff, e.rgb & 0xff);
            return true;
        }
    }
    return false;
}

unittest
{
    assert(namedColors.length == 147);
    Rgb c;
    assert(lookupColorName("tomato", c) && c == Rgb(255, 99, 71));
    assert(!lookupColorName("nocolour", c));
}
