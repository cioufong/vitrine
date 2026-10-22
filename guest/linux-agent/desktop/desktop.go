// Package desktop reads freedesktop.org .desktop entries and icon themes so the
// host can show guest apps in the Mac Dock and launch them.
package desktop

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"image"
	"image/draw"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Entry is one launchable application.
type Entry struct {
	Path           string // the .desktop file (the catalog id)
	Name           string
	Exec           string
	Icon           string
	StartupWMClass string
	NoDisplay      bool
}

// Dirs are the XDG application directories searched, most specific first.
func Dirs() []string {
	home, _ := os.UserHomeDir()
	dirs := []string{filepath.Join(home, ".local/share/applications")}
	data := os.Getenv("XDG_DATA_DIRS")
	if data == "" {
		data = "/usr/local/share:/usr/share"
	}
	for _, d := range strings.Split(data, ":") {
		if d != "" {
			dirs = append(dirs, filepath.Join(d, "applications"))
		}
	}
	return append(dirs, "/var/lib/flatpak/exports/share/applications")
}

// Parse reads the [Desktop Entry] group of a .desktop file. ok is false for
// entries that aren't visible applications.
func Parse(path string) (e Entry, ok bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return e, false
	}
	e.Path = path
	inEntry, typ, hidden := false, "", false
	sc := bufio.NewScanner(bytes.NewReader(data))
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if strings.HasPrefix(line, "[") {
			inEntry = line == "[Desktop Entry]"
			continue
		}
		k, v, found := strings.Cut(line, "=")
		if !inEntry || !found || strings.HasPrefix(line, "#") {
			continue
		}
		switch strings.TrimSpace(k) {
		case "Name":
			e.Name = strings.TrimSpace(v)
		case "Exec":
			e.Exec = strings.TrimSpace(v)
		case "Icon":
			e.Icon = strings.TrimSpace(v)
		case "StartupWMClass":
			e.StartupWMClass = strings.TrimSpace(v)
		case "Type":
			typ = strings.TrimSpace(v)
		case "NoDisplay":
			e.NoDisplay = strings.TrimSpace(v) == "true"
		case "Hidden":
			hidden = strings.TrimSpace(v) == "true"
		}
	}
	return e, typ == "Application" && !hidden && !e.NoDisplay && e.Name != "" && e.Exec != ""
}

// Entries lists visible applications; a file id in an earlier directory hides
// the same id in later ones (XDG precedence).
func Entries(dirs []string) []Entry {
	seen := map[string]bool{}
	var out []Entry
	for _, d := range dirs {
		files, _ := filepath.Glob(filepath.Join(d, "*.desktop"))
		sort.Strings(files)
		for _, f := range files {
			id := filepath.Base(f)
			if seen[id] {
				continue
			}
			seen[id] = true
			if e, ok := Parse(f); ok {
				out = append(out, e)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

// Key is what windows of this app report as their app name (WM_CLASS class):
// StartupWMClass when given, else the executable's base name.
func (e Entry) Key() string {
	if e.StartupWMClass != "" {
		return e.StartupWMClass
	}
	if args := SplitExec(e.Exec); len(args) > 0 {
		return filepath.Base(args[0])
	}
	return e.Name
}

// Matches reports whether a window whose WM_CLASS class is key belongs to e.
func (e Entry) Matches(key string) bool {
	k := strings.ToLower(key)
	if k == "" {
		return false
	}
	cands := []string{e.StartupWMClass, e.Name, strings.TrimSuffix(filepath.Base(e.Path), ".desktop")}
	if args := SplitExec(e.Exec); len(args) > 0 {
		cands = append(cands, filepath.Base(args[0]))
	}
	for _, c := range cands {
		c = strings.ToLower(c)
		if c != "" && (c == k || strings.HasSuffix(c, "."+k)) {
			return true
		}
	}
	return false
}

// SplitExec splits an Exec value into arguments (desktop-entry quoting) and
// drops field codes (%f, %U, …).
func SplitExec(s string) []string {
	var args []string
	var cur strings.Builder
	inQuote, escaped, have := false, false, false
	for _, r := range s {
		switch {
		case escaped:
			cur.WriteRune(r)
			escaped = false
		case r == '\\':
			escaped = true
		case r == '"':
			inQuote = !inQuote
			have = true
		case (r == ' ' || r == '\t') && !inQuote:
			if have || cur.Len() > 0 {
				args = append(args, cur.String())
			}
			cur.Reset()
			have = false
		default:
			cur.WriteRune(r)
		}
	}
	if have || cur.Len() > 0 {
		args = append(args, cur.String())
	}
	out := args[:0]
	for _, a := range args {
		if len(a) == 2 && a[0] == '%' {
			continue // field code
		}
		out = append(out, strings.ReplaceAll(a, "%%", "%"))
	}
	return out
}

// IconRoots are searched for themed icons.
var IconRoots = func() []string {
	home, _ := os.UserHomeDir()
	return []string{filepath.Join(home, ".local/share/icons"), filepath.Join(home, ".icons"),
		"/usr/share/icons", "/usr/local/share/icons"}
}

// PixmapDirs hold unthemed fallback icons.
var PixmapDirs = []string{"/usr/share/pixmaps"}

// FindIcon resolves an Icon= value to a PNG file, preferring the smallest
// size ≥ want (else the largest). SVG-only icons are rendered with rsvg-convert
// when it is installed.
func FindIcon(name string, want int) (string, error) {
	if name == "" {
		return "", errors.New("no icon")
	}
	if filepath.IsAbs(name) {
		return name, nil
	}
	type cand struct {
		path string
		size int
	}
	var pngs []cand
	var svg string
	for _, root := range IconRoots() {
		themes, _ := os.ReadDir(root)
		for _, t := range themes {
			matches, _ := filepath.Glob(filepath.Join(root, t.Name(), "*", "apps", name+".*"))
			matches2, _ := filepath.Glob(filepath.Join(root, t.Name(), "apps", "*", name+".*")) // Adwaita-style layout
			for _, m := range append(matches, matches2...) {
				switch strings.ToLower(filepath.Ext(m)) {
				case ".png":
					pngs = append(pngs, cand{m, sizeFromPath(m)})
				case ".svg":
					if svg == "" {
						svg = m
					}
				}
			}
		}
	}
	for _, d := range PixmapDirs {
		if p := filepath.Join(d, name+".png"); fileExists(p) {
			pngs = append(pngs, cand{p, 0})
		}
	}
	if len(pngs) > 0 {
		sort.Slice(pngs, func(i, j int) bool { return pngs[i].size < pngs[j].size })
		for _, c := range pngs {
			if c.size >= want {
				return c.path, nil
			}
		}
		if svg == "" || pngs[len(pngs)-1].size >= want/2 {
			return pngs[len(pngs)-1].path, nil
		}
	}
	if svg != "" {
		return svg, nil
	}
	return "", fmt.Errorf("icon %q not found", name)
}

func sizeFromPath(p string) int {
	for _, part := range strings.Split(p, string(filepath.Separator)) {
		w, _, ok := strings.Cut(part, "x")
		if n, err := strconv.Atoi(w); ok && err == nil {
			return n
		}
	}
	return 0
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

// IconPNG returns the icon scaled to size×size as PNG.
func IconPNG(name string, size int) ([]byte, error) {
	path, err := FindIcon(name, size)
	if err != nil {
		return nil, err
	}
	var data []byte
	if strings.EqualFold(filepath.Ext(path), ".svg") {
		rsvg, err := exec.LookPath("rsvg-convert")
		if err != nil {
			return nil, errors.New("svg icon and no rsvg-convert")
		}
		if data, err = exec.Command(rsvg, "-w", strconv.Itoa(size), "-h", strconv.Itoa(size), path).Output(); err != nil {
			return nil, err
		}
		return data, nil
	}
	if data, err = os.ReadFile(path); err != nil {
		return nil, err
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	if b := img.Bounds(); b.Dx() == size && b.Dy() == size {
		return data, nil
	}
	var out bytes.Buffer
	if err := png.Encode(&out, Scale(img, size)); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// Scale resizes img to size×size (box filter when shrinking, nearest when growing).
func Scale(img image.Image, size int) *image.NRGBA {
	src := image.NewNRGBA(img.Bounds())
	draw.Draw(src, src.Bounds(), img, img.Bounds().Min, draw.Src)
	sw, sh := src.Bounds().Dx(), src.Bounds().Dy()
	dst := image.NewNRGBA(image.Rect(0, 0, size, size))
	if sw == 0 || sh == 0 {
		return dst
	}
	for y := 0; y < size; y++ {
		y0, y1 := y*sh/size, max((y+1)*sh/size, y*sh/size+1)
		for x := 0; x < size; x++ {
			x0, x1 := x*sw/size, max((x+1)*sw/size, x*sw/size+1)
			var r, g, b, a, n int
			for yy := y0; yy < y1; yy++ {
				for xx := x0; xx < x1; xx++ {
					i := yy*src.Stride + xx*4
					pa := int(src.Pix[i+3])
					r += int(src.Pix[i]) * pa
					g += int(src.Pix[i+1]) * pa
					b += int(src.Pix[i+2]) * pa
					a += pa
					n++
				}
			}
			j := y*dst.Stride + x*4
			if a > 0 {
				dst.Pix[j], dst.Pix[j+1], dst.Pix[j+2] = uint8(r/a), uint8(g/a), uint8(b/a)
			}
			dst.Pix[j+3] = uint8(a / n)
		}
	}
	return dst
}

// Launch starts the app of a .desktop file that lives in one of dirs.
func Launch(path string, dirs []string) error {
	clean := filepath.Clean(path)
	inDir := false
	for _, d := range dirs {
		if filepath.Dir(clean) == filepath.Clean(d) {
			inDir = true
		}
	}
	if !inDir || filepath.Ext(clean) != ".desktop" {
		return fmt.Errorf("%s is not an application entry", path)
	}
	if gio, err := exec.LookPath("gio"); err == nil {
		return start(exec.Command(gio, "launch", clean))
	}
	e, ok := Parse(clean)
	if !ok {
		return fmt.Errorf("%s is not launchable", path)
	}
	args := SplitExec(e.Exec)
	if len(args) == 0 {
		return fmt.Errorf("%s has no command", path)
	}
	return start(exec.Command(args[0], args[1:]...))
}

// start runs cmd in the background and reaps it when it exits, so launched
// apps never linger as zombies of the long-lived agent.
func start(cmd *exec.Cmd) error {
	if err := cmd.Start(); err != nil {
		return err
	}
	go cmd.Wait()
	return nil
}

// Names caches display names of running apps by WM_CLASS ("Xfce4-terminal" →
// "Xfce Terminal"), re-reading the entries at most once a minute.
type Names struct {
	mu      sync.Mutex
	entries []Entry
	loaded  time.Time
	byKey   map[string]string
}

// Lookup returns the entry name for a window's WM_CLASS class, or "" if none matches.
func (n *Names) Lookup(class string) string {
	n.mu.Lock()
	defer n.mu.Unlock()
	if time.Since(n.loaded) > time.Minute {
		n.entries, n.loaded, n.byKey = Entries(Dirs()), time.Now(), map[string]string{}
	}
	if name, ok := n.byKey[class]; ok {
		return name
	}
	name := ""
	for _, e := range n.entries {
		if e.Matches(class) {
			name = e.Name
			break
		}
	}
	n.byKey[class] = name
	return name
}
