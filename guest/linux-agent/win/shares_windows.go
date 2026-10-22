//go:build windows

package win

import (
	"errors"
	"fmt"
	"slices"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"

	"github.com/cioufong/vitrine/guest/linux-agent/drop"
	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

var (
	mpr                        = windows.NewLazySystemDLL("mpr.dll")
	procWNetAddConnection2W    = mpr.NewProc("WNetAddConnection2W")
	procWNetCancelConnection2W = mpr.NewProc("WNetCancelConnection2W")
	procWNetGetConnectionW     = mpr.NewProc("WNetGetConnectionW")
)

// netResource is NETRESOURCEW.
type netResource struct {
	Scope, Type, DisplayType, Usage uint32
	LocalName, RemoteName           *uint16
	Comment, Provider               *uint16
}

const (
	resourceTypeDisk  = 1
	connectTemporary  = 0x4
	errNotConnected   = 2250 // ERROR_NOT_CONNECTED
	errBadNetPath     = 53
	errNetUnreachable = 1231
	errBadNetName     = 67
	errNoNetwork      = 1222
)

// MountShares implements agent.ShareMounter: maps every share with a letter
// to that drive and opens a deviceless connection for the others (so UNC
// paths such as the drop folder work without asking for credentials).
//
// A new Samba run (other server or credentials, or an agent that does not
// know what it mapped before) replaces every connection to the server: after
// a resume the guest still holds sessions authenticated with the previous
// run's password. Otherwise the request is reconciled with what is mapped:
// unchanged drives are left alone (every agent reconnect re-sends the list,
// and a share added or removed on the host must not interrupt copies on the
// other drives), dropped or changed ones are disconnected without force — a
// drive with open files stays mapped and is reported — and new ones are added.
func (b *Backend) MountShares(m protocol.MountShares) error {
	b.ensureLinkedConnections()
	b.shareMu.Lock()
	last := b.lastMount
	b.shareMu.Unlock()
	plan := planShares(last, m, connectionOf)
	prefix := strings.ToLower(`\\` + m.Server + `\`)
	var errs []string
	resetIncomplete := false
	if plan.Reset {
		b.shareMu.Lock()
		b.lastMount = nil // the old mappings are about to go
		b.shareMu.Unlock()
		if last != nil && !strings.EqualFold(last.Server, m.Server) {
			errs = append(errs, cancelServerConnections(last.Server, last.Shares)...)
		}
		failed := cancelServerConnections(m.Server, m.Shares)
		errs = append(errs, failed...)
		resetIncomplete = len(failed) > 0
	}
	mapped := slices.Clone(plan.Keep)
	claimed := map[string]string{} // drive letter → share of this server it stays mapped to
	for _, s := range plan.Keep {
		if s.Letter != "" {
			claimed[s.Letter] = s.Name
		}
	}
	for _, o := range plan.Remove {
		name := uncPath(m.Server, o.Name, "") // deviceless connection
		if o.Letter != "" {
			name = o.Letter + ":"
		}
		if err := cancelConnection(name, false); err != nil && err != syscall.Errno(errNotConnected) {
			errs = append(errs, fmt.Sprintf("%s: %s left connected (%v)", o.Name, name, err))
			mapped = append(mapped, o)
			if o.Letter != "" {
				claimed[o.Letter] = o.Name
			}
			continue
		}
		b.opts.Logf("unmapped %s (%s)", name, o.Name)
	}
	user := `VITRINE\` + m.Username
	for _, s := range plan.Add {
		remote := uncPath(m.Server, s.Name, "")
		local := ""
		if s.Letter != "" {
			if !validLetter(s.Letter) {
				errs = append(errs, fmt.Sprintf("%s: bad drive letter %q", s.Name, s.Letter))
				continue
			}
			local = s.Letter + ":"
			if owner, ok := claimed[s.Letter]; ok {
				if owner != s.Name { // same share: its busy old mapping was reported above
					errs = append(errs, fmt.Sprintf("%s: drive %s still maps %s", s.Name, local, owner))
				}
				continue
			}
			if cur, ok := connectionOf(local); ok && strings.EqualFold(cur, remote) && !plan.Reset {
				// Already mapped (by hand, or by a request that reported an error). Not after a
				// reset: a mapping that survived it still uses the old run's credentials.
				claimed[s.Letter] = s.Name
				mapped = append(mapped, s)
				continue
			} else if ok && !strings.HasPrefix(strings.ToLower(cur), prefix) {
				errs = append(errs, fmt.Sprintf("%s: %s already maps %s", s.Name, local, cur))
				continue
			} else if ok {
				// Another share of this server, not mapped by the last request.
				if err := cancelConnection(local, false); err != nil && err != syscall.Errno(errNotConnected) {
					errs = append(errs, fmt.Sprintf("%s: %s still maps %s (%v)", s.Name, local, cur, err))
					continue
				}
			} else if driveInUse(s.Letter) {
				errs = append(errs, fmt.Sprintf("%s: drive %s is in use", s.Name, local))
				continue
			}
		}
		if err := addConnection(local, remote, user, m.Password); err != nil {
			errs = append(errs, fmt.Sprintf("%s: %v", s.Name, err))
			continue
		}
		if local != "" {
			claimed[s.Letter] = s.Name
			setDriveLabel(m.Server, s.Name, s.Name+" (Mac)")
		}
		mapped = append(mapped, s)
		b.opts.Logf("mapped %s %s", remote, local)
	}
	applied := cloneMount(m)
	applied.Shares = mapped
	b.shareMu.Lock()
	b.shareServer = m.Server
	if resetIncomplete {
		b.lastMount = nil // stale connections remain: the next request resets again
	} else {
		b.lastMount = &applied
	}
	b.shareMu.Unlock()
	if len(errs) > 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

// ensureLinkedConnections makes drives mapped by the (elevated) agent visible to
// non-elevated programs such as Explorer. UAC gives the two tokens separate drive
// maps unless EnableLinkedConnections is set; the setting applies from the next sign-in.
func (b *Backend) ensureLinkedConnections() {
	const path = `SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System`
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, path, registry.QUERY_VALUE|registry.SET_VALUE)
	if err != nil {
		return
	}
	defer k.Close()
	if v, _, err := k.GetIntegerValue("EnableLinkedConnections"); err == nil && v == 1 {
		return
	}
	if err := k.SetDWordValue("EnableLinkedConnections", 1); err == nil {
		b.opts.Logf("enabled linked connections: shared drives show in Explorer after the next sign-in")
	}
}

// cancelServerConnections force-drops every drive mapped to server and the
// UNC connections to the listed shares and IPC$: they belong to a Samba run
// whose credentials are gone. Connections to other servers are not touched.
// It returns what could not be dropped (even a forced cancel can fail).
func cancelServerConnections(server string, shares []protocol.MountShare) []string {
	var failed []string
	cancel := func(name string) {
		if err := cancelConnection(name, true); err != nil && err != syscall.Errno(errNotConnected) {
			failed = append(failed, fmt.Sprintf("%s still connected (%v)", name, err))
		}
	}
	prefix := strings.ToLower(`\\` + server + `\`)
	for l := 'D'; l <= 'Z'; l++ {
		local := string(l) + ":"
		if cur, ok := connectionOf(local); ok && strings.HasPrefix(strings.ToLower(cur), prefix) {
			cancel(local)
		}
	}
	for _, s := range shares {
		cancel(uncPath(server, s.Name, ""))
	}
	cancel(`\\` + server + `\IPC$`)
	return failed
}

// addConnection retries while the guest network comes up (the agent starts at
// logon, possibly before DHCP finished).
func addConnection(local, remote, user, password string) error {
	nr := netResource{Type: resourceTypeDisk, RemoteName: wstr(remote)}
	if local != "" {
		nr.LocalName = wstr(local)
	}
	var last error
	for attempt := 0; attempt < 12; attempt++ {
		r, _, _ := procWNetAddConnection2W.Call(uintptr(unsafe.Pointer(&nr)),
			uintptr(unsafe.Pointer(wstr(password))), uintptr(unsafe.Pointer(wstr(user))), connectTemporary)
		if r == 0 {
			return nil
		}
		last = syscall.Errno(r)
		switch r {
		case errBadNetPath, errNetUnreachable, errNoNetwork, errBadNetName:
			time.Sleep(time.Duration(attempt+1) * time.Second)
		default:
			return last
		}
	}
	return last
}

// cancelConnection disconnects a drive ("Z:") or a deviceless UNC connection.
// Without force it fails (ERROR_OPEN_FILES, ERROR_DEVICE_IN_USE) while files
// are open on it.
func cancelConnection(name string, force bool) error {
	f := uintptr(0)
	if force {
		f = 1
	}
	if r, _, _ := procWNetCancelConnection2W.Call(uintptr(unsafe.Pointer(wstr(name))), 0, f); r != 0 {
		return syscall.Errno(r)
	}
	return nil
}

// connectionOf returns the remote name a drive letter is mapped to.
func connectionOf(local string) (string, bool) {
	buf := make([]uint16, 512)
	n := uint32(len(buf))
	r, _, _ := procWNetGetConnectionW.Call(uintptr(unsafe.Pointer(wstr(local))), uintptr(unsafe.Pointer(&buf[0])),
		uintptr(unsafe.Pointer(&n)))
	if r != 0 {
		return "", false
	}
	return windows.UTF16ToString(buf), true
}

func driveInUse(letter string) bool {
	mask, err := windows.GetLogicalDrives()
	return err == nil && mask&(1<<uint(letter[0]-'A')) != 0
}

// setDriveLabel names the mapped drive in Explorer ("Docs (Mac)" instead of
// "Docs (\\10.0.2.4)").
func setDriveLabel(server, share, label string) {
	path := `Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2\##` + server + `#` + share
	k, _, err := registry.CreateKey(registry.CURRENT_USER, path, registry.SET_VALUE)
	if err != nil {
		return
	}
	defer k.Close()
	_ = k.SetStringValue("_LabelFromReg", label)
}

// ReceiveFiles implements agent.FileReceiver: copies dropped files from the
// host's transfer share to the Desktop, renaming on collisions.
func (b *Backend) ReceiveFiles(d protocol.FileDrop) error {
	b.shareMu.Lock()
	server := b.shareServer
	b.shareMu.Unlock()
	if server == "" {
		return errors.New("the transfer share isn't connected yet")
	}
	desktop, err := windows.KnownFolderPath(windows.FOLDERID_Desktop, 0)
	if err != nil {
		return err
	}
	from := func(rel string) string { return uncPath(server, "VitrineTransfer", rel) }
	return drop.Receive(d.Files, from, desktop, b.opts.Logf)
}

func wstr(s string) *uint16 {
	p, _ := windows.UTF16PtrFromString(s)
	return p
}
