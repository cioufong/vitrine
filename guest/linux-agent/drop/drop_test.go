package drop

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSafeRelative(t *testing.T) {
	for _, bad := range []string{"", "/etc/passwd", `\x`, "C:x", "a/../../b", "..", "./", `a\..\b`} {
		if _, err := SafeRelative(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
	if got, err := SafeRelative("batch//dir/file.txt"); err != nil || got != "batch/dir/file.txt" {
		t.Fatal(got, err)
	}
}

func TestUniqueName(t *testing.T) {
	taken := map[string]bool{"a.txt": true, "a (2).txt": true, "dir": true}
	exists := func(n string) bool { return taken[n] }
	for in, want := range map[string]string{"a.txt": "a (3).txt", "dir": "dir (2)", "new.png": "new.png"} {
		if got, _ := UniqueName(in, exists); got != want {
			t.Errorf("%s: got %s want %s", in, got, want)
		}
	}
}

func TestReceiveCopiesFilesAndFoldersWithoutOverwriting(t *testing.T) {
	src, dest := t.TempDir(), t.TempDir()
	write := func(p, s string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(src, "b1", "note.txt"), "new")
	write(filepath.Join(src, "b1", "pics", "x.png"), "png")
	write(filepath.Join(dest, "note.txt"), "old")

	from := func(rel string) string { return filepath.Join(src, filepath.FromSlash(rel)) }
	err := Receive([]string{"b1/note.txt", "b1/pics", "../escape"}, from, dest, nil)
	if err == nil || !strings.Contains(err.Error(), "unsafe drop path") {
		t.Fatalf("the unsafe path must be reported: %v", err)
	}
	read := func(p string) string { b, _ := os.ReadFile(filepath.Join(dest, p)); return string(b) }
	if read("note.txt") != "old" || read("note (2).txt") != "new" {
		t.Fatalf("collision: %q %q", read("note.txt"), read("note (2).txt"))
	}
	if read("pics/x.png") != "png" {
		t.Fatal("folder not copied")
	}
}

func TestXDGDesktop(t *testing.T) {
	home := "/home/u"
	for in, want := range map[string]string{
		"": "/home/u/Desktop",
		"# comment\nXDG_DESKTOP_DIR=\"$HOME/Bureau\"\n": "/home/u/Bureau",
		"XDG_DESKTOP_DIR=\"/data/desk\"":                "/data/desk",
		"XDG_DESKTOP_DIR=\"relative\"":                  "/home/u/Desktop",
	} {
		if got := XDGDesktop([]byte(in), home); got != want {
			t.Errorf("%q: got %s want %s", in, got, want)
		}
	}
}
