//go:build linux

package x11

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"time"

	"github.com/jezek/xgb"
	"github.com/jezek/xgb/randr"
	"github.com/jezek/xgb/xproto"
)

const (
	resizeDebounce = 300 * time.Millisecond
	resizePoll     = 2 * time.Second
)

// resizer makes X follow the display size the host asks for. virtio-gpu
// announces a new preferred mode (hotplug + EDID), but Xorg/Xfce do not
// apply it by themselves; spice-vdagent normally does, so we do it here.
type resizer struct {
	b       *Backend
	conn    *xgb.Conn
	root    xproto.Window
	trigger chan struct{}
	last    map[string]modeInfo // preferred mode last seen per output name
}

// StartAutoResize watches RandR (events plus a 2 s poll) and switches
// connected outputs to their preferred mode when it changes.
func (b *Backend) StartAutoResize() error {
	conn, err := xgb.NewConnDisplay(b.display)
	if err != nil {
		return err
	}
	if err := randr.Init(conn); err != nil {
		conn.Close()
		return fmt.Errorf("RandR unavailable: %w", err)
	}
	v, err := randr.QueryVersion(conn, 1, 5).Reply()
	if err != nil || (v.MajorVersion == 1 && v.MinorVersion < 2) {
		conn.Close()
		return fmt.Errorf("RandR 1.2+ required")
	}
	r := &resizer{b: b, conn: conn, root: b.root, trigger: make(chan struct{}, 1), last: map[string]modeInfo{}}
	mask := uint16(randr.NotifyMaskScreenChange | randr.NotifyMaskCrtcChange | randr.NotifyMaskOutputChange)
	if err := randr.SelectInputChecked(conn, b.root, mask).Check(); err != nil {
		b.opts.Logf("RandR events unavailable (%v); polling only", err)
	}
	go r.events()
	go r.loop()
	return nil
}

func (r *resizer) events() {
	for {
		ev, err := r.conn.WaitForEvent()
		if ev == nil && err == nil {
			return
		}
		switch ev.(type) {
		case randr.ScreenChangeNotifyEvent, randr.NotifyEvent:
			select {
			case r.trigger <- struct{}{}:
			default:
			}
		}
	}
}

// loop debounces RandR events (a hotplug arrives as a burst) and polls as a
// fallback. The first check runs on the first poll tick so the session (and
// the host connection) can settle first.
func (r *resizer) loop() {
	poll := time.NewTicker(resizePoll)
	defer poll.Stop()
	var debounce <-chan time.Time
	for {
		select {
		case <-r.trigger:
			if debounce == nil {
				debounce = time.After(resizeDebounce)
			}
		case <-debounce:
			debounce = nil
			r.check()
		case <-poll.C:
			r.check()
		}
	}
}

// check compares each connected output's preferred mode with its current one.
func (r *resizer) check() {
	// GetScreenResources (not ...Current) re-probes outputs, picking up the
	// new EDID mode list after a hotplug.
	res, err := randr.GetScreenResources(r.conn, r.root).Reply()
	if err != nil {
		return
	}
	modes := make(map[uint32]modeInfo, len(res.Modes))
	for _, m := range res.Modes {
		modes[m.Id] = modeInfo{ID: m.Id, W: int(m.Width), H: int(m.Height)}
	}
	for _, out := range res.Outputs {
		info, err := randr.GetOutputInfo(r.conn, out, res.ConfigTimestamp).Reply()
		if err != nil || info.Connection != randr.ConnectionConnected || len(info.Modes) == 0 {
			continue
		}
		ids := make([]uint32, len(info.Modes))
		for i, m := range info.Modes {
			ids[i] = uint32(m)
		}
		pref, ok := preferredMode(ids, int(info.NumPreferred), modes)
		if !ok {
			continue
		}
		name := string(info.Name)
		var cur modeInfo
		active := false
		if info.Crtc != 0 {
			if ci, err := randr.GetCrtcInfo(r.conn, info.Crtc, res.ConfigTimestamp).Reply(); err == nil && ci.Mode != 0 {
				cur, active = modeInfo{ID: uint32(ci.Mode), W: int(ci.Width), H: int(ci.Height)}, true
			}
		}
		last, seen := r.last[name]
		r.last[name] = pref
		if !shouldApply(seen, last, pref, cur, active) {
			continue
		}
		r.b.opts.Logf("display %s: applying preferred mode %dx%d (was %dx%d)", name, pref.W, pref.H, cur.W, cur.H)
		if err := r.apply(res, out, info, pref); err != nil {
			r.b.opts.Logf("RandR apply failed (%v); running xrandr --output %s --auto", err, name)
			r.xrandrAuto(name)
		}
		return // one output per pass; the resulting events trigger another check
	}
}

// apply lights the output's CRTC with mode at 0,0 and resizes the screen,
// growing it first so the CRTC always fits and shrinking it afterwards.
func (r *resizer) apply(res *randr.GetScreenResourcesReply, out randr.Output, info *randr.GetOutputInfoReply, mode modeInfo) error {
	crtc := info.Crtc
	var others []crtcBox
	for _, c := range res.Crtcs {
		ci, err := randr.GetCrtcInfo(r.conn, c, res.ConfigTimestamp).Reply()
		if err != nil {
			continue
		}
		if crtc == 0 && ci.NumOutputs == 0 && contains(info.Crtcs, c) {
			crtc = c // output is unlit: take a free CRTC it can drive
			continue
		}
		if c != crtc && ci.Mode != 0 {
			others = append(others, crtcBox{int(ci.X), int(ci.Y), int(ci.Width), int(ci.Height)})
		}
	}
	if crtc == 0 {
		return fmt.Errorf("no free CRTC for output %s", info.Name)
	}
	w, h, err := r.b.rootSize()
	if err != nil {
		return err
	}
	fw, fh := screenSizeFor(mode.W, mode.H, others)
	gw, gh := max(w, fw), max(h, fh)
	if gw != w || gh != h {
		mw, mh := screenMM(gw, gh)
		if err := randr.SetScreenSizeChecked(r.conn, r.root, uint16(gw), uint16(gh), mw, mh).Check(); err != nil {
			return fmt.Errorf("grow screen to %dx%d: %v", gw, gh, err)
		}
	}
	reply, err := randr.SetCrtcConfig(r.conn, crtc, xproto.TimeCurrentTime, res.ConfigTimestamp, 0, 0,
		randr.Mode(mode.ID), randr.RotationRotate0, []randr.Output{out}).Reply()
	if err != nil {
		return fmt.Errorf("SetCrtcConfig: %v", err)
	}
	if reply.Status != randr.SetConfigSuccess {
		return fmt.Errorf("SetCrtcConfig status %d", reply.Status)
	}
	if fw != gw || fh != gh {
		mw, mh := screenMM(fw, fh)
		if err := randr.SetScreenSizeChecked(r.conn, r.root, uint16(fw), uint16(fh), mw, mh).Check(); err != nil {
			return fmt.Errorf("shrink screen to %dx%d: %v", fw, fh, err)
		}
	}
	return nil
}

func (r *resizer) xrandrAuto(output string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "xrandr", "--output", output, "--auto")
	cmd.Env = append(os.Environ(), "DISPLAY="+r.b.display)
	if out, err := cmd.CombinedOutput(); err != nil {
		r.b.opts.Logf("xrandr --auto failed: %v %s", err, out)
	}
}

func contains(list []randr.Crtc, c randr.Crtc) bool {
	for _, x := range list {
		if x == c {
			return true
		}
	}
	return false
}
