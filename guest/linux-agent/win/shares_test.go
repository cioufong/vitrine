package win

import (
	"slices"
	"testing"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

func TestUNCPath(t *testing.T) {
	if got := uncPath("10.0.2.4", "VitrineTransfer", "b/a b.txt"); got != `\\10.0.2.4\VitrineTransfer\b\a b.txt` {
		t.Fatal(got)
	}
	if got := uncPath("10.0.2.4", "Docs", ""); got != `\\10.0.2.4\Docs` {
		t.Fatal(got)
	}
}

func TestPremultipliedToStraight(t *testing.T) {
	// BGRA: half-transparent red (premultiplied 128,0,0 @ 128) and opaque blue.
	img := premultipliedBGRAToNRGBA([]byte{0, 0, 128, 128, 255, 0, 0, 255}, 2, 1)
	if got := img.Pix[0:4]; got[0] != 255 || got[1] != 0 || got[2] != 0 || got[3] != 128 {
		t.Fatalf("pixel 0: %v", got)
	}
	if got := img.Pix[4:8]; got[0] != 0 || got[2] != 255 || got[3] != 255 {
		t.Fatalf("pixel 1: %v", got)
	}
	// No alpha at all: opaque.
	img = premultipliedBGRAToNRGBA([]byte{10, 20, 30, 0}, 1, 1)
	if img.Pix[3] != 255 || img.Pix[0] != 30 {
		t.Fatalf("no-alpha pixel: %v", img.Pix)
	}
}

func TestValidLetter(t *testing.T) {
	for s, ok := range map[string]bool{"Z": true, "D": true, "C": false, "z": false, "ZZ": false, "": false} {
		if validLetter(s) != ok {
			t.Errorf("%q", s)
		}
	}
}

func TestPlanShares(t *testing.T) {
	docs := protocol.MountShare{Letter: "Z", Name: "Docs"}
	music := protocol.MountShare{Letter: "Y", Name: "Music"}
	transfer := protocol.MountShare{Name: "VitrineTransfer", ReadOnly: true}
	last := protocol.MountShares{Server: "10.0.2.4", Username: "u", Password: "p",
		Shares: []protocol.MountShare{docs, transfer}}
	// What the drives map to now: by default exactly last.
	drives := func(m map[string]string) func(string) (string, bool) {
		return func(local string) (string, bool) { r, ok := m[local]; return r, ok }
	}
	mapped := map[string]string{"Z:": `\\10.0.2.4\docs`} // case-insensitive, like Windows
	with := func(shares ...protocol.MountShare) protocol.MountShares {
		m := cloneMount(last)
		m.Shares = shares
		return m
	}
	readOnlyDocs := docs
	readOnlyDocs.ReadOnly = true
	movedDocs := docs
	movedDocs.Letter = "X"
	otherOnZ := protocol.MountShare{Letter: "Z", Name: "Music"}
	sh := func(s ...protocol.MountShare) []protocol.MountShare { return s }

	for _, tc := range []struct {
		name              string
		last              *protocol.MountShares
		next              protocol.MountShares
		drives            map[string]string
		keep, remove, add []protocol.MountShare
	}{
		{name: "unchanged", last: &last, next: cloneMount(last), drives: mapped, keep: sh(docs, transfer)},
		{name: "added", last: &last, next: with(docs, music, transfer), drives: mapped,
			keep: sh(docs, transfer), add: sh(music)},
		{name: "removed letter", last: &last, next: with(transfer), drives: mapped,
			keep: sh(transfer), remove: sh(docs)},
		{name: "removed UNC share", last: &last, next: with(docs), drives: mapped,
			keep: sh(docs), remove: sh(transfer)},
		{name: "other share on letter", last: &last, next: with(otherOnZ, transfer), drives: mapped,
			keep: sh(transfer), remove: sh(docs), add: sh(otherOnZ)},
		{name: "readOnly changed", last: &last, next: with(readOnlyDocs, transfer), drives: mapped,
			keep: sh(transfer), remove: sh(docs), add: sh(readOnlyDocs)},
		{name: "letter moved", last: &last, next: with(movedDocs, transfer), drives: mapped,
			keep: sh(transfer), remove: sh(docs), add: sh(movedDocs)},
		{name: "disconnected in Explorer", last: &last, next: cloneMount(last), drives: map[string]string{},
			keep: sh(transfer), add: sh(docs)},
		{name: "remapped elsewhere, then dropped", last: &last, next: with(transfer),
			drives: map[string]string{"Z:": `\\nas\photos`}, keep: sh(transfer)},
		{name: "duplicate letter", last: &last, next: with(docs, docs, transfer), drives: mapped,
			keep: sh(docs, transfer), add: sh(docs)},
	} {
		p := planShares(tc.last, tc.next, drives(tc.drives))
		if p.Reset || !slices.Equal(p.Keep, tc.keep) || !slices.Equal(p.Remove, tc.remove) || !slices.Equal(p.Add, tc.add) {
			t.Errorf("%s: got %+v, want keep %v remove %v add %v", tc.name, p, tc.keep, tc.remove, tc.add)
		}
	}

	// A new Samba run, or no record of what is mapped: start over.
	for name, change := range map[string]func(*protocol.MountShares){
		"server":   func(m *protocol.MountShares) { m.Server = "10.0.2.5" },
		"user":     func(m *protocol.MountShares) { m.Username = "v" },
		"password": func(m *protocol.MountShares) { m.Password = "q" },
	} {
		next := cloneMount(last)
		change(&next)
		if p := planShares(&last, next, drives(mapped)); !p.Reset || !slices.Equal(p.Add, next.Shares) || p.Keep != nil || p.Remove != nil {
			t.Errorf("%s change: %+v", name, p)
		}
	}
	if p := planShares(nil, last, drives(mapped)); !p.Reset || !slices.Equal(p.Add, last.Shares) {
		t.Errorf("unknown state: %+v", p)
	}
}

func TestCloneMount(t *testing.T) {
	m := protocol.MountShares{Server: "s", Shares: []protocol.MountShare{{Letter: "Z", Name: "Docs"}}}
	c := cloneMount(m)
	c.Shares[0].Name = "Other"
	if m.Shares[0].Name != "Docs" {
		t.Fatal("clone aliases the request's shares")
	}
}
