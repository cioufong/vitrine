//go:build linux

package agent

import (
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"unsafe"

	"golang.org/x/sys/unix"
)

// CameraLabel is the v4l2loopback card_label the host's installer gives the
// guest's virtual camera; the agent writes only to a device with this name.
const CameraLabel = "Vitrine Camera"

// cameraSysfs is where video4linux devices are listed (a variable for tests).
var cameraSysfs = "/sys/class/video4linux"

const (
	vidiocSFmt           = 0xC0D05605 // _IOWR('V', 5, struct v4l2_format), 208 bytes on 64-bit
	v4l2BufTypeVideoOut  = 2
	v4l2PixFmtYUYV       = 0x56595559 // 'YUYV'
	v4l2FieldNone        = 1
	v4l2ColorspaceSRGB   = 8
	v4l2FormatSize       = 208
	v4l2FormatUnionStart = 8 // the union is 8-byte aligned (struct v4l2_window holds pointers)
)

func cameraSupported() bool { return true }

// findCameraDevice returns /dev/videoN for the device labelled CameraLabel.
func findCameraDevice() (string, error) {
	names, _ := filepath.Glob(filepath.Join(cameraSysfs, "video*"))
	for _, dir := range names {
		b, err := os.ReadFile(filepath.Join(dir, "name"))
		if err == nil && strings.TrimSpace(string(b)) == CameraLabel {
			return "/dev/" + filepath.Base(dir), nil
		}
	}
	return "", errors.New("no \"" + CameraLabel + "\" device: v4l2loopback isn't installed or loaded (install camera support from Vitrine)")
}

// v4l2OutputFormat is struct v4l2_format for a packed YUYV OUTPUT stream.
func v4l2OutputFormat(w, h int) []byte {
	b := make([]byte, v4l2FormatSize)
	le := binary.LittleEndian
	le.PutUint32(b[0:], v4l2BufTypeVideoOut)
	p := b[v4l2FormatUnionStart:]
	le.PutUint32(p[0:], uint32(w))
	le.PutUint32(p[4:], uint32(h))
	le.PutUint32(p[8:], v4l2PixFmtYUYV)
	le.PutUint32(p[12:], v4l2FieldNone)
	le.PutUint32(p[16:], uint32(w*2))   // bytesperline
	le.PutUint32(p[20:], uint32(w*h*2)) // sizeimage
	le.PutUint32(p[24:], v4l2ColorspaceSRGB)
	return b
}

type v4l2Output struct {
	f    *os.File
	path string
	size int
}

func openPlatformCamera(w, h int) (cameraOutput, error) {
	path, err := findCameraDevice()
	if err != nil {
		return nil, err
	}
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}
	fmtBuf := v4l2OutputFormat(w, h)
	if _, _, e := unix.Syscall(unix.SYS_IOCTL, f.Fd(), vidiocSFmt, uintptr(unsafe.Pointer(&fmtBuf[0]))); e != 0 {
		f.Close()
		return nil, fmt.Errorf("setting %dx%d YUYV on %s: %w", w, h, path, e)
	}
	if err := checkV4L2Format(fmtBuf, w, h); err != nil {
		f.Close()
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &v4l2Output{f: f, path: path, size: w * h * 2}, nil
}

// checkV4L2Format checks the format VIDIOC_S_FMT settled on, which the driver may adjust without
// failing: v4l2loopback keeps its old one while another program holds it or with keep_format.
// Frames are written as packed w×h YUYV, so anything else would garble them. Installing camera
// support again wouldn't help, hence a cameraFixError.
func checkV4L2Format(b []byte, w, h int) error {
	le := binary.LittleEndian
	p := b[v4l2FormatUnionStart:]
	gw, gh, pix := le.Uint32(p[0:]), le.Uint32(p[4:]), le.Uint32(p[8:])
	stride, size := le.Uint32(p[16:]), le.Uint32(p[20:])
	if gw != uint32(w) || gh != uint32(h) || pix != v4l2PixFmtYUYV || stride != uint32(w*2) || size < uint32(w*h*2) {
		return &cameraFixError{fmt.Sprintf("the camera device stays at %dx%d (format %#x, %d bytes per line), not %dx%d YUYV: "+
			"close the programs using it and share the camera again", gw, gh, pix, stride, w, h)}
	}
	return nil
}

func (o *v4l2Output) Write(frame []byte) error {
	if len(frame) != o.size {
		return fmt.Errorf("frame is %d bytes, want %d", len(frame), o.size)
	}
	_, err := o.f.Write(frame)
	return err
}

func (o *v4l2Output) Close() error   { return o.f.Close() }
func (o *v4l2Output) Device() string { return o.path }
