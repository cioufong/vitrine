package screen

// BGRXToBGRA copies a 32-bpp little-endian ZPixmap (bytes B,G,R,X) into a
// tightly packed BGRA8 buffer with alpha forced to 255 (opaque pixels are
// trivially premultiplied). srcStride is the source row length in bytes;
// dst must hold w*h*4 bytes.
func BGRXToBGRA(dst, src []byte, w, h, srcStride int) {
	row := w * 4
	for y := 0; y < h; y++ {
		d := dst[y*row : (y+1)*row]
		copy(d, src[y*srcStride:y*srcStride+row])
		for i := 3; i < row; i += 4 {
			d[i] = 0xff
		}
	}
}
