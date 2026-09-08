package httpapi

import (
	"encoding/json"
	"me.zqydev/gamebox/server/internal/scratch"
	"testing"
)

func TestScratchDogSeriesCompatibility(t *testing.T) {
	f := newAPIFixture(t)
	user := f.register(t, "dog-series", "DogCollector")
	publish := func(counts []int) {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"counts": counts})
		response := f.request(t, "POST", "/v1/scratch/collections/me", string(raw), user.Session.AccessToken)
		if response.Code != 200 {
			t.Fatalf("publish %d: %s", response.Code, response.Body)
		}
	}
	read := func(query string) scratch.Page {
		t.Helper()
		response := f.request(t, "GET", "/v1/scratch/collections"+query, "", "")
		if response.Code != 200 {
			t.Fatalf("read %d: %s", response.Code, response.Body)
		}
		var page scratch.Page
		decodeResponse(t, response, &page)
		return page
	}
	legacy := make([]int, 24)
	legacy[0] = 3
	// Actual pre-upgrade database row.
	raw, _ := json.Marshal(legacy)
	if _, err := f.db.Exec(`INSERT INTO scratch_collections(user_id,counts_json,updated_at) VALUES(?,?,?)`, user.Session.User.ID, string(raw), 1); err != nil {
		t.Fatal(err)
	}
	p := read("?catalogSize=48").Players[0]
	if len(p.Counts) != 48 || p.Counts[0] != 3 || p.Counts[47] != 0 {
		t.Fatal("legacy row not padded", p)
	}
	if len(read("").Players[0].Counts) != 24 {
		t.Fatal("legacy GET contract changed")
	}
	current := make([]int, 48)
	current[0] = 3
	current[24] = 2
	current[47] = 1
	publish(current)
	if p := read("?catalogSize=48&card=47"); len(p.Players) != 1 || p.Players[0].Counts[47] != 1 {
		t.Fatal("dog owner missing", p)
	}
	legacy[0] = 4
	publish(legacy)
	p = read("?catalogSize=48").Players[0]
	if p.Counts[0] != 4 || p.Counts[24] != 2 || p.Counts[47] != 1 {
		t.Fatal("legacy write erased dogs", p)
	}
	if len(read("?catalogSize=48&card=46").Players) != 0 {
		t.Fatal("unowned dog exposed")
	}
	for _, query := range []string{"?catalogSize=25", "?catalogSize=048", "?catalogSize=", "?catalogSize=48&catalogSize=24", "?catalogSize=48&card=48"} {
		if r := f.request(t, "GET", "/v1/scratch/collections"+query, "", ""); r.Code != 400 {
			t.Fatal("invalid query accepted", query)
		}
	}
}
