// Package btbridge is the root half of Bluetooth sharing in Linux guests
// (`vitrine-agent bluetooth-bridge`). For each connection to its socket it
// adds an HCI controller to the kernel, a pseudo-terminal running the hci_uart
// line discipline, and relays the controller's H4 traffic between the
// connection and the terminal; closing the connection removes the controller.
// The agent, in the user's session, holds that connection and carries the
// traffic on to the host, which emulates the controller over the Mac's
// Bluetooth. Root is needed only to attach the line discipline.
package btbridge

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
)

// Serve listens on socket, which only owner (a user name or uid) may open,
// and serves one controller at a time: a new connection replaces the current
// one once that controller is gone.
func Serve(socket, owner string) error {
	uid, err := lookupUID(owner)
	if err != nil {
		return err
	}
	prepare()
	if err := os.MkdirAll(filepath.Dir(socket), 0o755); err != nil {
		return err
	}
	os.Remove(socket)
	l, err := net.Listen("unix", socket)
	if err != nil {
		return err
	}
	defer l.Close()
	if err := os.Chown(socket, uid, -1); err != nil {
		return err
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		return err
	}
	var current net.Conn
	done := make(chan struct{})
	close(done)
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		if current != nil {
			current.Close()
		}
		<-done
		current, done = c, make(chan struct{})
		go func(c net.Conn, done chan struct{}) {
			defer close(done)
			serve(c)
		}(c, done)
	}
}

func lookupUID(owner string) (int, error) {
	if uid, err := strconv.Atoi(owner); err == nil {
		return uid, nil
	}
	u, err := user.Lookup(owner)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(u.Uid)
}

func serve(c net.Conn) {
	defer c.Close()
	tty, dev, err := attach()
	if err != nil {
		fmt.Fprintf(c, "error %v\n", err)
		return
	}
	defer tty.Close()
	if _, err := fmt.Fprintf(c, "ok %s\n", dev); err != nil {
		return
	}
	done := make(chan struct{}, 2)
	go func() { io.Copy(c, tty); done <- struct{}{} }()
	go func() { io.Copy(tty, c); done <- struct{}{} }()
	<-done
}
