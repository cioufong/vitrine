package win

import (
	"slices"
	"strings"

	"github.com/cioufong/vitrine/guest/linux-agent/protocol"
)

// Platform-independent helpers for shared folders and file drops (tested on any OS).

// uncPath builds \\server\share[\rel], converting "/" separators in rel.
func uncPath(server, share, rel string) string {
	p := `\\` + server + `\` + share
	if rel != "" {
		p += `\` + strings.ReplaceAll(rel, "/", `\`)
	}
	return p
}

// sharePlan is how MountShares gets from what is mapped now to a request.
type sharePlan struct {
	// Reset: a new Samba run (other server or credentials) or nothing known
	// about the current mappings. Every connection to the server must be
	// dropped (sessions authenticated with the old password are useless) and
	// every share mapped again.
	Reset  bool
	Keep   []protocol.MountShare // mapped exactly as asked: left alone
	Remove []protocol.MountShare // mapped before, no longer asked for (or changed): disconnected without force
	Add    []protocol.MountShare // to map
}

// planShares diffs request next against last, the shares mapped by the
// previous request (nil when unknown), by drive letter. connected returns
// what a local device ("Z:") is mapped to now, so drives the user
// disconnected or remapped in Explorer are neither kept nor removed blindly.
// Shares without a letter are UNC-only connections and cannot be queried;
// they count as connected while they are listed in last.
func planShares(last *protocol.MountShares, next protocol.MountShares, connected func(local string) (string, bool)) sharePlan {
	if last == nil || last.Server != next.Server || last.Username != next.Username || last.Password != next.Password {
		return sharePlan{Reset: true, Add: slices.Clone(next.Shares)}
	}
	mappedAs := func(s protocol.MountShare) bool {
		if s.Letter == "" {
			return true
		}
		cur, ok := connected(s.Letter + ":")
		return ok && strings.EqualFold(cur, uncPath(last.Server, s.Name, ""))
	}
	var p sharePlan
	kept := make([]bool, len(last.Shares))
	for _, s := range next.Shares {
		i := slices.IndexFunc(last.Shares, func(o protocol.MountShare) bool { return o == s })
		if i >= 0 && !kept[i] && mappedAs(s) {
			kept[i] = true
			p.Keep = append(p.Keep, s)
		} else {
			p.Add = append(p.Add, s)
		}
	}
	for i, o := range last.Shares {
		if !kept[i] && mappedAs(o) {
			p.Remove = append(p.Remove, o)
		}
	}
	return p
}

// cloneMount copies m so a retained request does not alias the caller's slice.
func cloneMount(m protocol.MountShares) protocol.MountShares {
	m.Shares = slices.Clone(m.Shares)
	return m
}

// validLetter reports whether s is a single drive letter D–Z.
func validLetter(s string) bool {
	return len(s) == 1 && s[0] >= 'D' && s[0] <= 'Z'
}
