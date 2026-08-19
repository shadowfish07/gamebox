package games

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"testing"
)

type fakeRules struct {
	id      string
	players int
	single  bool
}

func (rules fakeRules) GameID() string                 { return rules.id }
func (rules fakeRules) PlayerLimit() int               { return rules.players }
func (rules fakeRules) SingleActiveMatchPerUser() bool { return rules.single }
func (fakeRules) Rebuild([]Event) (Snapshot, error) {
	return Snapshot{State: json.RawMessage(`{}`)}, nil
}
func (fakeRules) Apply(Snapshot, string, Action) (Event, Snapshot, error) {
	return Event{}, Snapshot{}, nil
}

func TestDefaultRegistryContainsOnlyGomokuAndModuleMetadata(t *testing.T) {
	registry := NewRegistry()
	descriptors := registry.Descriptors()
	if len(descriptors) != 1 {
		t.Fatalf("descriptor count = %d, want 1", len(descriptors))
	}
	want := Descriptor{GameID: "gomoku", PlayerLimit: 2, SingleActiveMatchPerUser: true}
	if descriptors[0] != want {
		t.Fatalf("descriptor = %#v, want %#v", descriptors[0], want)
	}
	rules, ok := registry.Lookup("gomoku")
	if !ok || rules.GameID() != "gomoku" || rules.PlayerLimit() != 2 {
		t.Fatalf("gomoku lookup = %#v, %v", rules, ok)
	}
	policy, ok := rules.(SingleActiveMatchPolicy)
	if !ok || !policy.SingleActiveMatchPerUser() {
		t.Fatal("gomoku module did not expose its own one-active-match policy")
	}
}

func TestRegistryRejectsInvalidAndDuplicateRules(t *testing.T) {
	tests := []struct {
		name  string
		rules []Rules
		want  error
	}{
		{name: "nil", rules: []Rules{nil}, want: ErrInvalidRules},
		{name: "empty game id", rules: []Rules{fakeRules{players: 2}}, want: ErrInvalidRules},
		{name: "invalid player limit", rules: []Rules{fakeRules{id: "chess", players: 0}}, want: ErrInvalidRules},
		{name: "duplicate", rules: []Rules{fakeRules{id: "chess", players: 2}, fakeRules{id: "chess", players: 4}}, want: ErrDuplicateGame},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			registry, err := NewRegistryFrom(test.rules...)
			if !errors.Is(err, test.want) || registry != nil {
				t.Fatalf("NewRegistryFrom = %#v, %v; want nil, %v", registry, err, test.want)
			}
			if err.Error() != test.want.Error() {
				t.Fatalf("registry error exposed untrusted registration data: %q", err)
			}
		})
	}
}

func TestRegistryAcceptsCanonicalExtensibleGameIDs(t *testing.T) {
	registry, err := NewRegistryFrom(fakeRules{id: "chess2_fast", players: 2})
	if err != nil {
		t.Fatalf("NewRegistryFrom: %v", err)
	}
	if _, ok := registry.Lookup("chess2_fast"); !ok {
		t.Fatal("canonical game ID was not registered")
	}
}

func TestRegistryUnknownLookupAndDescriptorDefensiveCopy(t *testing.T) {
	registry := NewRegistry()
	if rules, ok := registry.Lookup("missing"); ok || rules != nil {
		t.Fatalf("unknown lookup = %#v, %v", rules, ok)
	}
	first := registry.Descriptors()
	first[0] = Descriptor{GameID: "mutated"}
	second := registry.Descriptors()
	if len(second) != 1 || second[0].GameID != "gomoku" {
		t.Fatalf("registry descriptors were mutable: %#v", second)
	}
}

func TestRegistrySupportsConcurrentReads(t *testing.T) {
	registry := NewRegistry()
	const workers = 64
	var wg sync.WaitGroup
	errorsCh := make(chan error, workers)
	for worker := 0; worker < workers; worker++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for read := 0; read < 100; read++ {
				rules, ok := registry.Lookup("gomoku")
				if !ok || rules.GameID() != "gomoku" {
					errorsCh <- fmt.Errorf("lookup failed")
					return
				}
				if descriptors := registry.Descriptors(); len(descriptors) != 1 || descriptors[0].GameID != "gomoku" {
					errorsCh <- fmt.Errorf("descriptors changed")
					return
				}
			}
		}()
	}
	wg.Wait()
	close(errorsCh)
	for err := range errorsCh {
		t.Error(err)
	}
}
