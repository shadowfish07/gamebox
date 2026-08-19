package clock

import "time"

// Clock supplies the current time to services whose behavior depends on it.
type Clock interface {
	Now() time.Time
}

// Real is the production wall clock.
type Real struct{}

func (Real) Now() time.Time {
	return time.Now().UTC()
}
