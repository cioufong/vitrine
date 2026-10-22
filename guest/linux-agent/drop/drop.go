// Package drop copies files the host placed in its transfer folder (dropped on
// the VM window) into a folder in the guest. Platform-independent; the
// backends only say where the transfer folder and the Desktop are.
package drop

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
)

// mu serializes drops: picking a free name and copying run under one lock so
// concurrent drops never pick the same destination (MkdirAll would silently
// merge folders).
var mu sync.Mutex

// Receive copies each host-relative path in files from source(rel) into dest,
// renaming on collisions. It reports every file that could not be copied.
func Receive(files []string, source func(rel string) string, dest string, logf func(string, ...any)) error {
	mu.Lock()
	defer mu.Unlock()
	var errs []string
	for _, f := range files {
		rel, err := SafeRelative(f)
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		name, err := UniqueName(path.Base(rel), func(n string) bool {
			_, err := os.Lstat(filepath.Join(dest, n))
			return err == nil
		})
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		if err := CopyTree(source(rel), filepath.Join(dest, name)); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", rel, err))
			continue
		}
		if logf != nil {
			logf("received %s", name)
		}
	}
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

// SafeRelative validates a host-supplied path relative to the transfer folder:
// no absolute paths, drive letters, ".." components or empty segments.
func SafeRelative(rel string) (string, error) {
	if rel == "" || strings.HasPrefix(rel, "/") || strings.HasPrefix(rel, `\`) || strings.Contains(rel, ":") {
		return "", fmt.Errorf("unsafe drop path %q", rel)
	}
	parts := strings.FieldsFunc(rel, func(r rune) bool { return r == '/' || r == '\\' })
	if len(parts) == 0 {
		return "", fmt.Errorf("unsafe drop path %q", rel)
	}
	for _, p := range parts {
		if p == "." || p == ".." {
			return "", fmt.Errorf("unsafe drop path %q", rel)
		}
	}
	return strings.Join(parts, "/"), nil
}

// UniqueName returns name, or "base (2).ext", "base (3).ext"… — the first one
// exists() reports free, the way Explorer and file managers name copies.
func UniqueName(name string, exists func(string) bool) (string, error) {
	if !exists(name) {
		return name, nil
	}
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	for i := 2; i < 1000; i++ {
		n := fmt.Sprintf("%s (%d)%s", base, i, ext)
		if !exists(n) {
			return n, nil
		}
	}
	return "", errors.New("no free name for " + name)
}

// CopyTree copies a file or a folder (recursively) to dst, which must not exist.
func CopyTree(src, dst string) error {
	info, err := os.Stat(src)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return copyFile(src, dst, info.Mode())
	}
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		if err := CopyTree(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

func copyFile(src, dst string, mode os.FileMode) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode.Perm()|0o200)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(dst)
		return err
	}
	return out.Close()
}

// XDGDesktop returns the Desktop folder named by an XDG user-dirs.dirs file
// (XDG_DESKTOP_DIR="$HOME/Schreibtisch"), or home/Desktop without one.
func XDGDesktop(userDirs []byte, home string) string {
	s := bufio.NewScanner(bytes.NewReader(userDirs))
	for s.Scan() {
		line := strings.TrimSpace(s.Text())
		v, ok := strings.CutPrefix(line, "XDG_DESKTOP_DIR=")
		if !ok {
			continue
		}
		v = strings.Trim(v, `"`)
		if rest, ok := strings.CutPrefix(v, "$HOME"); ok {
			v = home + rest
		}
		if filepath.IsAbs(v) {
			return v
		}
	}
	return filepath.Join(home, "Desktop")
}
