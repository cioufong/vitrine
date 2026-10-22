package win

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math/bits"
)

// DIB constants (wingdi.h).
const (
	biRGB          = 0
	biBitfields    = 3
	bitmapV5Size   = 124
	bitmapInfoSize = 40
	lcsSRGB        = 0x73524742 // 'sRGB'
	lcsGMImages    = 4
)

// dibToPNG converts a packed DIB (CF_DIB / CF_DIBV5 clipboard contents:
// header, optional masks/palette, pixels) to PNG. 24- and 32-bit images
// (BI_RGB or BI_BITFIELDS) are supported, which covers what screenshot
// tools and browsers put on the clipboard.
func dibToPNG(dib []byte) ([]byte, error) {
	le := binary.LittleEndian
	if len(dib) < bitmapInfoSize {
		return nil, errors.New("DIB too short")
	}
	hdrSize := int(le.Uint32(dib[0:]))
	width := int(int32(le.Uint32(dib[4:])))
	height := int(int32(le.Uint32(dib[8:])))
	bpp := int(le.Uint16(dib[14:]))
	compression := le.Uint32(dib[16:])
	clrUsed := int(le.Uint32(dib[32:]))
	if hdrSize < bitmapInfoSize || hdrSize > len(dib) || width <= 0 || height == 0 || width > 1<<15 {
		return nil, fmt.Errorf("bad DIB header (size %d, %dx%d)", hdrSize, width, height)
	}
	topDown := height < 0
	if topDown {
		height = -height
	}
	if height > 1<<15 {
		return nil, errors.New("DIB too tall")
	}
	if bpp != 24 && bpp != 32 {
		return nil, fmt.Errorf("unsupported DIB depth %d", bpp)
	}
	rMask, gMask, bMask, aMask := uint32(0xFF0000), uint32(0xFF00), uint32(0xFF), uint32(0)
	off := hdrSize
	switch compression {
	case biRGB:
	case biBitfields:
		if bpp != 32 {
			return nil, errors.New("BI_BITFIELDS needs 32 bpp")
		}
		if hdrSize == bitmapInfoSize { // masks follow a plain BITMAPINFOHEADER
			if len(dib) < off+12 {
				return nil, errors.New("DIB masks truncated")
			}
			rMask, gMask, bMask = le.Uint32(dib[off:]), le.Uint32(dib[off+4:]), le.Uint32(dib[off+8:])
			off += 12
		} else if hdrSize >= 56 { // V3+/V4/V5 headers carry the masks
			rMask, gMask, bMask, aMask = le.Uint32(dib[40:]), le.Uint32(dib[44:]), le.Uint32(dib[48:]), le.Uint32(dib[52:])
		}
	default:
		return nil, fmt.Errorf("unsupported DIB compression %d", compression)
	}
	off += clrUsed * 4
	stride := (width*bpp + 31) / 32 * 4
	if off < 0 || len(dib) < off+stride*height {
		return nil, errors.New("DIB pixels truncated")
	}
	if compression == biRGB && bpp == 32 && hdrSize >= 56 {
		aMask = le.Uint32(dib[52:]) // V4/V5 may declare alpha even for BI_RGB
	}
	img := image.NewNRGBA(image.Rect(0, 0, width, height))
	hasAlpha := false
	for y := 0; y < height; y++ {
		srcY := height - 1 - y
		if topDown {
			srcY = y
		}
		row := dib[off+srcY*stride:]
		for x := 0; x < width; x++ {
			var r, g, b, a uint8 = 0, 0, 0, 255
			if bpp == 24 {
				b, g, r = row[x*3], row[x*3+1], row[x*3+2]
			} else {
				p := le.Uint32(row[x*4:])
				r, g, b = extract(p, rMask), extract(p, gMask), extract(p, bMask)
				if aMask != 0 {
					a = extract(p, aMask)
					hasAlpha = hasAlpha || a != 0
				}
			}
			img.SetNRGBA(x, y, color.NRGBA{r, g, b, a})
		}
	}
	if aMask != 0 && !hasAlpha { // all-zero alpha means "no alpha", not "invisible"
		for i := 3; i < len(img.Pix); i += 4 {
			img.Pix[i] = 255
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// extract scales the masked channel of p to 8 bits.
func extract(p, mask uint32) uint8 {
	if mask == 0 {
		return 0
	}
	shift := bits.TrailingZeros32(mask)
	width := bits.OnesCount32(mask)
	v := (p & mask) >> shift
	if width >= 8 {
		return uint8(v >> (width - 8))
	}
	return uint8(v * 255 / (1<<width - 1))
}

// pngToDIBV5 converts a PNG to a bottom-up 32-bit BITMAPV5HEADER DIB with
// straight alpha (CF_DIBV5); Windows synthesizes CF_DIB/CF_BITMAP from it
// for applications that do not understand PNG.
func pngToDIBV5(data []byte) ([]byte, error) {
	src, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	b := src.Bounds()
	w, h := b.Dx(), b.Dy()
	out := make([]byte, bitmapV5Size+w*h*4)
	le := binary.LittleEndian
	le.PutUint32(out[0:], bitmapV5Size)
	le.PutUint32(out[4:], uint32(int32(w)))
	le.PutUint32(out[8:], uint32(int32(h))) // positive: bottom-up, the most compatible layout
	le.PutUint16(out[12:], 1)               // planes
	le.PutUint16(out[14:], 32)              // bit count
	le.PutUint32(out[16:], biBitfields)
	le.PutUint32(out[20:], uint32(w*h*4))
	le.PutUint32(out[24:], 3780) // 96 DPI in pixels per metre
	le.PutUint32(out[28:], 3780)
	le.PutUint32(out[40:], 0x00FF0000)
	le.PutUint32(out[44:], 0x0000FF00)
	le.PutUint32(out[48:], 0x000000FF)
	le.PutUint32(out[52:], 0xFF000000)
	le.PutUint32(out[56:], lcsSRGB)
	le.PutUint32(out[108:], lcsGMImages)
	px := out[bitmapV5Size:]
	for y := 0; y < h; y++ {
		row := px[(h-1-y)*w*4:]
		for x := 0; x < w; x++ {
			c := color.NRGBAModel.Convert(src.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
			row[x*4], row[x*4+1], row[x*4+2], row[x*4+3] = c.B, c.G, c.R, c.A
		}
	}
	return out, nil
}
