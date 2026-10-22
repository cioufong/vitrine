//go:build windows

package agent

import (
	"errors"
	"fmt"
	"os"
	"runtime"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// The Windows guest camera is a Media Foundation virtual camera (Windows 11, build 22000+):
// MFCreateVirtualCamera registers "Vitrine Camera" with the Frame Server, which loads the
// vitrine-camera.dll media source (guest/windows-camera) as LocalService. That source reads the
// frames this agent writes to cameraPipe and scales them to the format the app picked. No
// driver is involved.
const (
	CameraLabel    = "Vitrine Camera"
	cameraCLSID    = "{E0945567-3221-4186-B6DE-EAE89A9A73E4}" // guest/windows-camera/common.h
	cameraPipe     = `\\.\pipe\vitrine-camera`
	minCameraBuild = 22000
	// cameraLinger keeps the virtual camera after its output closes, so a resolution change
	// (close and reopen, camera.go) doesn't make guest apps lose the camera mid-call.
	cameraLinger = 5 * time.Second
)

var (
	camMFPlat                 = windows.NewLazySystemDLL("mfplat.dll")
	procMFStartup             = camMFPlat.NewProc("MFStartup")
	procMFShutdown            = camMFPlat.NewProc("MFShutdown")
	camSensorGroup            = windows.NewLazySystemDLL("mfsensorgroup.dll")
	procMFCreateVirtualCamera = camSensorGroup.NewProc("MFCreateVirtualCamera")
)

// cameraSupported: Windows 11 with the virtual camera API. Whether the media source is
// installed is checked when the camera starts, so a guest without it gets an installable
// error and the host can offer Install Camera Support.
func cameraSupported() bool {
	return windows.RtlGetVersion().BuildNumber >= minCameraBuild && procMFCreateVirtualCamera.Find() == nil
}

// cameraSourceInstalled checks the media source's COM registration. It must be machine-wide
// (HKLM): the Frame Server's LocalService account doesn't see the user's classes.
func cameraSourceInstalled() error {
	missing := errors.New("Vitrine Camera support isn't installed in this guest (install camera support from Vitrine)")
	k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Classes\CLSID\`+cameraCLSID+`\InprocServer32`, registry.QUERY_VALUE)
	if err != nil {
		return missing
	}
	defer k.Close()
	path, _, err := k.GetStringValue("")
	if err != nil || path == "" {
		return missing
	}
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("Vitrine Camera support is registered but %s is missing (install camera support from Vitrine)", path)
	}
	return nil
}

// winCamera is the virtual camera and its pipe, shared by successive outputs and torn down
// cameraLinger after the last one closes.
type winCamera struct {
	users int
	gen   int // bumped whenever the camera is taken again, invalidating a pending teardown
	pipe  *cameraPipeServer
	vcam  *virtualCamera
}

var (
	camMu      sync.Mutex
	camShared  *winCamera
	camClosing chan struct{} // closed when a lingering camera's teardown has finished
)

func openPlatformCamera(w, h int) (cameraOutput, error) {
	camMu.Lock()
	defer camMu.Unlock()
	if camClosing != nil {
		// Neither the pipe's first instance nor a camera with the same name and source can be
		// created again until the old ones are gone. A Frame Server slow to let go of the old
		// camera mustn't hold up the agent, so give up after a while; the host may retry.
		select {
		case <-camClosing:
			camClosing = nil
		case <-time.After(5 * time.Second):
			return nil, &cameraFixError{"the guest's previous Vitrine Camera is still shutting down; try again in a moment"}
		}
	}
	if camShared == nil {
		c, err := startWinCamera()
		if err != nil {
			return nil, err
		}
		camShared = c
	}
	camShared.users++
	camShared.gen++
	return &winCameraOutput{cam: camShared, w: w, h: h}, nil
}

func startWinCamera() (*winCamera, error) {
	if windows.RtlGetVersion().BuildNumber < minCameraBuild {
		return nil, &cameraFixError{"the guest's camera needs Windows 11: this version of Windows has no virtual camera support"}
	}
	if err := cameraSourceInstalled(); err != nil {
		return nil, err
	}
	// The pipe first, so the media source finds it as soon as the Frame Server starts it.
	p, err := listenCameraPipe()
	if err != nil {
		return nil, err
	}
	v, err := startVirtualCamera()
	if err != nil {
		p.close()
		return nil, err
	}
	return &winCamera{pipe: p, vcam: v}, nil
}

func (c *winCamera) release() {
	camMu.Lock()
	defer camMu.Unlock()
	c.users--
	if c.users > 0 {
		return
	}
	gen := c.gen
	time.AfterFunc(cameraLinger, func() {
		camMu.Lock()
		if camShared != c || c.users > 0 || c.gen != gen {
			camMu.Unlock()
			return
		}
		camShared = nil
		closing := make(chan struct{})
		camClosing = closing
		camMu.Unlock()
		c.vcam.close()
		c.pipe.close()
		// close stops waiting after five seconds; a new camera has to wait for the real end.
		<-c.vcam.done
		close(closing)
	})
}

type winCameraOutput struct {
	cam  *winCamera
	w, h int
	once sync.Once
}

// Write never blocks: each reader of the pipe takes the newest frame when it's ready.
func (o *winCameraOutput) Write(frame []byte) error {
	if len(frame) != o.w*o.h*2 {
		return fmt.Errorf("frame is %d bytes, want %d", len(frame), o.w*o.h*2)
	}
	o.cam.pipe.fan.send(o.w, o.h, frame)
	return nil
}

func (o *winCameraOutput) Close() error {
	o.once.Do(o.cam.release)
	return nil
}

func (o *winCameraOutput) Device() string { return CameraLabel }

// ---- the virtual camera ----

const (
	mfVersion = 0x00020070 // MF_SDK_VERSION<<16 | MF_API_VERSION
	// IMFVirtualCamera vtable slots: IUnknown (0-2), IMFAttributes (3-32), then
	// AddDeviceSourceInfo, AddProperty, AddRegistryEntry, Start, Stop, Remove, GetMediaSource,
	// SendCameraProperty, CreateSyncEvent, CreateSyncSemaphore, Shutdown (mfvirtualcamera.h).
	vcRelease  = 2
	vcStart    = 36
	vcRemove   = 38
	vcShutdown = 43

	hrSFalse             = 1
	hrAccessDenied       = 0x80070005
	hrClassNotRegistered = 0x80040154
)

// virtualCamera owns an IMFVirtualCamera on one locked OS thread (a COM multithreaded
// apartment) for its whole life. Its lifetime is the session's: Windows removes the camera when
// it is shut down or this process exits.
type virtualCamera struct {
	stop chan struct{}
	done chan struct{}
}

func startVirtualCamera() (*virtualCamera, error) {
	v := &virtualCamera{stop: make(chan struct{}), done: make(chan struct{})}
	started := make(chan error, 1)
	go v.run(started)
	if err := <-started; err != nil {
		<-v.done
		return nil, err
	}
	return v, nil
}

func (v *virtualCamera) run(started chan<- error) {
	defer close(v.done)
	runtime.LockOSThread() // never unlocked: the thread ends with this goroutine
	if err := windows.CoInitializeEx(0, windows.COINIT_MULTITHREADED); err != nil && err != syscall.Errno(hrSFalse) {
		started <- &cameraFixError{fmt.Sprintf("starting COM for the virtual camera: %v", err)}
		return
	}
	defer windows.CoUninitialize()
	if hr := hresult(procMFStartup.Call(mfVersion, 0)); hr < 0 {
		started <- &cameraFixError{"starting Media Foundation: " + hrString(hr)}
		return
	}
	defer procMFShutdown.Call()

	name, _ := windows.UTF16PtrFromString(CameraLabel)
	source, _ := windows.UTF16PtrFromString(cameraCLSID)
	var cam unsafe.Pointer // IMFVirtualCamera*
	hr := hresult(procMFCreateVirtualCamera.Call(
		0, // MFVirtualCameraType_SoftwareCameraSource
		0, // MFVirtualCameraLifetime_Session
		0, // MFVirtualCameraAccess_CurrentUser
		uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(source)),
		0, 0, // default categories (video camera, video, capture)
		uintptr(unsafe.Pointer(&cam))))
	runtime.KeepAlive(name)
	runtime.KeepAlive(source)
	if hr < 0 {
		started <- virtualCameraError("creating the virtual camera", hr)
		return
	}
	defer comCall(cam, vcRelease)
	if hr := comCall(cam, vcStart, 0); hr < 0 { // no callback: synchronous
		comCall(cam, vcShutdown)
		started <- virtualCameraError("starting the virtual camera", hr)
		return
	}
	started <- nil
	<-v.stop
	comCall(cam, vcRemove)
	comCall(cam, vcShutdown)
}

// close removes the camera; a wedged Frame Server can't hold the agent up for long.
func (v *virtualCamera) close() {
	close(v.stop)
	select {
	case <-v.done:
	case <-time.After(5 * time.Second):
	}
}

func virtualCameraError(what string, hr int32) error {
	switch uint32(hr) {
	case hrAccessDenied:
		return &cameraFixError{"Windows blocks camera access: turn on Settings ▸ Privacy & security ▸ Camera ▸ Camera access and \"Let desktop apps access your camera\""}
	case hrClassNotRegistered:
		return errors.New("Vitrine Camera support isn't installed in this guest (install camera support from Vitrine)")
	}
	return &cameraFixError{what + ": " + hrString(hr)}
}

func hresult(r uintptr, _ uintptr, _ error) int32 { return int32(uint32(r)) }

func hrString(hr int32) string {
	if uint32(hr)&0xFFFF0000 == 0x80070000 { // FACILITY_WIN32
		return fmt.Sprintf("%v (0x%08X)", syscall.Errno(uint32(hr)&0xFFFF), uint32(hr))
	}
	return fmt.Sprintf("HRESULT 0x%08X", uint32(hr))
}

// comCall calls vtable slot i of a COM object.
func comCall(obj unsafe.Pointer, i int, args ...uintptr) int32 {
	vtbl := *(*unsafe.Pointer)(obj)
	fn := *(*uintptr)(unsafe.Add(vtbl, uintptr(i)*unsafe.Sizeof(uintptr(0))))
	r, _, _ := syscall.SyscallN(fn, append([]uintptr{uintptr(obj)}, args...)...)
	return int32(uint32(r))
}

// ---- the frame pipe ----

const (
	pipeRejectRemoteClients = 0x00000008 // PIPE_REJECT_REMOTE_CLIENTS
	cameraPipeBuffer        = 1 << 20
)

// cameraPipeServer accepts the media source's connections on cameraPipe. Only SYSTEM, the
// Frame Server's LocalService, administrators and this user may open it; the first instance is
// created with FILE_FLAG_FIRST_PIPE_INSTANCE so no other program can be serving it already.
type cameraPipeServer struct {
	fan  *cameraFanout
	sa   *windows.SecurityAttributes
	stop windows.Handle
	ov   windows.Overlapped // the pending ConnectNamedPipe; on the heap, which doesn't move
	done chan struct{}
}

func listenCameraPipe() (*cameraPipeServer, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, fmt.Errorf("camera pipe: %w", err)
	}
	sddl := "D:P(A;;GA;;;SY)(A;;GA;;;LS)(A;;GA;;;BA)(A;;GA;;;" + user.User.Sid.String() + ")"
	// The Frame Server's service SIDs too, in case its token is restricted to them.
	for _, svc := range []string{`NT SERVICE\FrameServer`, `NT SERVICE\FrameServerMonitor`} {
		if sid, _, _, err := windows.LookupSID("", svc); err == nil {
			sddl += "(A;;GR;;;" + sid.String() + ")"
		}
	}
	sd, err := windows.SecurityDescriptorFromString(sddl)
	if err != nil {
		return nil, fmt.Errorf("camera pipe: %w", err)
	}
	s := &cameraPipeServer{
		fan:  newCameraFanout(),
		sa:   &windows.SecurityAttributes{Length: uint32(unsafe.Sizeof(windows.SecurityAttributes{})), SecurityDescriptor: sd},
		done: make(chan struct{}),
	}
	h, err := s.instance(true)
	if err != nil {
		if errors.Is(err, windows.ERROR_ACCESS_DENIED) || errors.Is(err, windows.ERROR_PIPE_BUSY) {
			return nil, &cameraFixError{"another program is already serving " + cameraPipe + " (is a second Vitrine agent running?)"}
		}
		return nil, &cameraFixError{fmt.Sprintf("creating %s: %v", cameraPipe, err)}
	}
	if s.stop, err = windows.CreateEvent(nil, 1, 0, nil); err != nil {
		windows.CloseHandle(h)
		return nil, err
	}
	if s.ov.HEvent, err = windows.CreateEvent(nil, 1, 0, nil); err != nil {
		windows.CloseHandle(h)
		windows.CloseHandle(s.stop)
		return nil, err
	}
	go s.accept(h)
	return s, nil
}

func (s *cameraPipeServer) instance(first bool) (windows.Handle, error) {
	flags := uint32(windows.PIPE_ACCESS_OUTBOUND | windows.FILE_FLAG_OVERLAPPED)
	if first {
		flags |= windows.FILE_FLAG_FIRST_PIPE_INSTANCE
	}
	name, _ := windows.UTF16PtrFromString(cameraPipe)
	return windows.CreateNamedPipe(name, flags, windows.PIPE_TYPE_BYTE|windows.PIPE_WAIT|pipeRejectRemoteClients,
		windows.PIPE_UNLIMITED_INSTANCES, cameraPipeBuffer, 0, 0, s.sa)
}

// accept hands each connected instance to the fanout and opens the next, until close.
func (s *cameraPipeServer) accept(h windows.Handle) {
	defer close(s.done)
	defer windows.CloseHandle(s.ov.HEvent)
	for {
		windows.ResetEvent(s.ov.HEvent)
		err := windows.ConnectNamedPipe(h, &s.ov)
		if err == windows.ERROR_IO_PENDING {
			ev, _ := windows.WaitForMultipleObjects([]windows.Handle{s.ov.HEvent, s.stop}, false, windows.INFINITE)
			var n uint32
			if ev != windows.WAIT_OBJECT_0 {
				windows.CancelIoEx(h, &s.ov)
				windows.GetOverlappedResult(h, &s.ov, &n, true)
				windows.CloseHandle(h)
				return
			}
			err = windows.GetOverlappedResult(h, &s.ov, &n, false)
		}
		if err == nil || err == windows.ERROR_PIPE_CONNECTED {
			c, cerr := newPipeConn(h)
			if cerr != nil {
				windows.CloseHandle(h)
			} else if !s.fan.add(c) {
				return
			}
		} else {
			windows.CloseHandle(h) // a client that came and went
		}
		for {
			if h, err = s.instance(false); err == nil {
				break
			}
			if ev, _ := windows.WaitForSingleObject(s.stop, 1000); ev == windows.WAIT_OBJECT_0 {
				return
			}
		}
	}
}

func (s *cameraPipeServer) close() {
	windows.SetEvent(s.stop)
	<-s.done
	s.fan.close()
	windows.CloseHandle(s.stop)
}

// pipeConn is one connected pipe instance: overlapped writes that Close can cancel.
type pipeConn struct {
	h      windows.Handle
	ov     windows.Overlapped
	mu     sync.Mutex // held for the length of a Write
	closed atomic.Bool
	once   sync.Once
}

func newPipeConn(h windows.Handle) (*pipeConn, error) {
	ev, err := windows.CreateEvent(nil, 1, 0, nil)
	if err != nil {
		return nil, err
	}
	c := &pipeConn{h: h}
	c.ov.HEvent = ev
	return c, nil
}

func (c *pipeConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	total := 0
	for total < len(p) {
		if c.closed.Load() {
			return total, os.ErrClosed
		}
		var n uint32
		windows.ResetEvent(c.ov.HEvent)
		err := windows.WriteFile(c.h, p[total:], nil, &c.ov)
		if err == nil || err == windows.ERROR_IO_PENDING {
			err = windows.GetOverlappedResult(c.h, &c.ov, &n, true)
		}
		if err != nil {
			return total, err
		}
		total += int(n)
	}
	return total, nil
}

func (c *pipeConn) Close() error {
	c.once.Do(func() {
		c.closed.Store(true)
		for !c.mu.TryLock() { // a write is in progress: cancel it until it gives up
			windows.CancelIoEx(c.h, nil)
			time.Sleep(5 * time.Millisecond)
		}
		windows.DisconnectNamedPipe(c.h)
		windows.CloseHandle(c.h)
		windows.CloseHandle(c.ov.HEvent)
		c.mu.Unlock()
	})
	return nil
}
