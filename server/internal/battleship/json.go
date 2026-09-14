package battleship

import (
	"bytes"
	"encoding/json"
)

// A missing or null coordinate must never silently become an attack on A1.
func exactValues(raw []byte, keys ...string) error {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		return err
	}
	if len(fields) != len(keys) {
		return ErrInvalid
	}
	for _, key := range keys {
		value, ok := fields[key]
		if !ok || bytes.Equal(bytes.TrimSpace(value), []byte("null")) {
			return ErrInvalid
		}
	}
	return nil
}
func (s *Ship) UnmarshalJSON(raw []byte) error {
	if err := exactValues(raw, "id", "cell", "vertical"); err != nil {
		return err
	}
	type plain Ship
	var decoded plain
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return err
	}
	*s = Ship(decoded)
	return nil
}
func (a *Action) UnmarshalJSON(raw []byte) error {
	if err := exactValues(raw, "actionId", "revision", "kind", "ships", "cell"); err != nil {
		return err
	}
	type plain Action
	var decoded plain
	if err := json.Unmarshal(raw, &decoded); err != nil {
		return err
	}
	*a = Action(decoded)
	return nil
}
