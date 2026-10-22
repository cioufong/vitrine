package win

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"testing"
)

func TestUseSerial(t *testing.T) {
	const path = `\\.\Global\org.vitrine.agent.0`
	for _, tc := range []struct {
		name string
		err  error
		want bool
	}{
		{"opened", nil, true},
		{"absent", &os.PathError{Op: "open", Path: path, Err: fs.ErrNotExist}, false},
		{"absent, wrapped", fmt.Errorf("probe: %w", &os.PathError{Op: "open", Path: path, Err: fs.ErrNotExist}), false},
		{"held by another process", &os.PathError{Op: "open", Path: path, Err: fs.ErrPermission}, true},
		{"other failure", &os.PathError{Op: "open", Path: path, Err: errors.New("device not ready")}, true},
	} {
		if got := UseSerial(tc.err); got != tc.want {
			t.Errorf("%s: UseSerial(%v) = %v, want %v", tc.name, tc.err, got, tc.want)
		}
	}
}
