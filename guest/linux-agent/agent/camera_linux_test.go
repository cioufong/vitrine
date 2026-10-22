//go:build linux

package agent

import (
	"encoding/binary"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestFindCameraDevice(t *testing.T) {
	dir := t.TempDir()
	for name, label := range map[string]string{"video0": "Integrated Webcam\n", "video3": CameraLabel + "\n"} {
		os.MkdirAll(filepath.Join(dir, name), 0o755)
		os.WriteFile(filepath.Join(dir, name, "name"), []byte(label), 0o644)
	}
	old := cameraSysfs
	cameraSysfs = dir
	t.Cleanup(func() { cameraSysfs = old })
	if dev, err := findCameraDevice(); err != nil || dev != "/dev/video3" {
		t.Fatalf("got %q, %v", dev, err)
	}
	os.Remove(filepath.Join(dir, "video3", "name"))
	if _, err := findCameraDevice(); err == nil {
		t.Fatal("found a camera that isn't there")
	}
}

func TestV4L2OutputFormat(t *testing.T) {
	b := v4l2OutputFormat(1280, 720)
	le := binary.LittleEndian
	if len(b) != 208 || le.Uint32(b) != 2 {
		t.Fatalf("len %d type %d", len(b), le.Uint32(b))
	}
	want := []uint32{1280, 720, 0x56595559, 1, 2560, 1280 * 720 * 2, 8}
	for i, w := range want {
		if got := le.Uint32(b[8+4*i:]); got != w {
			t.Errorf("field %d = %d, want %d", i, got, w)
		}
	}
}

// The driver may answer VIDIOC_S_FMT with another format without failing.
func TestCheckV4L2Format(t *testing.T) {
	if err := checkV4L2Format(v4l2OutputFormat(640, 480), 640, 480); err != nil {
		t.Fatal(err)
	}
	var fixed *cameraFixError
	if err := checkV4L2Format(v4l2OutputFormat(1280, 720), 640, 480); !errors.As(err, &fixed) {
		t.Fatalf("kept size accepted: %v", err)
	}
	b := v4l2OutputFormat(640, 480)
	binary.LittleEndian.PutUint32(b[8+8:], 0x47504A4D) // 'MJPG'
	if err := checkV4L2Format(b, 640, 480); err == nil {
		t.Fatal("other pixel format accepted")
	}
	b = v4l2OutputFormat(640, 480)
	binary.LittleEndian.PutUint32(b[8+16:], 640*2+64) // padded lines
	if err := checkV4L2Format(b, 640, 480); err == nil {
		t.Fatal("padded stride accepted")
	}
}

// TestRealCameraDevice writes a pattern to the installed virtual camera and reads it back the way
// a webcam app would. Opt-in (VITRINE_CAMERA_DEVICE_TEST=1): it needs v4l2loopback and ffmpeg.
func TestRealCameraDevice(t *testing.T) {
	if os.Getenv("VITRINE_CAMERA_DEVICE_TEST") != "1" {
		t.Skip("set VITRINE_CAMERA_DEVICE_TEST=1 in a guest with camera support and ffmpeg")
	}
	const w, h = 320, 240
	out, err := openPlatformCamera(w, h)
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	// Left half bright, right half dark, no colour.
	frame := make([]byte, w*h*2)
	for i := 0; i < len(frame); i += 2 {
		frame[i], frame[i+1] = 40, 128
		if (i/2)%w < w/2 {
			frame[i] = 200
		}
	}
	stop := make(chan struct{})
	defer close(stop)
	go func() {
		for {
			select {
			case <-stop:
				return
			case <-time.After(33 * time.Millisecond):
				out.Write(frame)
			}
		}
	}()
	gray, err := exec.Command("ffmpeg", "-v", "error", "-f", "v4l2", "-i", out.Device(),
		"-frames:v", "1", "-pix_fmt", "gray", "-f", "rawvideo", "-").Output()
	if err != nil {
		t.Fatalf("ffmpeg: %v", err)
	}
	if len(gray) != w*h {
		t.Fatalf("captured %d bytes, want %d", len(gray), w*h)
	}
	row := gray[(h/2)*w:]
	if l, r := row[w/4], row[3*w/4]; l < 180 || r > 60 {
		t.Fatalf("pattern didn't survive: left %d right %d", l, r)
	}
}
