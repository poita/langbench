package render

import (
	"svgraster/raster"
	"svgraster/stroke"
	"svgraster/svgparse"
	"svgraster/xmlmini"
)

// Style is the typed set of inherited painting properties of an element.
type Style struct {
	Fill, Stroke               svgparse.Paint
	FillOpacity, StrokeOpacity float64
	FillRule                   raster.Rule
	StrokeWidth                float64
	Cap                        stroke.Cap
	Join                       stroke.Join
	MiterLimit                 float64
	Color                      svgparse.RGB
}

// InitialStyle holds the initial values of the inherited properties.
func InitialStyle() Style {
	return Style{
		Fill:          svgparse.Paint{Kind: svgparse.PaintRGB},
		Stroke:        svgparse.Paint{Kind: svgparse.PaintNone},
		FillOpacity:   1,
		StrokeOpacity: 1,
		FillRule:      raster.NonZero,
		StrokeWidth:   1,
		MiterLimit:    4,
	}
}

type prop uint8

const (
	pFill prop = iota
	pFillOpacity
	pFillRule
	pStroke
	pStrokeWidth
	pLinecap
	pLinejoin
	pMiterLimit
	pStrokeOpacity
	pColor
	pOpacity
	pDisplay
	numProps
)

var propNames = [numProps]string{
	"fill", "fill-opacity", "fill-rule", "stroke", "stroke-width",
	"stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "stroke-opacity",
	"color", "opacity", "display",
}

var propIndex = func() map[string]prop {
	m := make(map[string]prop, numProps)
	for i, n := range propNames {
		m[n] = prop(i)
	}
	return m
}()

// declared holds the raw value of each property as written on one element.
type declared [numProps]struct {
	val string
	set bool
}

// collect gathers the raw property values of el: the style attribute first,
// then the presentation attributes for properties the style does not set.
func collect(el *xmlmini.Element) declared {
	var d declared
	if s, ok := el.Attr("style"); ok {
		svgparse.Style(s, func(name, value string) {
			if p, ok := propIndex[name]; ok {
				d[p].val, d[p].set = value, true
			}
		})
	}
	for p := prop(0); p < numProps; p++ {
		if !d[p].set {
			if v, ok := el.Attr(propNames[p]); ok {
				d[p].val, d[p].set = v, true
			}
		}
	}
	return d
}

// apply computes the element's style from its parent's: each property that
// is set on the element and parses replaces the inherited value; one that is
// set but does not parse reverts to the initial value.
func (d *declared) apply(s Style) Style {
	init := InitialStyle()
	if d[pColor].set {
		if p, ok := svgparse.ParseColor(d[pColor].val); ok && p.Kind == svgparse.PaintRGB {
			s.Color = p.RGB
		} else if !ok || p.Kind == svgparse.PaintNone {
			s.Color = init.Color
		}
	}
	if d[pFill].set {
		if p, ok := svgparse.ParseColor(d[pFill].val); ok {
			s.Fill = p
		} else {
			s.Fill = init.Fill
		}
	}
	if d[pStroke].set {
		if p, ok := svgparse.ParseColor(d[pStroke].val); ok {
			s.Stroke = p
		} else {
			s.Stroke = init.Stroke
		}
	}
	if d[pFillOpacity].set {
		if v, ok := svgparse.Opacity(d[pFillOpacity].val); ok {
			s.FillOpacity = v
		} else {
			s.FillOpacity = init.FillOpacity
		}
	}
	if d[pStrokeOpacity].set {
		if v, ok := svgparse.Opacity(d[pStrokeOpacity].val); ok {
			s.StrokeOpacity = v
		} else {
			s.StrokeOpacity = init.StrokeOpacity
		}
	}
	if d[pFillRule].set {
		switch d[pFillRule].val {
		case "nonzero":
			s.FillRule = raster.NonZero
		case "evenodd":
			s.FillRule = raster.EvenOdd
		default:
			s.FillRule = init.FillRule
		}
	}
	if d[pStrokeWidth].set {
		if v, ok := svgparse.Length(d[pStrokeWidth].val); ok {
			s.StrokeWidth = v
		} else {
			s.StrokeWidth = init.StrokeWidth
		}
	}
	if d[pMiterLimit].set {
		if v, _, ok := svgparse.ScanNumber(trimLeft(d[pMiterLimit].val), 0); ok {
			s.MiterLimit = v
		} else {
			s.MiterLimit = init.MiterLimit
		}
	}
	if d[pLinecap].set {
		switch d[pLinecap].val {
		case "butt":
			s.Cap = stroke.CapButt
		case "round":
			s.Cap = stroke.CapRound
		case "square":
			s.Cap = stroke.CapSquare
		default:
			s.Cap = init.Cap
		}
	}
	if d[pLinejoin].set {
		switch d[pLinejoin].val {
		case "miter":
			s.Join = stroke.JoinMiter
		case "round":
			s.Join = stroke.JoinRound
		case "bevel":
			s.Join = stroke.JoinBevel
		default:
			s.Join = init.Join
		}
	}
	return s
}

func trimLeft(s string) string {
	i := 0
	for i < len(s) && svgparse.IsSpace(s[i]) {
		i++
	}
	return s[i:]
}
