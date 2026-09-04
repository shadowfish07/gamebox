// Package games provides the platform registry and the narrow game rules API.
package games

import "me.zqydev/gamebox/server/internal/games/gameapi"

type Action = gameapi.Action
type Event = gameapi.Event
type Snapshot = gameapi.Snapshot
type Rules = gameapi.Rules
type RandomizedRules = gameapi.RandomizedRules
type Configurator = gameapi.Configurator
type SingleActiveMatchPolicy = gameapi.SingleActiveMatchPolicy

var (
	ErrInvalidAction   = gameapi.ErrInvalidAction
	ErrInvalidEvent    = gameapi.ErrInvalidEvent
	ErrInvalidSnapshot = gameapi.ErrInvalidSnapshot
)
