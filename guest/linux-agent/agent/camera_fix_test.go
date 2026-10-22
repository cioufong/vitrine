package agent

import (
	"errors"
	"testing"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// A cameraFixError tells the host that Install Camera Support won't help; other errors leave
// installable unset.
func TestCameraStatusInstallable(t *testing.T) {
	for _, tc := range []struct {
		err  error
		want *bool
	}{
		{errors.New("Vitrine Camera support isn't installed"), nil},
		{&cameraFixError{"needs Windows 11"}, new(bool)},
	} {
		fakeCameras(t, tc.err)
		h, _ := newHost(t, New(&fakeBackend{}, false))
		expect[protocol.Hello](h)
		expect[protocol.DisplayInfo](h)
		h.send(protocol.CameraStart{Width: 2, Height: 2, FPS: 30})
		st := expect[protocol.CameraStatus](h)
		if st.Ready || st.Error != tc.err.Error() || (st.Installable == nil) != (tc.want == nil) ||
			(st.Installable != nil && *st.Installable != *tc.want) {
			t.Fatalf("%v: status %+v", tc.err, st)
		}
		h.conn.Close()
	}
}
