package battleship

import (
	"encoding/json"
	"testing"
)

func TestNullAndMissingValuesAreNotImplicitMoves(t *testing.T) {
	for _, body := range []string{
		`{"actionId":"x","revision":0,"kind":"fire","ships":[],"cell":null}`,
		`{"actionId":"x","revision":null,"kind":"fire","ships":[],"cell":0}`,
		`{"actionId":"x","revision":0,"kind":"fire","ships":[],"cell":0.5}`,
		`{"actionId":"x","revision":0,"kind":"save","ships":[{}],"cell":0}`,
		`{"actionId":"x","revision":0,"kind":"save","ships":[{"id":0,"cell":0,"vertical":null}],"cell":0}`,
	} {
		var action Action
		if err := json.Unmarshal([]byte(body), &action); err == nil {
			t.Fatalf("accepted invalid body %s", body)
		}
	}
	var action Action
	if err := json.Unmarshal([]byte(`{"actionId":"x","revision":0,"kind":"save","ships":[{"id":0,"cell":0,"vertical":false}],"cell":0}`), &action); err != nil {
		t.Fatal(err)
	}
}
