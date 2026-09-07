package httpapi

import (
	"encoding/json"
	"fmt"
	"me.zqydev/gamebox/server/internal/scratch"
	"net/http"
	"testing"
)

func TestScratchPublicCollections(t *testing.T) {
	f := newAPIFixture(t)
	alice := f.register(t, "scratch-alice-invite", "Alice")
	bob := f.register(t, "scratch-bob-invite", "Bob")
	counts := make([]int, 24)
	counts[13] = 2
	body, _ := json.Marshal(map[string]any{"counts": counts})
	if got := f.request(t, "POST", "/v1/scratch/collections/me", string(body), "").Code; got != 401 {
		t.Fatalf("anonymous publish %d", got)
	}
	if got := f.request(t, "GET", "/v1/scratch/collections", "", ""); got.Code != 200 {
		t.Fatalf("list %d %s", got.Code, got.Body)
	}
	for _, token := range []string{alice.Session.AccessToken, bob.Session.AccessToken} {
		if got := f.request(t, "POST", "/v1/scratch/collections/me", string(body), token); got.Code != 200 {
			t.Fatalf("publish %d %s", got.Code, got.Body)
		}
	}
	var page struct {
		Players []struct {
			UserID string `json:"userId"`
			Counts []int  `json:"counts"`
		} `json:"players"`
	}
	decodeResponse(t, f.request(t, "GET", "/v1/scratch/collections", "", bob.Session.AccessToken), &page)
	if len(page.Players) != 2 || page.Players[0].Counts[13] != 2 {
		t.Fatalf("unexpected page %+v", page)
	}
	// Re-publishing replaces a snapshot; it never doubles the collection.
	f.request(t, "POST", "/v1/scratch/collections/me", string(body), alice.Session.AccessToken)
	for _, invalid := range []string{`{"counts":[1]}`, `{"counts":null}`, `{"counts":[],"userId":"other"}`} {
		if got := f.request(t, "POST", "/v1/scratch/collections/me", invalid, alice.Session.AccessToken).Code; got != 400 {
			t.Fatalf("invalid body %d", got)
		}
	}
	if got := f.request(t, "DELETE", "/v1/scratch/collections/me", "", alice.Session.AccessToken).Code; got != http.StatusNoContent {
		t.Fatalf("delete %d", got)
	}
	decodeResponse(t, f.request(t, "GET", "/v1/scratch/collections", "", ""), &page)
	if len(page.Players) != 1 || page.Players[0].UserID != bob.Session.User.ID {
		t.Fatalf("delete touched another player %+v", page)
	}
	f.db.Exec(`UPDATE users SET enabled=0 WHERE id=?`, bob.Session.User.ID)
	decodeResponse(t, f.request(t, "GET", "/v1/scratch/collections", "", ""), &page)
	if len(page.Players) != 0 {
		t.Fatal("disabled player exposed")
	}
}

func TestScratchCollectionPaginationAndBounds(t *testing.T) {
	f := newAPIFixture(t)
	counts := make([]int, 24)
	raw, _ := json.Marshal(counts)
	for i := 0; i < 32; i++ {
		id := fmt.Sprintf("%08d-1111-4111-8111-111111111111", i)
		if _, err := f.db.Exec(`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES(?,?,?,?,?)`, id, id, id, 1, 1); err != nil {
			t.Fatal(err)
		}
		if _, err := f.db.Exec(`INSERT INTO scratch_collections(user_id,counts_json,updated_at) VALUES(?,?,?)`, id, string(raw), 1); err != nil {
			t.Fatal(err)
		}
	}
	var first, second scratch.Page
	decodeResponse(t, f.request(t, "GET", "/v1/scratch/collections", "", ""), &first)
	if len(first.Players) != 30 || first.NextCursor != first.Players[29].UserID {
		t.Fatalf("first page size=%d cursor=%s", len(first.Players), first.NextCursor)
	}
	decodeResponse(t, f.request(t, "GET", "/v1/scratch/collections?after="+first.NextCursor, "", ""), &second)
	if len(second.Players) != 2 || second.NextCursor != "" || second.Players[0].UserID <= first.NextCursor {
		t.Fatal("invalid second page")
	}
	for _, query := range []string{"?after=bad", "?unknown=yes", "?after=x&after=y"} {
		if got := f.request(t, "GET", "/v1/scratch/collections"+query, "", "").Code; got != 400 {
			t.Fatalf("invalid query status %d", got)
		}
	}
	alice := f.register(t, "scratch-bounds-invite", "Bounds")
	for _, bad := range []int{-1, 1000000001} {
		counts[0] = bad
		body, _ := json.Marshal(map[string]any{"counts": counts})
		if got := f.request(t, "POST", "/v1/scratch/collections/me", string(body), alice.Session.AccessToken).Code; got != 400 {
			t.Fatalf("invalid count status %d", got)
		}
	}
}
