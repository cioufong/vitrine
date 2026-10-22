package agent

import "time"

// StatsInterval is how often CPU, memory and disk use are reported.
var StatsInterval = 3 * time.Second

// cpuTimes is a cumulative busy/total CPU time sample; the unit doesn't matter.
type cpuTimes struct{ busy, total uint64 }

// cpuPercent is the busy share between two samples, or nil when it can't tell.
func cpuPercent(prev, now cpuTimes) *float64 {
	if now.total <= prev.total || now.busy < prev.busy {
		return nil
	}
	p := float64(now.busy-prev.busy) / float64(now.total-prev.total) * 100
	if p > 100 {
		p = 100
	}
	return &p
}

// statsLoop reports guest load every StatsInterval until the connection
// closes. Started once per session, when the host's Hello lists "stats".
func (s *session) statsLoop() {
	prev, havePrev := sampleCPU()
	t := time.NewTicker(StatsInterval)
	defer t.Stop()
	for {
		select {
		case <-s.conn.Done():
			return
		case <-t.C:
			st := sampleStats()
			if now, ok := sampleCPU(); ok {
				if havePrev {
					st.CPUPercent = cpuPercent(prev, now)
				}
				prev, havePrev = now, true
			}
			s.conn.Send(st)
		}
	}
}

// startStatsReports runs statsLoop once per session.
func (s *session) startStatsReports() {
	s.statsOnce.Do(func() { go s.statsLoop() })
}

func u64(v uint64) *uint64 { return &v }
