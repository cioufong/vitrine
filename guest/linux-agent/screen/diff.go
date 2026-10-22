package screen

import "bytes"

// DiffTiles compares two equally sized BGRA frames (stride w*4) and returns
// the tiles that differ. Used when the Damage extension is unavailable.
func DiffTiles(prev, cur []byte, w, h, tile int) []Rect {
	var out []Rect
	stride := w * 4
	for ty := 0; ty < h; ty += tile {
		th := min(tile, h-ty)
		for tx := 0; tx < w; tx += tile {
			tw := min(tile, w-tx)
			for y := ty; y < ty+th; y++ {
				o := y*stride + tx*4
				if !bytes.Equal(prev[o:o+tw*4], cur[o:o+tw*4]) {
					out = append(out, Rect{tx, ty, tw, th})
					break
				}
			}
		}
	}
	return out
}

// Crop copies rect r out of a full frame (stride w*4) into a tight buffer.
func Crop(full []byte, w int, r Rect) []byte {
	out := make([]byte, r.W*r.H*4)
	for y := 0; y < r.H; y++ {
		o := ((r.Y+y)*w + r.X) * 4
		copy(out[y*r.W*4:(y+1)*r.W*4], full[o:o+r.W*4])
	}
	return out
}
