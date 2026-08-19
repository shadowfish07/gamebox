package clock

import (
	"sync"
	"testing"
	"time"
)

func TestRealNowIsUTC(t *testing.T) {
	t.Parallel()

	before := time.Now().UTC()
	got := (Real{}).Now()
	after := time.Now().UTC()
	if got.Location() != time.UTC {
		t.Fatalf("Real.Now location = %v, want UTC", got.Location())
	}
	if got.Before(before) || got.After(after) {
		t.Fatalf("Real.Now = %v, want between %v and %v", got, before, after)
	}
}

func TestFakeAdvance(t *testing.T) {
	t.Parallel()

	start := time.Date(2026, time.August, 19, 10, 0, 0, 123, time.FixedZone("CST", 8*60*60))
	fake := NewFake(start)
	if got, want := fake.Now(), start.UTC(); !got.Equal(want) || got.Location() != time.UTC {
		t.Fatalf("Fake.Now = %v (%v), want %v (UTC)", got, got.Location(), want)
	}

	fake.Advance(24*time.Hour + 3*time.Second)
	if got, want := fake.Now(), start.UTC().Add(24*time.Hour+3*time.Second); !got.Equal(want) {
		t.Fatalf("Fake.Now after Advance = %v, want %v", got, want)
	}
}

func TestFakeIsSafeForConcurrentUse(t *testing.T) {
	t.Parallel()

	const workers = 32
	const advancesPerWorker = 100
	fake := NewFake(time.Unix(0, 0))
	var wg sync.WaitGroup
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < advancesPerWorker; i++ {
				fake.Advance(time.Nanosecond)
				_ = fake.Now()
			}
		}()
	}
	wg.Wait()

	want := time.Unix(0, workers*advancesPerWorker).UTC()
	if got := fake.Now(); !got.Equal(want) {
		t.Fatalf("Fake.Now after concurrent advances = %v, want %v", got, want)
	}
}
