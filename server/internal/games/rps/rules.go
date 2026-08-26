// Package rps implements server-authoritative rock-paper-scissors rounds.
package rps

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"unicode"
	"unicode/utf8"

	"me.zqydev/gamebox/server/internal/games/gameapi"
)

const (
	GameID = "rps"

	ChoiceRequested = "rps.choice.requested"
	ChoiceLocked    = "rps.choice.locked"
	RoundRevealed   = "rps.round.revealed"

	FormatSingleRound = "single_round"
	FormatBestOfThree = "best_of_three"

	Rock     = "rock"
	Paper    = "paper"
	Scissors = "scissors"
)

var (
	ErrInvalidFormat = errors.New("invalid_format")
	ErrInvalidChoice = errors.New("invalid_choice")
	ErrChoiceLocked  = errors.New("choice_locked")
	ErrMatchFinished = errors.New("match_finished")
)

// Rules is either an unconfigured registry template or an immutable
// match-scoped rules instance returned by Configure.
type Rules struct{ format string }

func NewRules() *Rules { return &Rules{} }

func (*Rules) GameID() string { return GameID }

func (*Rules) PlayerLimit() int { return 2 }

func (*Rules) SingleActiveMatchPerUser() bool { return true }

func (*Rules) Configure(config json.RawMessage) (gameapi.Rules, error) {
	format, err := decodeConfig(config)
	if err != nil {
		return nil, err
	}
	return &Rules{format: format}, nil
}

type state struct {
	Status       string            `json:"status"`
	Format       string            `json:"format"`
	Round        int               `json:"round"`
	Choices      map[string]string `json:"choices"`
	Scores       map[string]int    `json:"scores"`
	LastReveal   *reveal           `json:"lastReveal"`
	WinnerUserID *string           `json:"winnerUserId"`
	Result       *string           `json:"result"`
}

type locked struct {
	Round  int    `json:"round"`
	UserID string `json:"userId"`
	Choice string `json:"choice"`
}

type reveal struct {
	Round             int               `json:"round"`
	Choices           map[string]string `json:"choices"`
	RoundWinnerUserID *string           `json:"roundWinnerUserId"`
	Draw              bool              `json:"draw"`
	Scores            map[string]int    `json:"scores"`
	MatchWinnerUserID *string           `json:"matchWinnerUserId"`
	Result            *string           `json:"result"`
}

func (rules *Rules) Rebuild(events []gameapi.Event) (gameapi.Snapshot, error) {
	snapshot, err := rules.initialSnapshot()
	if err != nil {
		return gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	for index, persisted := range events {
		if persisted.Revision != int64(index+1) || !validActorID(persisted.ActorID) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		var choice string
		switch persisted.Type {
		case ChoiceLocked:
			payload, decodeErr := decodeLocked(persisted.Payload)
			if decodeErr != nil || payload.UserID != persisted.ActorID {
				return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
			}
			choice = payload.Choice
		case RoundRevealed:
			payload, decodeErr := decodeReveal(persisted.Payload)
			if decodeErr != nil {
				return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
			}
			choice = payload.Choices[persisted.ActorID]
			if choice == "" {
				return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
			}
		default:
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		produced, next, applyErr := rules.apply(snapshot, persisted.ActorID, choice)
		if applyErr != nil || produced.Revision != persisted.Revision || produced.Type != persisted.Type || produced.ActorID != persisted.ActorID || !bytes.Equal(produced.Payload, persisted.Payload) {
			return gameapi.Snapshot{}, gameapi.ErrInvalidEvent
		}
		snapshot = next
	}
	return cloneSnapshot(snapshot), nil
}

func (rules *Rules) Apply(snapshot gameapi.Snapshot, actorID string, action gameapi.Action) (gameapi.Event, gameapi.Snapshot, error) {
	if rules == nil || !validFormat(rules.format) || action.Type != ChoiceRequested || !validActorID(actorID) {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	choice, err := decodeChoice(action.Payload)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, err
	}
	if len(snapshot.State) == 0 && snapshot.Revision == 0 {
		snapshot, err = rules.initialSnapshot()
		if err != nil {
			return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
		}
	}
	return rules.apply(snapshot, actorID, choice)
}

func (rules *Rules) apply(snapshot gameapi.Snapshot, actorID, choice string) (gameapi.Event, gameapi.Snapshot, error) {
	current, err := decodeState(snapshot, rules.format)
	if err != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	if current.Status != "active" {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrMatchFinished
	}
	if !validChoice(choice) {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrInvalidChoice
	}
	if _, exists := current.Choices[actorID]; exists {
		return gameapi.Event{}, gameapi.Snapshot{}, ErrChoiceLocked
	}
	current.Choices[actorID] = choice
	revision := snapshot.Revision + 1
	if len(current.Choices) == 1 {
		payload, marshalErr := json.Marshal(locked{Round: current.Round, UserID: actorID, Choice: choice})
		if marshalErr != nil {
			return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
		}
		next, encodeErr := encodeState(revision, current)
		if encodeErr != nil {
			return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
		}
		return gameapi.Event{Revision: revision, Type: ChoiceLocked, ActorID: actorID, Payload: payload}, next, nil
	}
	if len(current.Choices) != 2 {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}

	ids := make([]string, 0, 2)
	for userID := range current.Choices {
		ids = append(ids, userID)
	}
	if ids[0] > ids[1] {
		ids[0], ids[1] = ids[1], ids[0]
	}
	left, right := ids[0], ids[1]
	comparison := compare(current.Choices[left], current.Choices[right])
	var roundWinner *string
	if comparison > 0 {
		roundWinner = stringPointer(left)
	} else if comparison < 0 {
		roundWinner = stringPointer(right)
	}
	if roundWinner != nil {
		current.Scores[*roundWinner]++
	}
	var matchWinner, result *string
	if roundWinner != nil && (rules.format == FormatSingleRound || current.Scores[*roundWinner] >= 2) {
		matchWinner = stringPointer(*roundWinner)
		result = stringPointer("rounds")
		current.Status = "finished"
		current.WinnerUserID = stringPointer(*roundWinner)
		current.Result = stringPointer("rounds")
	}
	revealed := reveal{
		Round: current.Round, Choices: cloneStringMap(current.Choices),
		RoundWinnerUserID: cloneStringPointer(roundWinner), Draw: roundWinner == nil,
		Scores: cloneScoreMap(current.Scores), MatchWinnerUserID: cloneStringPointer(matchWinner), Result: cloneStringPointer(result),
	}
	current.LastReveal = &revealed
	current.Choices = map[string]string{}
	if current.Status == "active" {
		current.Round++
	}
	payload, marshalErr := json.Marshal(revealed)
	if marshalErr != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidAction
	}
	next, encodeErr := encodeState(revision, current)
	if encodeErr != nil {
		return gameapi.Event{}, gameapi.Snapshot{}, gameapi.ErrInvalidSnapshot
	}
	return gameapi.Event{Revision: revision, Type: RoundRevealed, ActorID: actorID, Payload: payload}, next, nil
}

func (rules *Rules) initialSnapshot() (gameapi.Snapshot, error) {
	if rules == nil || !validFormat(rules.format) {
		return gameapi.Snapshot{}, ErrInvalidFormat
	}
	return encodeState(0, state{Status: "active", Format: rules.format, Round: 1, Choices: map[string]string{}, Scores: map[string]int{}})
}

func decodeConfig(config json.RawMessage) (string, error) {
	fields, err := decodeObject(config, map[string]struct{}{"format": {}})
	if err != nil || len(fields) != 1 {
		return "", ErrInvalidFormat
	}
	var format string
	if json.Unmarshal(fields["format"], &format) != nil || !validFormat(format) {
		return "", ErrInvalidFormat
	}
	return format, nil
}

func decodeChoice(payload json.RawMessage) (string, error) {
	fields, err := decodeObject(payload, map[string]struct{}{"choice": {}})
	if err != nil || len(fields) != 1 {
		return "", gameapi.ErrInvalidAction
	}
	var choice string
	if json.Unmarshal(fields["choice"], &choice) != nil || !validChoice(choice) {
		return "", ErrInvalidChoice
	}
	return choice, nil
}

func decodeLocked(payload json.RawMessage) (locked, error) {
	fields, err := decodeObject(payload, map[string]struct{}{"round": {}, "userId": {}, "choice": {}})
	if err != nil || len(fields) != 3 {
		return locked{}, gameapi.ErrInvalidEvent
	}
	var value locked
	if json.Unmarshal(payload, &value) != nil || value.Round < 1 || !validActorID(value.UserID) || !validChoice(value.Choice) {
		return locked{}, gameapi.ErrInvalidEvent
	}
	return value, nil
}

func decodeReveal(payload json.RawMessage) (reveal, error) {
	allowed := map[string]struct{}{"round": {}, "choices": {}, "roundWinnerUserId": {}, "draw": {}, "scores": {}, "matchWinnerUserId": {}, "result": {}}
	fields, err := decodeObject(payload, allowed)
	if err != nil || len(fields) != len(allowed) {
		return reveal{}, gameapi.ErrInvalidEvent
	}
	var value reveal
	if json.Unmarshal(payload, &value) != nil || value.Round < 1 || len(value.Choices) != 2 || len(value.Scores) > 2 {
		return reveal{}, gameapi.ErrInvalidEvent
	}
	for userID, choice := range value.Choices {
		if !validActorID(userID) || !validChoice(choice) {
			return reveal{}, gameapi.ErrInvalidEvent
		}
	}
	return value, nil
}

func decodeState(snapshot gameapi.Snapshot, format string) (state, error) {
	if snapshot.Revision < 0 || len(snapshot.State) == 0 || len(snapshot.State) > 16384 || !utf8.Valid(snapshot.State) {
		return state{}, gameapi.ErrInvalidSnapshot
	}
	var current state
	decoder := json.NewDecoder(bytes.NewReader(snapshot.State))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&current) != nil || current.Format != format || !validFormat(current.Format) || current.Round < 1 || current.Choices == nil || current.Scores == nil || len(current.Choices) > 2 || len(current.Scores) > 2 {
		return state{}, gameapi.ErrInvalidSnapshot
	}
	if current.Status != "active" && current.Status != "finished" {
		return state{}, gameapi.ErrInvalidSnapshot
	}
	for userID, choice := range current.Choices {
		if !validActorID(userID) || !validChoice(choice) {
			return state{}, gameapi.ErrInvalidSnapshot
		}
	}
	for userID, score := range current.Scores {
		if !validActorID(userID) || score < 0 || score > 2 {
			return state{}, gameapi.ErrInvalidSnapshot
		}
	}
	return current, nil
}

func encodeState(revision int64, current state) (gameapi.Snapshot, error) {
	encoded, err := json.Marshal(current)
	return gameapi.Snapshot{Revision: revision, State: encoded}, err
}

func decodeObject(data []byte, allowed map[string]struct{}) (map[string]json.RawMessage, error) {
	if len(data) == 0 || len(data) > 16384 || !utf8.Valid(data) {
		return nil, gameapi.ErrInvalidAction
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	token, err := decoder.Token()
	if err != nil || token != json.Delim('{') {
		return nil, gameapi.ErrInvalidAction
	}
	fields := make(map[string]json.RawMessage, len(allowed))
	for decoder.More() {
		token, err = decoder.Token()
		key, ok := token.(string)
		if err != nil || !ok {
			return nil, gameapi.ErrInvalidAction
		}
		if _, duplicate := fields[key]; duplicate {
			return nil, gameapi.ErrInvalidAction
		}
		if _, permitted := allowed[key]; !permitted {
			return nil, gameapi.ErrInvalidAction
		}
		var raw json.RawMessage
		if decoder.Decode(&raw) != nil {
			return nil, gameapi.ErrInvalidAction
		}
		fields[key] = append(json.RawMessage(nil), raw...)
	}
	if token, err = decoder.Token(); err != nil || token != json.Delim('}') {
		return nil, gameapi.ErrInvalidAction
	}
	if _, err = decoder.Token(); !errors.Is(err, io.EOF) {
		return nil, gameapi.ErrInvalidAction
	}
	return fields, nil
}

func validFormat(format string) bool {
	return format == FormatSingleRound || format == FormatBestOfThree
}

func validChoice(choice string) bool { return choice == Rock || choice == Paper || choice == Scissors }

func validActorID(actorID string) bool {
	if actorID == "" || len(actorID) > 128 || !utf8.ValidString(actorID) {
		return false
	}
	for _, character := range actorID {
		if unicode.IsControl(character) {
			return false
		}
	}
	return true
}

func compare(left, right string) int {
	if left == right {
		return 0
	}
	if left == Rock && right == Scissors || left == Paper && right == Rock || left == Scissors && right == Paper {
		return 1
	}
	return -1
}

func cloneSnapshot(snapshot gameapi.Snapshot) gameapi.Snapshot {
	return gameapi.Snapshot{Revision: snapshot.Revision, State: append(json.RawMessage(nil), snapshot.State...)}
}

func cloneStringMap(source map[string]string) map[string]string {
	result := make(map[string]string, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func cloneScoreMap(source map[string]int) map[string]int {
	result := make(map[string]int, len(source))
	for key, value := range source {
		result[key] = value
	}
	return result
}

func cloneStringPointer(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func stringPointer(value string) *string { return &value }
