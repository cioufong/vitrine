// Package screen holds platform-independent framebuffer helpers used by the
// X11 capturer: dirty-rect bookkeeping, band splitting and pixel conversion.
package screen

// Rect is a pixel rectangle (top-left origin).
type Rect struct{ X, Y, W, H int }

// Empty reports whether r covers no pixels.
func (r Rect) Empty() bool { return r.W <= 0 || r.H <= 0 }

// Area returns r's pixel count.
func (r Rect) Area() int {
	if r.Empty() {
		return 0
	}
	return r.W * r.H
}

// Intersect returns the overlap of r and o (empty if none).
func (r Rect) Intersect(o Rect) Rect {
	x0, y0 := max(r.X, o.X), max(r.Y, o.Y)
	x1, y1 := min(r.X+r.W, o.X+o.W), min(r.Y+r.H, o.Y+o.H)
	if x1 <= x0 || y1 <= y0 {
		return Rect{}
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// Union returns the bounding box of r and o.
func (r Rect) Union(o Rect) Rect {
	if r.Empty() {
		return o
	}
	if o.Empty() {
		return r
	}
	x0, y0 := min(r.X, o.X), min(r.Y, o.Y)
	x1, y1 := max(r.X+r.W, o.X+o.W), max(r.Y+r.H, o.Y+o.H)
	return Rect{x0, y0, x1 - x0, y1 - y0}
}

// touches reports whether r and o share pixels or touch edges.
func (r Rect) touches(o Rect) bool {
	return r.X <= o.X+o.W && o.X <= r.X+r.W && r.Y <= o.Y+o.H && o.Y <= r.Y+r.H
}

// Region accumulates dirty rectangles between sends. It keeps a short list of
// rects, merging touching ones, and collapses to the bounding box when the
// list grows long or the boxes would mostly overlap anyway — sending a few
// extra pixels is cheaper than many tiny messages and GetImage round trips.
type Region struct {
	rects []Rect
	full  bool
	// MaxRects bounds the list before it collapses to its bounding box.
	MaxRects int
}

// Add records a dirty rectangle (clipped by the caller).
func (g *Region) Add(r Rect) {
	if r.Empty() || g.full {
		return
	}
	limit := g.MaxRects
	if limit <= 0 {
		limit = 16
	}
	// Merge into an existing rect when the union wastes little area.
	for i, e := range g.rects {
		if e.touches(r) {
			u := e.Union(r)
			if u.Area() <= (e.Area()+r.Area())*3/2 {
				g.rects = append(g.rects[:i], g.rects[i+1:]...)
				g.Add(u)
				return
			}
		}
	}
	g.rects = append(g.rects, r)
	if len(g.rects) > limit {
		b := Rect{}
		for _, e := range g.rects {
			b = b.Union(e)
		}
		g.rects = []Rect{b}
	}
}

// AddFull marks the whole surface dirty.
func (g *Region) AddFull() { g.full = true; g.rects = nil }

// Empty reports whether nothing is dirty.
func (g *Region) Empty() bool { return !g.full && len(g.rects) == 0 }

// Take returns the dirty rects clipped to bounds and resets the region.
func (g *Region) Take(bounds Rect) []Rect {
	defer func() { g.rects, g.full = nil, false }()
	if g.full {
		return []Rect{bounds}
	}
	out := make([]Rect, 0, len(g.rects))
	for _, r := range g.rects {
		if c := r.Intersect(bounds); !c.Empty() {
			out = append(out, c)
		}
	}
	return out
}

// SplitBands splits r into horizontal bands of at most maxBytes BGRA pixels
// each (at least one row per band).
func SplitBands(r Rect, maxBytes int) []Rect {
	if r.Empty() {
		return nil
	}
	rows := maxBytes / (r.W * 4)
	if rows < 1 {
		rows = 1
	}
	var out []Rect
	for y := r.Y; y < r.Y+r.H; y += rows {
		h := min(rows, r.Y+r.H-y)
		out = append(out, Rect{r.X, y, r.W, h})
	}
	return out
}
