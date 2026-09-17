package httpapi

import (
	"encoding/json"
	"github.com/google/uuid"
	"me.zqydev/gamebox/server/internal/battleship"
	"testing"
)

func TestBattleshipAuthenticatedPrivateHTTP(t *testing.T) {
	f := newAPIFixture(t)
	a := f.register(t, "sea-alice-invite", "舰长甲")
	b := f.register(t, "sea-bob-invite", "舰长乙")
	x := f.register(t, "sea-other-invite", "旁观者")
	id := uuid.NewString()
	path := "/v1/battleship/matches/" + id
	body, _ := json.Marshal(map[string]string{"id": id, "opponentId": b.Session.User.ID})
	if got := f.request(t, "POST", "/v1/battleship/matches", string(body), ""); got.Code != 401 {
		t.Fatal(got.Code)
	}
	got := f.request(t, "POST", "/v1/battleship/matches", string(body), a.Session.AccessToken)
	if got.Code != 200 {
		t.Fatal(got.Code, got.Body)
	}
	if got.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("private response can be cached")
	}
	var v battleship.View
	decodeResponse(t, got, &v)
	action := battleship.Action{ActionID: uuid.NewString(), Kind: "ready", Ships: []battleship.Ship{{Cell: 0, ID: 0}, {Cell: 10, ID: 1}, {Cell: 20, ID: 2}, {Cell: 30, ID: 3}, {Cell: 40, ID: 4}}}
	raw, _ := json.Marshal(action)
	got = f.request(t, "POST", path+"/actions", string(raw), a.Session.AccessToken)
	if got.Code != 200 {
		t.Fatal(got.Code, got.Body)
	}
	got = f.request(t, "GET", path, "", b.Session.AccessToken)
	decodeResponse(t, got, &v)
	if len(v.EnemyShips) != 0 || !v.EnemyReady || v.Ready {
		t.Fatal("private snapshot leaked", v)
	}
	if got = f.request(t, "GET", path, "", x.Session.AccessToken); got.Code != 404 {
		t.Fatal("nonparticipant", got.Code)
	}
	if got = f.request(t, "POST", path+"/actions", string(raw), x.Session.AccessToken); got.Code != 404 {
		t.Fatal("nonparticipant action", got.Code)
	}
	// Exact retry survives subsequent reads; no additional revision is produced.
	got = f.request(t, "POST", path+"/actions", string(raw), a.Session.AccessToken)
	decodeResponse(t, got, &v)
	if v.Revision != 1 {
		t.Fatal(v.Revision)
	}
	stale := action
	stale.ActionID = uuid.NewString()
	stale.Kind = "cancel"
	rawStale, _ := json.Marshal(stale)
	if got = f.request(t, "POST", path+"/actions", string(rawStale), a.Session.AccessToken); got.Code != 409 {
		t.Fatal("stale revision must be a conflict", got.Code, got.Body)
	}
	var list battleship.MatchPage
	decodeResponse(t, f.request(t, "GET", "/v1/battleship/matches", "", b.Session.AccessToken), &list)
	if len(list.Matches) != 1 || len(list.Matches[0].EnemyShips) != 0 {
		t.Fatal("list privacy")
	}
	for _, bad := range []string{`{}`, `{"actionId":"bad","revision":1,"kind":"fire","ships":[],"cell":0}`, `{"actionId":null,"revision":1,"kind":"fire","ships":[],"cell":0}`} {
		if got = f.request(t, "POST", path+"/actions", bad, a.Session.AccessToken); got.Code != 400 {
			t.Fatal("invalid action", got.Code)
		}
	}
}

func TestBattleshipRejectsIncompatibleMatchIDs(t *testing.T) {
	f := newAPIFixture(t)
	a := f.register(t, "sea-id-a", "甲舰长")
	b := f.register(t, "sea-id-b", "乙舰长")
	for _, id := range []string{
		"11111111-1111-4111-0111-111111111111",
		"11111111-1111-4111-c111-111111111111",
		"11111111-1111-0111-8111-111111111111",
		"11111111-1111-6111-8111-111111111111",
		"11111111-1111-7111-8111-111111111111",
		"11111111-1111-f111-8111-111111111111",
	} {
		body, _ := json.Marshal(map[string]string{"id": id, "opponentId": b.Session.User.ID})
		if got := f.request(t, "POST", "/v1/battleship/matches", string(body), a.Session.AccessToken); got.Code != 400 {
			t.Errorf("incompatible ID %s: status=%d, want 400", id, got.Code)
		}
	}
	var list battleship.MatchPage
	decodeResponse(t, f.request(t, "GET", "/v1/battleship/matches", "", b.Session.AccessToken), &list)
	if len(list.Matches) != 0 {
		t.Fatalf("invalid IDs polluted opponent list: %d matches", len(list.Matches))
	}
	// All UUID versions accepted by the client remain usable over HTTP.
	for _, version := range []byte{'1', '2', '3', '4', '5'} {
		id := []byte("11111111-1111-4111-8111-111111111111")
		id[14] = version
		body, _ := json.Marshal(map[string]string{"id": string(id), "opponentId": b.Session.User.ID})
		if got := f.request(t, "POST", "/v1/battleship/matches", string(body), a.Session.AccessToken); got.Code != 200 {
			t.Fatalf("supported version %c: %d", version, got.Code)
		}
	}
}
