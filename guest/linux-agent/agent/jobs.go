package agent

import "slices"

// maxJobs bounds the ordered job queue, so a host flooding requests while a
// mapping waits on the network cannot grow it without limit.
const maxJobs = 32

// job is one ordered backend call (MountShares, FileDrop). Jobs run one at a
// time, in arrival order, on the agent's worker goroutine: a drop sent right
// after the shares is handled once they are mapped.
type job struct {
	gen   uint64 // generation of the session that queued it
	mount bool   // a MountShares request
	run   func()
}

// enqueue queues run behind the session's earlier jobs. It never blocks the
// read loop: the queue is bounded and a job that does not fit is dropped
// (and reported). A MountShares request queued right behind another one
// replaces it: nothing between them depends on the older mapping, and only
// the latest list matters.
func (s *session) enqueue(mount bool, what string, run func()) {
	a := s.a
	if a.generation() != s.gen {
		return // replaced: the newer session's host decides now
	}
	a.jobOnce.Do(func() {
		a.jobWake = make(chan struct{}, 1)
		go a.runJobs()
	})
	a.jobMu.Lock()
	q := a.jobs[:0]
	for _, j := range a.jobs {
		if j.gen >= s.gen || !j.mount { // replaced sessions' share lists would only be skipped
			q = append(q, j)
		}
	}
	clear(a.jobs[len(q):])
	j := job{gen: s.gen, mount: mount, run: run}
	full, evicted := false, false
	if mount {
		// A share list goes ahead of drops left by earlier sessions (they need its fresh
		// credentials), replaces a share list queued just before it, and is never refused:
		// without it the guest keeps stale mappings until the next one arrives.
		at := slices.IndexFunc(q, func(o job) bool { return o.gen < s.gen })
		if at < 0 {
			at = len(q)
		}
		switch {
		case at > 0 && q[at-1].mount:
			q[at-1] = j
		default:
			if len(q) >= maxJobs {
				// Make room by dropping the oldest file drop.
				if d := slices.IndexFunc(q, func(o job) bool { return !o.mount }); d >= 0 {
					q = slices.Delete(q, d, d+1)
					if d < at {
						at--
					}
					evicted = true
				}
			}
			q = slices.Insert(q, at, j)
		}
	} else if len(q) >= maxJobs {
		full = true
	} else {
		q = append(q, j)
	}
	a.jobs = q
	a.jobMu.Unlock()
	if evicted {
		s.logf("file drop: dropped to make room for the share mapping (%d requests waiting)", maxJobs)
	}
	if full {
		s.logf("%s: dropped, %d requests already waiting", what, maxJobs)
		return
	}
	select {
	case a.jobWake <- struct{}{}:
	default: // the worker is already due to look at the queue
	}
}

// runJobs is the agent's single job worker. Share lists of a session that has
// been replaced since they were queued are skipped; file drops always run.
func (a *Agent) runJobs() {
	for range a.jobWake {
		for {
			a.jobMu.Lock()
			if len(a.jobs) == 0 {
				a.jobMu.Unlock()
				break
			}
			j := a.jobs[0]
			a.jobs[0] = job{}
			a.jobs = a.jobs[1:]
			a.jobMu.Unlock()
			// A share list from a replaced session is outdated (the new host sends its own); a
			// file drop isn't — the host already reported it delivered and keeps the files.
			if !j.mount || j.gen == a.generation() {
				j.run()
			}
		}
	}
}

// generation is the number of the newest session (0 before the first).
func (a *Agent) generation() uint64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.gen
}
