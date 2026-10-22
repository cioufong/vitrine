package screen

import (
	"bytes"
	"testing"
)

func TestSplitBands(t *testing.T) {
	r := Rect{0, 0, 1920, 1080}
	bands := SplitBands(r, 8<<20)
	total := 0
	for i, b := range bands {
		if b.W*b.H*4 > 8<<20 {
			t.Fatalf("band %d too big", i)
		}
		if b.Y != total {
			t.Fatalf("band %d not contiguous", i)
		}
		total += b.H
	}
	if total != 1080 || len(bands) != 1 {
		t.Fatalf("1080p: %d rows in %d bands", total, len(bands))
	}
	big := SplitBands(Rect{0, 0, 6016, 3384}, 8<<20)
	if len(big) < 10 || big[0].H != (8<<20)/(6016*4) {
		t.Fatalf("6K bands: %v", big[:2])
	}
	if got := SplitBands(Rect{0, 0, 10, 10}, 1); len(got) != 10 {
		t.Fatalf("min one row per band: %d", len(got))
	}
}

func TestRegion(t *testing.T) {
	var g Region
	bounds := Rect{0, 0, 100, 100}
	g.Add(Rect{0, 0, 10, 10})
	g.Add(Rect{10, 0, 10, 10}) // touching, merges
	g.Add(Rect{80, 80, 50, 50})
	got := g.Take(bounds)
	if len(got) != 2 || got[0] != (Rect{0, 0, 20, 10}) || got[1] != (Rect{80, 80, 20, 20}) {
		t.Fatalf("got %v", got)
	}
	if !g.Empty() {
		t.Fatal("Take must reset")
	}
	g.MaxRects = 3
	for i := 0; i < 4; i++ {
		g.Add(Rect{i * 20, i * 20, 2, 2})
	}
	if got := g.Take(bounds); len(got) != 1 || got[0] != (Rect{0, 0, 62, 62}) {
		t.Fatalf("collapse: %v", got)
	}
	g.Add(Rect{1, 1, 1, 1})
	g.AddFull()
	if got := g.Take(bounds); len(got) != 1 || got[0] != bounds {
		t.Fatalf("full: %v", got)
	}
}

func TestBGRXToBGRA(t *testing.T) {
	src := []byte{
		1, 2, 3, 0, 4, 5, 6, 7, 99, 99, // row 0 + padding
		8, 9, 10, 0, 11, 12, 13, 0, 99, 99,
	}
	dst := make([]byte, 16)
	BGRXToBGRA(dst, src, 2, 2, 10)
	want := []byte{1, 2, 3, 255, 4, 5, 6, 255, 8, 9, 10, 255, 11, 12, 13, 255}
	if !bytes.Equal(dst, want) {
		t.Fatalf("got %v", dst)
	}
}

func TestDiffTilesAndCrop(t *testing.T) {
	w, h := 10, 6
	prev := make([]byte, w*h*4)
	cur := append([]byte(nil), prev...)
	cur[(4*w+9)*4] = 1 // pixel (9,4)
	got := DiffTiles(prev, cur, w, h, 4)
	if len(got) != 1 || got[0] != (Rect{8, 4, 2, 2}) {
		t.Fatalf("diff: %v", got)
	}
	if DiffTiles(prev, prev, w, h, 4) != nil {
		t.Fatal("identical frames should not differ")
	}
	c := Crop(cur, w, Rect{8, 4, 2, 2})
	if len(c) != 16 || c[4] != 1 {
		t.Fatalf("crop: %v", c)
	}
}
