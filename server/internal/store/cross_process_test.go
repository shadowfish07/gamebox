package store

import (
	"bufio"
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

const (
	crossProcessOwnerID = "11111111-1111-4111-8111-111111111111"
	crossProcessPeerID  = "22222222-2222-4222-8222-222222222222"
	crossProcessMatchID = "33333333-3333-4333-8333-333333333333"
)

func TestConcurrentWritableOpenClosePreservesLiveOwnerAndReadOnlyVisibility(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gamebox.sqlite")
	owner := exec.Command(os.Args[0], "-test.run=^TestCrossProcessStoreHelper$")
	owner.Env = append(os.Environ(),
		"GAMEBOX_STORE_HELPER_ROLE=owner",
		"GAMEBOX_STORE_HELPER_DB="+path,
	)
	ownerInput, err := owner.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	ownerOutput, err := owner.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var ownerErrors bytes.Buffer
	owner.Stderr = &ownerErrors
	if err := owner.Start(); err != nil {
		t.Fatal(err)
	}
	ownerLines := make(chan string, 8)
	go func() {
		scanner := bufio.NewScanner(ownerOutput)
		for scanner.Scan() {
			ownerLines <- scanner.Text()
		}
		close(ownerLines)
	}()
	ownerClosed := false
	t.Cleanup(func() {
		if ownerClosed {
			return
		}
		_, _ = fmt.Fprintln(ownerInput, "close")
		_ = ownerInput.Close()
		_ = owner.Wait()
	})
	wantOwnerLine(t, ownerLines, "ready:wal")

	before := existingSidecarIdentities(t, path)
	for _, suffix := range []string{"-wal", "-shm"} {
		if _, exists := before[suffix]; !exists {
			t.Fatalf("owner did not retain live %s sidecar", suffix)
		}
	}
	runStoreHelper(t, "writer", path)
	afterWriter := existingSidecarIdentities(t, path)
	for suffix, original := range before {
		current, exists := afterWriter[suffix]
		if !exists || !os.SameFile(original, current) {
			t.Fatalf("writer close replaced the live %s sidecar", suffix)
		}
	}

	_, _ = fmt.Fprintln(ownerInput, "verify-writer")
	wantOwnerLine(t, ownerLines, "writer-visible")
	_, _ = fmt.Fprintln(ownerInput, "create-match")
	wantOwnerLine(t, ownerLines, "match-created")

	runStoreHelper(t, "reader", path)
	_, _ = fmt.Fprintln(ownerInput, "verify-match")
	wantOwnerLine(t, ownerLines, "match-visible")
	_, _ = fmt.Fprintln(ownerInput, "close")
	wantOwnerLine(t, ownerLines, "closed")
	_ = ownerInput.Close()
	if err := owner.Wait(); err != nil {
		t.Fatalf("owner helper failed: %v: %s", err, ownerErrors.String())
	}
	ownerClosed = true
}

func TestCrossProcessStoreHelper(t *testing.T) {
	role := os.Getenv("GAMEBOX_STORE_HELPER_ROLE")
	if role == "" {
		t.Skip("cross-process helper only")
	}
	path := os.Getenv("GAMEBOX_STORE_HELPER_DB")
	switch role {
	case "owner":
		runStoreOwnerHelper(t, path)
	case "writer":
		runStoreWriterHelper(t, path)
	case "reader":
		runStoreReaderHelper(t, path)
	default:
		t.Fatal("unsupported helper role")
	}
}

func runStoreOwnerHelper(t *testing.T, path string) {
	t.Helper()
	database, err := Open(context.Background(), path)
	if err != nil {
		t.Fatalf("owner open: %v", err)
	}
	defer database.Close()
	insertCrossProcessUser(t, database, crossProcessOwnerID, "Owner", "owner")

	// Establish a reader snapshot before a second write so SQLite must retain
	// live WAL frames while the other process opens and closes the database.
	pinnedConnection, err := database.Conn(context.Background())
	if err != nil {
		t.Fatalf("owner connection: %v", err)
	}
	defer pinnedConnection.Close()
	pinnedRead, err := pinnedConnection.BeginTx(context.Background(), &sql.TxOptions{ReadOnly: true})
	if err != nil {
		t.Fatalf("owner read transaction: %v", err)
	}
	defer pinnedRead.Rollback()
	var ownerUsers int
	if err := pinnedRead.QueryRow(`SELECT COUNT(*) FROM users WHERE id=?`, crossProcessOwnerID).Scan(&ownerUsers); err != nil {
		t.Fatalf("pin owner snapshot: %v", err)
	}
	if ownerUsers != 1 {
		t.Fatalf("pin owner snapshot users=%d", ownerUsers)
	}
	if _, err := database.Exec(`UPDATE users SET updated_at=? WHERE id=?`, int64(2), crossProcessOwnerID); err != nil {
		t.Fatalf("create pinned WAL frame: %v", err)
	}

	stopQueries := make(chan struct{})
	queryErrors := make(chan error, 1)
	go func() {
		ticker := time.NewTicker(5 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				var count int
				if err := pinnedRead.QueryRow(`SELECT COUNT(*) FROM users WHERE id=?`, crossProcessOwnerID).Scan(&count); err != nil {
					select {
					case queryErrors <- err:
					default:
					}
					return
				}
			case <-stopQueries:
				return
			}
		}
	}()
	defer close(stopQueries)
	var journalMode string
	if err := database.QueryRow(`PRAGMA journal_mode`).Scan(&journalMode); err != nil {
		t.Fatalf("owner journal mode: %v", err)
	}
	fmt.Printf("ready:%s\n", journalMode)

	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		select {
		case err := <-queryErrors:
			t.Fatalf("owner periodic query: %v", err)
		default:
		}
		switch scanner.Text() {
		case "verify-writer":
			var count int
			if err := database.QueryRow(`SELECT COUNT(*) FROM users WHERE id=?`, crossProcessPeerID).Scan(&count); err != nil || count != 1 {
				t.Fatalf("owner writer visibility count=%d err=%v", count, err)
			}
			fmt.Println("writer-visible")
		case "create-match":
			createCrossProcessMatch(t, database)
			fmt.Println("match-created")
		case "verify-match":
			var count int
			if err := database.QueryRow(`SELECT COUNT(*) FROM matches WHERE id=?`, crossProcessMatchID).Scan(&count); err != nil || count != 1 {
				t.Fatalf("owner match visibility count=%d err=%v", count, err)
			}
			fmt.Println("match-visible")
		case "close":
			fmt.Println("closed")
			return
		default:
			t.Fatal("unsupported owner command")
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
}

func runStoreWriterHelper(t *testing.T, path string) {
	t.Helper()
	database, err := Open(context.Background(), path)
	if err != nil {
		t.Fatalf("writer open: %v", err)
	}
	insertCrossProcessUser(t, database, crossProcessPeerID, "Peer", "peer")
	if err := database.Close(); err != nil {
		t.Fatalf("writer close: %v", err)
	}
}

func runStoreReaderHelper(t *testing.T, path string) {
	t.Helper()
	database, err := OpenReadOnly(context.Background(), path)
	if err != nil {
		t.Fatalf("reader open: %v", err)
	}
	defer database.Close()
	var users, matches int
	if err := database.QueryRow(`SELECT COUNT(*) FROM users WHERE id IN (?,?)`, crossProcessOwnerID, crossProcessPeerID).Scan(&users); err != nil {
		t.Fatalf("reader users: %v", err)
	}
	if err := database.QueryRow(`SELECT COUNT(*) FROM matches WHERE id=?`, crossProcessMatchID).Scan(&matches); err != nil {
		t.Fatalf("reader match: %v", err)
	}
	if users != 2 || matches != 1 {
		t.Fatalf("reader visibility users=%d matches=%d", users, matches)
	}
}

func insertCrossProcessUser(t *testing.T, database *sql.DB, id, nickname, normalized string) {
	t.Helper()
	if _, err := database.Exec(
		`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES (?,?,?,?,?)`,
		id, nickname, normalized, int64(1), int64(1),
	); err != nil {
		t.Fatalf("insert user: %v", err)
	}
}

func createCrossProcessMatch(t *testing.T, database *sql.DB) {
	t.Helper()
	transaction, err := database.Begin()
	if err != nil {
		t.Fatal(err)
	}
	defer transaction.Rollback()
	statements := []struct {
		query string
		args  []any
	}{
		{`INSERT INTO matches(id,game_id,status,revision,created_at,updated_at) VALUES (?,?,'active',0,1,1)`, []any{crossProcessMatchID, "gomoku"}},
		{`INSERT INTO match_players(match_id,user_id,nickname_snapshot,seat,color) VALUES (?,?,?,0,'black')`, []any{crossProcessMatchID, crossProcessOwnerID, "Owner"}},
		{`INSERT INTO match_players(match_id,user_id,nickname_snapshot,seat,color) VALUES (?,?,?,1,'white')`, []any{crossProcessMatchID, crossProcessPeerID, "Peer"}},
	}
	for _, statement := range statements {
		if _, err := transaction.Exec(statement.query, statement.args...); err != nil {
			t.Fatal(err)
		}
	}
	if err := transaction.Commit(); err != nil {
		t.Fatal(err)
	}
}

func runStoreHelper(t *testing.T, role, path string) {
	t.Helper()
	command := exec.Command(os.Args[0], "-test.run=^TestCrossProcessStoreHelper$")
	command.Env = append(os.Environ(),
		"GAMEBOX_STORE_HELPER_ROLE="+role,
		"GAMEBOX_STORE_HELPER_DB="+path,
	)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("%s helper failed: %v: %s", role, err, output)
	}
}

func existingSidecarIdentities(t *testing.T, path string) map[string]os.FileInfo {
	t.Helper()
	result := make(map[string]os.FileInfo, 2)
	for _, suffix := range []string{"-wal", "-shm"} {
		info, err := os.Stat(path + suffix)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatalf("stat %s sidecar: %v", suffix, err)
		}
		result[suffix] = info
	}
	return result
}

func wantOwnerLine(t *testing.T, lines <-chan string, want string) {
	t.Helper()
	select {
	case got, ok := <-lines:
		if !ok || got != want {
			t.Fatalf("owner line=(%q,%v), want %q", got, ok, want)
		}
	case <-time.After(10 * time.Second):
		t.Fatalf("timed out waiting for owner line %q", want)
	}
}
