//go:build linux

package x11

import (
	"fmt"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/shm"
	"golang.org/x/sys/unix"
)

// shmSegment is a SysV shared memory block attached to both us and the X
// server, so GetImage results arrive without copying through the socket.
type shmSegment struct {
	conn *xgb.Conn
	seg  shm.Seg
	data []byte
}

func newShmSegment(conn *xgb.Conn, size int) (*shmSegment, error) {
	id, err := unix.SysvShmGet(unix.IPC_PRIVATE, size, unix.IPC_CREAT|0o600)
	if err != nil {
		return nil, fmt.Errorf("shmget: %w", err)
	}
	// Mark for removal once both sides detach (after the server attached).
	defer unix.SysvShmCtl(id, unix.IPC_RMID, nil)
	data, err := unix.SysvShmAttach(id, 0, 0)
	if err != nil {
		return nil, fmt.Errorf("shmat: %w", err)
	}
	seg, err := shm.NewSegId(conn)
	if err != nil {
		unix.SysvShmDetach(data)
		return nil, err
	}
	// Checked so the server has attached before IPC_RMID runs. Fails for
	// remote displays or when the server lives in another IPC namespace.
	if err := shm.AttachChecked(conn, seg, uint32(id), false).Check(); err != nil {
		unix.SysvShmDetach(data)
		return nil, fmt.Errorf("XShmAttach: %v", err)
	}
	return &shmSegment{conn: conn, seg: seg, data: data}, nil
}

func (s *shmSegment) close() {
	shm.Detach(s.conn, s.seg)
	unix.SysvShmDetach(s.data)
}
