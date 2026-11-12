package render

import (
	"svgraster/path"
	"svgraster/svgparse"
	"svgraster/xmlmini"
)

// ShapePath converts a shape element (path, rect, circle, ellipse, line,
// polyline, polygon) to a path in the element's user space. It returns nil
// when nothing is to be drawn.
func ShapePath(n *xmlmini.Node) *path.Path {
	switch n.Tag {
	case "path":
		d, _ := n.Attr("d")
		return path.Parse(d)
	case "rect":
		return rectPath(n)
	case "circle":
		r := lengthOr(n, "r", 0)
		return path.Ellipse(lengthOr(n, "cx", 0), lengthOr(n, "cy", 0), r, r)
	case "ellipse":
		return path.Ellipse(lengthOr(n, "cx", 0), lengthOr(n, "cy", 0),
			lengthOr(n, "rx", 0), lengthOr(n, "ry", 0))
	case "line":
		return path.Line(lengthOr(n, "x1", 0), lengthOr(n, "y1", 0),
			lengthOr(n, "x2", 0), lengthOr(n, "y2", 0))
	case "polyline", "polygon":
		s, _ := n.Attr("points")
		return path.Poly(svgparse.ParseNumberList(s), n.Tag == "polygon")
	}
	return nil
}

func rectPath(n *xmlmini.Node) *path.Path {
	x, y := lengthOr(n, "x", 0), lengthOr(n, "y", 0)
	w, h := lengthOr(n, "width", 0), lengthOr(n, "height", 0)
	if !(w > 0) || !(h > 0) {
		return nil
	}
	rx, rxOK := lengthAttr(n, "rx")
	ry, ryOK := lengthAttr(n, "ry")
	switch {
	case !rxOK && !ryOK:
		rx, ry = 0, 0
	case !rxOK:
		rx = ry
	case !ryOK:
		ry = rx
	}
	if rx < 0 {
		rx = 0
	}
	if ry < 0 {
		ry = 0
	}
	if rx > w/2 {
		rx = w / 2
	}
	if ry > h/2 {
		ry = h / 2
	}
	return path.Rect(x, y, w, h, rx, ry)
}
