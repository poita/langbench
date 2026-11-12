package render

import (
	"strings"

	"svgraster/raster"
	"svgraster/stroke"
	"svgraster/svgparse"
	"svgraster/xmlmini"
)

// style holds the computed values of the inherited painting properties.
type style struct {
	fill          svgparse.Paint
	stroke        svgparse.Paint
	fillOpacity   float64
	strokeOpacity float64
	fillRule      raster.FillRule
	strokeWidth   float64
	cap           stroke.Cap
	join          stroke.Join
	miterLimit    float64
	color         svgparse.Color
}

// initialStyle holds the initial values at the document element.
func initialStyle() style {
	return style{
		fill:          svgparse.Paint{Color: svgparse.Color{}},
		stroke:        svgparse.Paint{None: true},
		fillOpacity:   1,
		strokeOpacity: 1,
		fillRule:      raster.NonZero,
		strokeWidth:   1,
		cap:           stroke.ButtCap,
		join:          stroke.MiterJoin,
		miterLimit:    4,
	}
}

// props gives access to an element's declared properties: the style attribute
// takes precedence over presentation attributes.
type props struct {
	n     *xmlmini.Node
	decls svgparse.Declarations
}

func newProps(n *xmlmini.Node) props {
	p := props{n: n}
	if s, ok := n.Attr("style"); ok {
		p.decls = svgparse.ParseStyle(s)
	}
	return p
}

// get returns the declared value of a property, preferring the style
// attribute, and whether there is one.
func (p props) get(name string) (string, bool) {
	if v, ok := p.decls[name]; ok {
		return v, true
	}
	if v, ok := p.n.Attr(name); ok {
		return strings.TrimSpace(v), true
	}
	return "", false
}

// computeStyle derives the element's computed style from its parent's.
func computeStyle(parent style, p props) style {
	s := parent
	init := initialStyle()
	if v, ok := p.get("color"); ok {
		if pt, ok := svgparse.ParsePaint(v); ok && !pt.None && !pt.Current {
			s.color = pt.Color
		} else if ok && pt.Current {
			// currentColor on color inherits the parent's value.
		} else {
			s.color = init.color
		}
	}
	paint := func(name string, cur *svgparse.Paint, initial svgparse.Paint) {
		if v, ok := p.get(name); ok {
			if pt, ok := svgparse.ParsePaint(v); ok {
				*cur = pt
			} else {
				*cur = initial
			}
		}
	}
	paint("fill", &s.fill, init.fill)
	paint("stroke", &s.stroke, init.stroke)
	opacity := func(name string, cur *float64) {
		if v, ok := p.get(name); ok {
			if o, ok := svgparse.ParseOpacity(v); ok {
				*cur = o
			} else {
				*cur = 1
			}
		}
	}
	opacity("fill-opacity", &s.fillOpacity)
	opacity("stroke-opacity", &s.strokeOpacity)
	if v, ok := p.get("fill-rule"); ok {
		switch v {
		case "nonzero":
			s.fillRule = raster.NonZero
		case "evenodd":
			s.fillRule = raster.EvenOdd
		default:
			s.fillRule = init.fillRule
		}
	}
	if v, ok := p.get("stroke-linecap"); ok {
		switch v {
		case "butt":
			s.cap = stroke.ButtCap
		case "round":
			s.cap = stroke.RoundCap
		case "square":
			s.cap = stroke.SquareCap
		default:
			s.cap = init.cap
		}
	}
	if v, ok := p.get("stroke-linejoin"); ok {
		switch v {
		case "miter":
			s.join = stroke.MiterJoin
		case "round":
			s.join = stroke.RoundJoin
		case "bevel":
			s.join = stroke.BevelJoin
		default:
			s.join = init.join
		}
	}
	if v, ok := p.get("stroke-width"); ok {
		if w, ok := svgparse.ParseLength(v); ok {
			s.strokeWidth = w
		} else {
			s.strokeWidth = init.strokeWidth
		}
	}
	if v, ok := p.get("stroke-miterlimit"); ok {
		if m, ok := svgparse.ParseLength(v); ok {
			s.miterLimit = m
		} else {
			s.miterLimit = init.miterLimit
		}
	}
	return s
}

// resolve turns a paint into an RGB triple in [0,1]; ok is false for none.
func (s style) resolve(p svgparse.Paint) (rgb [3]float64, ok bool) {
	if p.None {
		return rgb, false
	}
	c := p.Color
	if p.Current {
		c = s.color
	}
	return [3]float64{float64(c.R) / 255, float64(c.G) / 255, float64(c.B) / 255}, true
}

// opacityOf returns the element's own (non-inherited) opacity property.
func opacityOf(p props) float64 {
	if v, ok := p.get("opacity"); ok {
		if o, ok := svgparse.ParseOpacity(v); ok {
			return o
		}
	}
	return 1
}

// hidden reports whether the element's computed display is "none".
func hidden(p props) bool {
	v, ok := p.get("display")
	return ok && v == "none"
}
