package win

import "image"

// premultipliedBGRAToNRGBA converts GDI's 32-bit premultiplied BGRA rows (top-down,
// tightly packed) to straight-alpha RGBA. Bitmaps without any alpha (all zero)
// are treated as opaque, the way GDI draws them.
func premultipliedBGRAToNRGBA(pix []byte, w, h int) *image.NRGBA {
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	hasAlpha := false
	for i := 3; i < len(pix); i += 4 {
		if pix[i] != 0 {
			hasAlpha = true
			break
		}
	}
	for i := 0; i+3 < len(pix) && i < w*h*4; i += 4 {
		b, g, r, a := pix[i], pix[i+1], pix[i+2], pix[i+3]
		if !hasAlpha {
			a = 255
		} else if a > 0 && a < 255 {
			r = uint8(min(255, int(r)*255/int(a)))
			g = uint8(min(255, int(g)*255/int(a)))
			b = uint8(min(255, int(b)*255/int(a)))
		}
		img.Pix[i], img.Pix[i+1], img.Pix[i+2], img.Pix[i+3] = r, g, b, a
	}
	return img
}
