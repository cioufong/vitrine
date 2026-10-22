//go:build linux

package x11

import (
	"os"
	"path/filepath"

	"github.com/cioufong/vitrine/guest/linux-agent/drop"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// transferDir is the host's drop staging folder: VZ shares it as "Vitrine
// Transfer" inside the "vitrine" virtiofs tag, which cloud-init mounts at
// /mnt/vitrine. QEMU guests don't have it, so they don't announce "files".
const transferDir = "/mnt/vitrine/Vitrine Transfer"

func transferAvailable() bool {
	info, err := os.Stat(transferDir)
	return err == nil && info.IsDir()
}

// ReceiveFiles implements agent.FileReceiver: copies dropped files from the
// transfer folder to the user's Desktop, renaming on collisions.
func (b *Backend) ReceiveFiles(d protocol.FileDrop) error {
	home, err := os.UserHomeDir()
	if err != nil {
		return err
	}
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		config = filepath.Join(home, ".config")
	}
	userDirs, _ := os.ReadFile(filepath.Join(config, "user-dirs.dirs"))
	desktop := drop.XDGDesktop(userDirs, home)
	if err := os.MkdirAll(desktop, 0o755); err != nil {
		return err
	}
	from := func(rel string) string { return filepath.Join(transferDir, filepath.FromSlash(rel)) }
	return drop.Receive(d.Files, from, desktop, b.opts.Logf)
}
