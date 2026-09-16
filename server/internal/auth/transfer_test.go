package auth

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"me.zqydev/gamebox/server/internal/clock"
	"strings"
	"sync"
	"testing"
	"time"
)

func transferSnapshot() string {
	data, _ := json.Marshal(map[string]any{"version": 3, "counts": make([]int, 48), "firstFound": make([]*string, 48), "favorites": []int{}, "cat": 0, "claimed": false, "winning": false, "isNew": false, "serial": 9})
	return string(data)
}
func receiverSecret(n byte) string {
	return base64.RawURLEncoding.EncodeToString([]byte(strings.Repeat(string(n), 32)))
}
func TestTransferIdentityRevocationAndRetry(t *testing.T) {
	f := newAuthFixture(t)
	ctx := context.Background()
	f.addInvite(t, "transfer-invite")
	old, err := f.service.RegisterAndIssue(ctx, "transfer-invite", "Alice")
	if err != nil {
		t.Fatal(err)
	}
	code, err := f.service.CreateTransfer(ctx, old.AccessToken, transferSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.service.Authenticate(ctx, old.AccessToken); err != nil {
		t.Fatal("generation signed out old device")
	}
	result, err := f.service.RedeemTransfer(ctx, strings.ToLower(code.Code[:4]+" "+code.Code[4:]), receiverSecret('a'), "peer")
	if err != nil {
		t.Fatal(err)
	}
	if result.Session.User != old.User || result.Snapshot != transferSnapshot() {
		t.Fatal("identity/progress changed")
	}
	if _, err = f.service.Authenticate(ctx, old.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("old access accepted", err)
	}
	if _, err = f.service.Refresh(ctx, old.RefreshToken); !errors.Is(err, ErrSessionTransferred) {
		t.Fatal("old refresh accepted", err)
	}
	if _, err = f.service.Authenticate(ctx, result.Session.AccessToken); err != nil {
		t.Fatal(err)
	}
	if _, err = f.service.RedeemTransfer(ctx, code.Code, receiverSecret('b'), "peer"); !errors.Is(err, ErrTransferInvalid) {
		t.Fatal("second receiver accepted")
	}
	f.service.clock.(*clock.Fake).Advance(20 * time.Minute)
	again, err := f.service.RedeemTransfer(ctx, code.Code, receiverSecret('a'), "peer")
	if err != nil || again.Session.RefreshToken != result.Session.RefreshToken {
		t.Fatal("retry lost receipt", err)
	}
	if _, err = f.service.Authenticate(ctx, again.Session.AccessToken); err != nil {
		t.Fatal("retry access expired", err)
	}
	if _, err = f.service.Refresh(ctx, again.Session.RefreshToken); err != nil {
		t.Fatal(err)
	}
	var blob []byte
	if err = f.db.QueryRow(`SELECT response FROM device_transfers`).Scan(&blob); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(blob), result.Session.RefreshToken) {
		t.Fatal("plaintext receipt")
	}
}
func TestTransferExpiryReplacementCancellationAndConcurrentClaim(t *testing.T) {
	f := newAuthFixture(t)
	ctx := context.Background()
	f.addInvite(t, "transfer-expire")
	old, err := f.service.RegisterAndIssue(ctx, "transfer-expire", "Alice")
	if err != nil {
		t.Fatal(err)
	}
	first, _ := f.service.CreateTransfer(ctx, old.AccessToken, transferSnapshot())
	second, _ := f.service.CreateTransfer(ctx, old.AccessToken, transferSnapshot())
	if _, err = f.service.RedeemTransfer(ctx, first.Code, receiverSecret('a'), "peer"); !errors.Is(err, ErrTransferInvalid) {
		t.Fatal("replaced code accepted")
	}
	f.service.clock.(*clock.Fake).Advance(10 * time.Minute)
	if _, err = f.service.RedeemTransfer(ctx, second.Code, receiverSecret('a'), "peer"); !errors.Is(err, ErrTransferInvalid) {
		t.Fatal("expired code accepted")
	}
	code, _ := f.service.CreateTransfer(ctx, old.AccessToken, transferSnapshot())
	if err = f.service.CancelTransfer(ctx, old.AccessToken); err != nil {
		t.Fatal(err)
	}
	if _, err = f.service.RedeemTransfer(ctx, code.Code, receiverSecret('a'), "peer"); !errors.Is(err, ErrTransferInvalid) {
		t.Fatal("cancelled code accepted")
	}
	code, err = f.service.CreateTransfer(ctx, old.AccessToken, transferSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	results := make(chan error, 2)
	for _, n := range []byte{'a', 'b'} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := f.service.RedeemTransfer(ctx, code.Code, receiverSecret(n), "peer")
			results <- err
		}()
	}
	wg.Wait()
	close(results)
	successes := 0
	for err := range results {
		if err == nil {
			successes++
		} else if !errors.Is(err, ErrTransferInvalid) {
			t.Fatal(err)
		}
	}
	if successes != 1 {
		t.Fatal("claims", successes)
	}
}
func TestTransferRecoveryAndRateLimit(t *testing.T) {
	f := newAuthFixture(t)
	ctx := context.Background()
	f.addInvite(t, "transfer-recovery")
	old, err := f.service.RegisterAndIssue(ctx, "transfer-recovery", "Alice")
	if err != nil {
		t.Fatal(err)
	}
	code, err := f.service.CreateRecovery(ctx, old.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.service.RedeemTransfer(ctx, code.Code, receiverSecret('a'), "peer"); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 30; i++ {
		_, err = f.service.RedeemTransfer(ctx, "AAAAAAAA", receiverSecret('b'), "attack")
	}
	if _, err = f.service.RedeemTransfer(ctx, "AAAAAAAA", receiverSecret('b'), "attack"); !errors.Is(err, ErrTransferLimited) {
		t.Fatal("no rate limit", err)
	}
}

func TestTransferCommitFailureLeavesOldSessionAndCodeUsable(t *testing.T) {
	f := newAuthFixture(t)
	ctx := context.Background()
	f.addInvite(t, "transfer-rollback")
	old, err := f.service.RegisterAndIssue(ctx, "transfer-rollback", "Alice")
	if err != nil {
		t.Fatal(err)
	}
	code, err := f.service.CreateTransfer(ctx, old.AccessToken, transferSnapshot())
	if err != nil {
		t.Fatal(err)
	}
	commits := 0
	f.service.commit = func(tx *writeTransaction) error {
		commits++
		if commits == 1 {
			return commitWriteTransaction(tx)
		}
		return errors.New("injected commit failure")
	}
	if _, err = f.service.RedeemTransfer(ctx, code.Code, receiverSecret('a'), "peer"); err == nil {
		t.Fatal("expected rollback")
	}
	f.service.commit = commitWriteTransaction
	if _, err = f.service.Authenticate(ctx, old.AccessToken); err != nil {
		t.Fatal("rollback revoked old device", err)
	}
	if _, err = f.service.RedeemTransfer(ctx, code.Code, receiverSecret('b'), "peer"); err != nil {
		t.Fatal("rollback consumed code", err)
	}
}

func TestRecoveryKeepsPublishedCountsWithoutInventingDiscoveryDates(t *testing.T) {
	f := newAuthFixture(t)
	ctx := context.Background()
	f.addInvite(t, "recovery-counts")
	old, err := f.service.RegisterAndIssue(ctx, "recovery-counts", "Alice")
	if err != nil {
		t.Fatal(err)
	}
	counts := make([]int, 48)
	counts[3] = 7
	raw, _ := json.Marshal(counts)
	if _, err = f.db.Exec(`INSERT INTO scratch_collections(user_id,counts_json,updated_at) VALUES(?,?,?)`, old.User.ID, string(raw), f.now.UnixMilli()); err != nil {
		t.Fatal(err)
	}
	code, err := f.service.CreateRecovery(ctx, old.User.ID)
	if err != nil {
		t.Fatal(err)
	}
	result, err := f.service.RedeemTransfer(ctx, code.Code, receiverSecret('a'), "peer")
	if err != nil {
		t.Fatal(err)
	}
	if !validTransferSnapshot(result.Snapshot) {
		t.Fatal("recovery save cannot be transferred again")
	}
	var saved struct {
		Counts         []int
		FirstFound     []*string
		RecoveredDates bool
	}
	if err = json.Unmarshal([]byte(result.Snapshot), &saved); err != nil {
		t.Fatal(err)
	}
	if saved.Counts[3] != 7 || saved.FirstFound[3] != nil || !saved.RecoveredDates {
		t.Fatal("recovery invented dates or lost counts")
	}
}
