package desktop

import (
	"bytes"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestEntriesPrecedenceAndFilter(t *testing.T) {
	d := t.TempDir()
	user, sys := filepath.Join(d, "user"), filepath.Join(d, "sys")
	write(t, filepath.Join(sys, "mousepad.desktop"), "[Desktop Entry]\nType=Application\nName=Mousepad\nExec=mousepad %F\nIcon=org.xfce.mousepad\n[Desktop Action new]\nName=New\n")
	write(t, filepath.Join(sys, "hidden.desktop"), "[Desktop Entry]\nType=Application\nName=H\nExec=h\nNoDisplay=true\n")
	write(t, filepath.Join(sys, "link.desktop"), "[Desktop Entry]\nType=Link\nName=L\nURL=x\n")
	write(t, filepath.Join(sys, "firefox-esr.desktop"), "[Desktop Entry]\nType=Application\nName=Firefox ESR\nExec=/usr/lib/firefox-esr/firefox-esr %u\nStartupWMClass=firefox-esr\n")
	write(t, filepath.Join(user, "firefox-esr.desktop"), "[Desktop Entry]\nType=Application\nName=My Firefox\nExec=firefox-esr --private %u\n")
	es := Entries([]string{user, sys})
	var names []string
	for _, e := range es {
		names = append(names, e.Name)
	}
	if !reflect.DeepEqual(names, []string{"Mousepad", "My Firefox"}) {
		t.Fatalf("got %v", names)
	}
	if es[0].Name != "Mousepad" || es[0].Key() != "mousepad" || !es[0].Matches("Mousepad") {
		t.Fatalf("mousepad: key %q", es[0].Key())
	}
	if !es[1].Matches("firefox-esr") || es[1].Matches("firefox") {
		t.Fatal("firefox matching")
	}
}

func TestSplitExec(t *testing.T) {
	got := SplitExec(`"/opt/My App/run" --name "a b" 100%% %U`)
	want := []string{"/opt/My App/run", "--name", "a b", "100%"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %q", got)
	}
}

func TestFindIconPrefersSize(t *testing.T) {
	d := t.TempDir()
	old := IconRoots
	IconRoots = func() []string { return []string{d} }
	defer func() { IconRoots = old }()
	for _, s := range []string{"16x16", "48x48", "256x256"} {
		write(t, filepath.Join(d, "hicolor", s, "apps", "app.png"), "x")
	}
	p, err := FindIcon("app", 128)
	if err != nil || filepath.Base(filepath.Dir(filepath.Dir(p))) != "256x256" {
		t.Fatalf("got %s %v", p, err)
	}
	if _, err := FindIcon("missing", 64); err == nil {
		t.Fatal("missing icon found")
	}
}

func TestIconPNGScales(t *testing.T) {
	d := t.TempDir()
	old := IconRoots
	IconRoots = func() []string { return []string{d} }
	defer func() { IconRoots = old }()
	img := image.NewNRGBA(image.Rect(0, 0, 64, 64))
	for i := range img.Pix {
		img.Pix[i] = 200
	}
	img.Set(0, 0, color.NRGBA{255, 0, 0, 255})
	var buf bytes.Buffer
	png.Encode(&buf, img)
	write(t, filepath.Join(d, "hicolor", "64x64", "apps", "app.png"), buf.String())
	out, err := IconPNG("app", 32)
	if err != nil {
		t.Fatal(err)
	}
	dec, err := png.Decode(bytes.NewReader(out))
	if err != nil || dec.Bounds().Dx() != 32 || dec.Bounds().Dy() != 32 {
		t.Fatalf("bad scaled icon: %v %v", err, dec.Bounds())
	}
}

func TestLaunchRefusesOutsideDirs(t *testing.T) {
	if err := Launch("/etc/passwd", []string{"/usr/share/applications"}); err == nil {
		t.Fatal("launched a non-entry")
	}
	if err := Launch("/usr/share/applications/../../../tmp/x.desktop", []string{"/usr/share/applications"}); err == nil {
		t.Fatal("path traversal accepted")
	}
}
