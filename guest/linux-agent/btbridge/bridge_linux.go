//go:build linux

package btbridge

import (
	"fmt"
	"io"
	"os"
	"os/exec"

	"golang.org/x/sys/unix"
)

const (
	nHCI             = 15         // N_HCI line discipline
	hciUARTSetProto  = 0x400455C8 // _IOW('U', 200, int)
	hciUARTGetDevice = 0x800455CA // _IOR('U', 202, int)
	hciUARTH4        = 0
)

func prepare() { exec.Command("modprobe", "hci_uart").Run() }

// controller is the pseudo-terminal pair carrying one HCI controller: the
// kernel's side runs the hci_uart line discipline, the bridge reads and writes
// the other.
type controller struct {
	master *os.File
	slave  int
}

func (c *controller) Read(p []byte) (int, error)  { return c.master.Read(p) }
func (c *controller) Write(p []byte) (int, error) { return c.master.Write(p) }

// Close detaches the line discipline (the kernel removes the controller) and
// wakes any blocked Read.
func (c *controller) Close() error {
	unix.Close(c.slave)
	return c.master.Close()
}

func attach() (io.ReadWriteCloser, string, error) {
	// Non-blocking, so the runtime poller serves it and Close interrupts reads.
	m, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC|unix.O_NONBLOCK, 0)
	if err != nil {
		return nil, "", fmt.Errorf("opening /dev/ptmx: %w", err)
	}
	master := os.NewFile(uintptr(m), "/dev/ptmx")
	fail := func(what string, err error) (io.ReadWriteCloser, string, error) {
		master.Close()
		return nil, "", fmt.Errorf("%s: %w", what, err)
	}
	if err := unix.IoctlSetPointerInt(m, unix.TIOCSPTLCK, 0); err != nil {
		return fail("unlocking the pty", err)
	}
	n, err := unix.IoctlGetUint32(m, unix.TIOCGPTN)
	if err != nil {
		return fail("naming the pty", err)
	}
	s, err := unix.Open(fmt.Sprintf("/dev/pts/%d", n), unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return fail("opening the pty", err)
	}
	c := &controller{master: master, slave: s}
	fail = func(what string, err error) (io.ReadWriteCloser, string, error) {
		c.Close()
		return nil, "", fmt.Errorf("%s: %w", what, err)
	}
	t, err := unix.IoctlGetTermios(s, unix.TCGETS)
	if err != nil {
		return fail("reading the pty's settings", err)
	}
	// cfmakeraw: bytes pass untouched.
	t.Iflag &^= unix.IGNBRK | unix.BRKINT | unix.PARMRK | unix.ISTRIP | unix.INLCR | unix.IGNCR | unix.ICRNL | unix.IXON
	t.Oflag &^= unix.OPOST
	t.Lflag &^= unix.ECHO | unix.ECHONL | unix.ICANON | unix.ISIG | unix.IEXTEN
	t.Cflag &^= unix.CSIZE | unix.PARENB
	t.Cflag |= unix.CS8
	t.Cc[unix.VMIN], t.Cc[unix.VTIME] = 1, 0
	if err := unix.IoctlSetTermios(s, unix.TCSETS, t); err != nil {
		return fail("making the pty raw", err)
	}
	if err := unix.IoctlSetPointerInt(s, unix.TIOCSETD, nHCI); err != nil {
		return fail("attaching hci_uart (is the hci_uart module available?)", err)
	}
	if err := unix.IoctlSetInt(s, hciUARTSetProto, hciUARTH4); err != nil {
		return fail("selecting the H4 protocol", err)
	}
	id, _, errno := unix.Syscall(unix.SYS_IOCTL, uintptr(s), hciUARTGetDevice, 0)
	if errno != 0 {
		return fail("finding the new controller", errno)
	}
	return c, fmt.Sprintf("hci%d", id), nil
}
