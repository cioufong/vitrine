//go:build linux

package x11

import (
	"errors"

	"github.com/cioufong/vitrine/guest/linux-agent/desktop"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// AppCatalog implements agent.AppProvider from the XDG .desktop entries.
func (b *Backend) AppCatalog(iconSize int) (protocol.AppCatalog, error) {
	var cat protocol.AppCatalog
	for _, e := range desktop.Entries(desktop.Dirs()) {
		key := e.Key()
		app := protocol.CatalogApp{ID: e.Path, Name: e.Name, Key: &key}
		if iconSize > 0 {
			app.PNG, _ = desktop.IconPNG(e.Icon, iconSize)
		}
		cat.Apps = append(cat.Apps, app)
	}
	return cat, nil
}

// AppIcon implements agent.AppProvider: key is a window's WM_CLASS class.
func (b *Backend) AppIcon(key string) ([]byte, error) {
	for _, e := range desktop.Entries(desktop.Dirs()) {
		if e.Matches(key) {
			return desktop.IconPNG(e.Icon, 256)
		}
	}
	return nil, errors.New("no application entry matches " + key)
}

// LaunchApp implements agent.AppProvider.
func (b *Backend) LaunchApp(id string) error { return desktop.Launch(id, desktop.Dirs()) }
