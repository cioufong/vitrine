//go:build windows

package transport

import (
	"io"
	"os"
	"sync"
	"sync/atomic"

	"golang.org/x/sys/windows"
)

// serialPort is a virtio-serial port opened through the Red Hat VirtIO Serial
// driver (vioser), e.g. \\.\Global\org.vitrine.agent.0. The handle is
// overlapped: synchronous I/O on one handle is serialized by the I/O manager,
// so a blocked read would stall every write. Reads and writes each have their
// own OVERLAPPED and event and run concurrently; Close cancels both.
type serialPort struct {
	h    windows.Handle
	path string

	closed atomic.Bool

	rmu  sync.Mutex // one read at a time; held for the life of the I/O
	rov  windows.Overlapped
	rbuf []byte // the in-flight read buffer, kept on the heap (see do)

	wmu  sync.Mutex // one write at a time
	wov  windows.Overlapped
	wbuf []byte
}

// OpenSerial opens a vioser port as an already-connected byte stream. Share
// mode 0: no other process can open the port while the agent holds it. A read
// returning EOF or an error means the host side is (or was) detached; callers
// reopen with a backoff, as on Linux.
func OpenSerial(path string) (io.ReadWriteCloser, error) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	h, err := windows.CreateFile(name, windows.GENERIC_READ|windows.GENERIC_WRITE, 0, nil,
		windows.OPEN_EXISTING, windows.FILE_FLAG_OVERLAPPED, 0)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	s := &serialPort{h: h, path: path}
	for _, ov := range []*windows.Overlapped{&s.rov, &s.wov} {
		// Manual reset: ReadFile/WriteFile reset it when an operation starts.
		ev, err := windows.CreateEvent(nil, 1, 0, nil)
		if err != nil {
			s.release()
			return nil, &os.PathError{Op: "open", Path: path, Err: err}
		}
		ov.HEvent = ev
	}
	return s, nil
}

// maxSerialIO bounds one ReadFile/WriteFile: vioser fails large requests with
// ERROR_NO_SYSTEM_RESOURCES ("Insufficient system resources exist…"), seen as
// the session dropping right after a host connected with a big queue pending.
const maxSerialIO = 32 << 10

func (s *serialPort) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	s.rmu.Lock()
	defer s.rmu.Unlock()
	if len(p) > maxSerialIO {
		p = p[:maxSerialIO]
	}
	n, err := s.do(p, &s.rbuf, &s.rov, windows.ReadFile)
	switch {
	case err == windows.ERROR_HANDLE_EOF || err == windows.ERROR_BROKEN_PIPE:
		return n, io.EOF
	case err != nil:
		return n, s.wrap("read", err)
	case n == 0:
		// A successful empty read is how the driver reports the host side
		// gone; returning (0, nil) would make the reader spin.
		return 0, io.EOF
	}
	return n, nil
}

func (s *serialPort) Write(p []byte) (int, error) {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	written := 0
	for written < len(p) {
		n, err := s.do(p[written:min(len(p), written+maxSerialIO)], &s.wbuf, &s.wov, windows.WriteFile)
		written += n
		if err != nil {
			return written, s.wrap("write", err)
		}
		if n == 0 {
			return written, io.ErrShortWrite
		}
	}
	return written, nil
}

// do runs one overlapped ReadFile/WriteFile to completion. The caller holds
// the direction's mutex, so ov and the event are not shared. buf is parked in
// a field of the (heap) port while the kernel may still write to it: the
// store makes p escape at every call site, so it can never be on a goroutine
// stack that moves while the I/O is pending.
func (s *serialPort) do(p []byte, buf *[]byte, ov *windows.Overlapped,
	f func(windows.Handle, []byte, *uint32, *windows.Overlapped) error) (int, error) {
	if s.closed.Load() {
		return 0, os.ErrClosed
	}
	*buf = p
	defer func() { *buf = nil }()
	ev := ov.HEvent
	*ov = windows.Overlapped{HEvent: ev}
	var n uint32
	err := f(s.h, p, &n, ov)
	if err == nil || err == windows.ERROR_IO_PENDING {
		// Close may have run between the check above and the I/O starting,
		// in which case its CancelIoEx found nothing to cancel.
		if s.closed.Load() {
			windows.CancelIoEx(s.h, ov)
		}
		err = windows.GetOverlappedResult(s.h, ov, &n, true)
	}
	if err != nil && s.closed.Load() {
		return int(n), os.ErrClosed
	}
	return int(n), err
}

func (s *serialPort) wrap(op string, err error) error {
	if err == os.ErrClosed {
		return err
	}
	return &os.PathError{Op: op, Path: s.path, Err: err}
}

// Close cancels any pending read or write (unblocking the reader), waits for
// them to return, then releases the handle.
func (s *serialPort) Close() error {
	if !s.closed.CompareAndSwap(false, true) {
		return os.ErrClosed
	}
	windows.CancelIoEx(s.h, nil) // ERROR_NOT_FOUND when nothing is pending
	s.rmu.Lock()
	s.wmu.Lock()
	defer s.wmu.Unlock()
	defer s.rmu.Unlock()
	return s.release()
}

func (s *serialPort) release() error {
	for _, ev := range []windows.Handle{s.rov.HEvent, s.wov.HEvent} {
		if ev != 0 {
			windows.CloseHandle(ev)
		}
	}
	return windows.CloseHandle(s.h)
}
