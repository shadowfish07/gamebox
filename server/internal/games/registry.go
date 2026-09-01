package games

import (
	"errors"
	"reflect"
	"sort"

	"me.zqydev/gamebox/server/internal/games/chinesecheckers"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/games/rps"
)

var (
	ErrInvalidRules  = errors.New("invalid_rules")
	ErrDuplicateGame = errors.New("duplicate_game")
)

type Descriptor struct {
	GameID                   string
	PlayerLimit              int
	SingleActiveMatchPerUser bool
}

// Registry is immutable after construction. Its map and ordered descriptors
// are never exposed, making concurrent reads safe without synchronization.
type Registry struct {
	rules       map[string]Rules
	descriptors []Descriptor
}

// NewRegistry returns the production registry.
func NewRegistry() *Registry {
	registry, err := NewRegistryFrom(chinesecheckers.NewRules(), gomoku.NewRules(), rps.NewRules())
	if err != nil {
		panic("games: invalid built-in registry")
	}
	return registry
}

// NewRegistryFrom is a validation seam for tests and future composition. It
// does not add built-ins implicitly.
func NewRegistryFrom(entries ...Rules) (*Registry, error) {
	registry := &Registry{
		rules:       make(map[string]Rules, len(entries)),
		descriptors: make([]Descriptor, 0, len(entries)),
	}
	for _, rules := range entries {
		if nilRules(rules) {
			return nil, ErrInvalidRules
		}
		gameID := rules.GameID()
		playerLimit := rules.PlayerLimit()
		if !validGameID(gameID) || playerLimit < 1 || playerLimit > 64 {
			return nil, ErrInvalidRules
		}
		if _, exists := registry.rules[gameID]; exists {
			return nil, ErrDuplicateGame
		}
		single := false
		if policy, ok := rules.(SingleActiveMatchPolicy); ok {
			single = policy.SingleActiveMatchPerUser()
		}
		registry.rules[gameID] = rules
		registry.descriptors = append(registry.descriptors, Descriptor{
			GameID:                   gameID,
			PlayerLimit:              playerLimit,
			SingleActiveMatchPerUser: single,
		})
	}
	sort.Slice(registry.descriptors, func(left, right int) bool {
		return registry.descriptors[left].GameID < registry.descriptors[right].GameID
	})
	return registry, nil
}

func (registry *Registry) Lookup(gameID string) (Rules, bool) {
	if registry == nil {
		return nil, false
	}
	rules, ok := registry.rules[gameID]
	return rules, ok
}

func (registry *Registry) Descriptors() []Descriptor {
	if registry == nil {
		return nil
	}
	return append([]Descriptor(nil), registry.descriptors...)
}

func nilRules(rules Rules) bool {
	if rules == nil {
		return true
	}
	value := reflect.ValueOf(rules)
	switch value.Kind() {
	case reflect.Chan, reflect.Func, reflect.Interface, reflect.Map, reflect.Pointer, reflect.Slice:
		return value.IsNil()
	default:
		return false
	}
}

func validGameID(gameID string) bool {
	if len(gameID) < 1 || len(gameID) > 32 || gameID[0] < 'a' || gameID[0] > 'z' {
		return false
	}
	for _, character := range gameID[1:] {
		isLetter := character >= 'a' && character <= 'z'
		isDigit := character >= '0' && character <= '9'
		if !isLetter && !isDigit && character != '-' && character != '_' {
			return false
		}
	}
	return true
}
