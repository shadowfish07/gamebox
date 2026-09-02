package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/games/chinesecheckers"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/games/rps"
	"me.zqydev/gamebox/server/internal/store"
)

const (
	testPepper  = "gameboxctl-test-token-pepper-at-least-thirty-two-bytes"
	testMatchID = "11111111-1111-4111-8111-111111111111"
	testBlackID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	testWhiteID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
)

func TestInviteCreateWritesOnlyDistinctDigestsAndOneJSONDocument(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	now := time.Date(2026, time.August, 20, 3, 4, 5, 678900000, time.FixedZone("fixture", 8*60*60))
	plaintexts := []string{"ABCD1234WXYZ", "WXYZ9876ABCD"}
	next := 0
	deps := commandDeps{
		lookupEnv: pepperLookup(testPepper),
		now:       func() time.Time { return now },
		randomInviteCode: func() (string, error) {
			if next >= len(plaintexts) {
				t.Fatalf("RandomInviteCode call = %d", next)
			}
			value := plaintexts[next]
			next++
			return value, nil
		},
	}
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"invite", "create", "--count", "2", "--db", databasePath, "--json"}, &stdout, &stderr, deps)
	if code != exitOK || stderr.Len() != 0 {
		t.Fatalf("run exit=%d stderr=%q", code, stderr.String())
	}
	if got, want := stdout.String(), "{\"invites\":[\"ABCD1234WXYZ\",\"WXYZ9876ABCD\"]}\n"; got != want {
		t.Fatalf("stdout=%q want=%q", got, want)
	}
	if next != 2 {
		t.Fatalf("token calls=%d want=2", next)
	}

	database := openDatabase(t, databasePath)
	defer database.Close()
	rows, err := database.Query(`SELECT code_hash,created_at,consumed_by,consumed_at FROM invite_codes ORDER BY code_hash`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var hashes []string
	for rows.Next() {
		var hash string
		var createdAt int64
		var consumedBy sql.NullString
		var consumedAt sql.NullInt64
		if err := rows.Scan(&hash, &createdAt, &consumedBy, &consumedAt); err != nil {
			t.Fatal(err)
		}
		if createdAt != now.UTC().UnixMilli() || consumedBy.Valid || consumedAt.Valid {
			t.Fatalf("invite metadata=(%d,%v,%v)", createdAt, consumedBy, consumedAt)
		}
		hashes = append(hashes, hash)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	wantHashes := make([]string, 0, len(plaintexts))
	for _, plaintext := range plaintexts {
		hash, err := auth.HashToken(testPepper, plaintext)
		if err != nil {
			t.Fatal(err)
		}
		wantHashes = append(wantHashes, hash)
	}
	if len(hashes) != 2 || !sameStringSet(hashes, wantHashes) {
		t.Fatalf("stored hashes=%v want=%v", hashes, wantHashes)
	}
	contents, err := os.ReadFile(databasePath)
	if err != nil {
		t.Fatal(err)
	}
	for _, plaintext := range plaintexts {
		if bytes.Contains(contents, []byte(plaintext)) {
			t.Fatalf("database contains plaintext invite %q", plaintext)
		}
	}
}

func TestInviteCreateRejectsBoundsAndStrictSyntaxBeforeOpeningDatabase(t *testing.T) {
	tests := []struct {
		name string
		args []string
	}{
		{name: "zero", args: []string{"invite", "create", "--count", "0", "--db", "DB", "--json"}},
		{name: "over maximum", args: []string{"invite", "create", "--count", "1001", "--db", "DB", "--json"}},
		{name: "missing count", args: []string{"invite", "create", "--db", "DB", "--json"}},
		{name: "missing db", args: []string{"invite", "create", "--count", "2", "--json"}},
		{name: "missing json", args: []string{"invite", "create", "--count", "2", "--db", "DB"}},
		{name: "duplicate count", args: []string{"invite", "create", "--count", "2", "--count", "3", "--db", "DB", "--json"}},
		{name: "json value", args: []string{"invite", "create", "--count", "2", "--db", "DB", "--json=false"}},
		{name: "extra", args: []string{"invite", "create", "--count", "2", "--db", "DB", "--json", "extra"}},
		{name: "unknown", args: []string{"invite", "create", "--count", "2", "--db", "DB", "--json", "--pepper", "secret"}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
			args := append([]string(nil), test.args...)
			for index := range args {
				if args[index] == "DB" {
					args[index] = databasePath
				}
			}
			var stdout, stderr bytes.Buffer
			code := run(context.Background(), args, &stdout, &stderr, commandDeps{
				lookupEnv: pepperLookup(testPepper), now: time.Now, randomInviteCode: auth.RandomInviteCode,
			})
			if code != exitUsage || stdout.Len() != 0 || !strings.HasPrefix(stderr.String(), "usage: gameboxctl ") {
				t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
			}
			if _, err := os.Stat(databasePath); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("database touched before validation: %v", err)
			}
		})
	}
}

func TestInviteCreateFailureDoesNotPrintOrPartiallyCommit(t *testing.T) {
	t.Run("entropy failure", func(t *testing.T) {
		databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
		var stdout, stderr bytes.Buffer
		code := run(context.Background(), []string{"invite", "create", "--count", "2", "--db", databasePath, "--json"}, &stdout, &stderr, commandDeps{
			lookupEnv: pepperLookup(testPepper), now: time.Now,
			randomInviteCode: func() (string, error) { return "", errors.New("entropy-secret-detail") },
		})
		if code != exitFailure || stdout.Len() != 0 || stderr.String() != "error: invite creation failed\n" || strings.Contains(stderr.String(), "entropy-secret-detail") {
			t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
		}
		if _, err := os.Stat(databasePath); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("database touched after entropy failure: %v", err)
		}
	})

	t.Run("batch collision regenerates candidate", func(t *testing.T) {
		databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
		generated := []string{"ABCD1234WXYZ", "ABCD1234WXYZ", "WXYZ9876ABCD"}
		var calls int
		var stdout, stderr bytes.Buffer
		code := run(context.Background(), []string{"invite", "create", "--count", "2", "--db", databasePath, "--json"}, &stdout, &stderr, commandDeps{
			lookupEnv: pepperLookup(testPepper), now: time.Now,
			randomInviteCode: func() (string, error) {
				value := generated[calls]
				calls++
				return value, nil
			},
		})
		if code != exitOK || stdout.String() != "{\"invites\":[\"ABCD1234WXYZ\",\"WXYZ9876ABCD\"]}\n" || stderr.Len() != 0 {
			t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
		}
		if calls != 3 {
			t.Fatalf("generation calls=%d want=3", calls)
		}
		database := openDatabase(t, databasePath)
		defer database.Close()
		var count int
		if err := database.QueryRow(`SELECT COUNT(*) FROM invite_codes`).Scan(&count); err != nil || count != 2 {
			t.Fatalf("invite count=%d err=%v", count, err)
		}
	})

	t.Run("existing digest collision regenerates candidate", func(t *testing.T) {
		databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
		database := openDatabase(t, databasePath)
		existingHash, err := auth.HashToken(testPepper, "OLD1234ABCDE")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := database.Exec(`INSERT INTO invite_codes(code_hash,created_at) VALUES (?,?)`, existingHash, time.Now().UnixMilli()); err != nil {
			t.Fatal(err)
		}
		if err := database.Close(); err != nil {
			t.Fatal(err)
		}
		generated := []string{"NEW1234ABCDE", "OLD1234ABCDE", "REPL1234ABCD"}
		var calls int
		var stdout, stderr bytes.Buffer
		code := run(context.Background(), []string{"invite", "create", "--count", "2", "--db", databasePath, "--json"}, &stdout, &stderr, commandDeps{
			lookupEnv: pepperLookup(testPepper), now: time.Now,
			randomInviteCode: func() (string, error) {
				value := generated[calls]
				calls++
				return value, nil
			},
		})
		if code != exitOK || stdout.String() != "{\"invites\":[\"NEW1234ABCDE\",\"REPL1234ABCD\"]}\n" || stderr.Len() != 0 {
			t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
		}
		if calls != 3 {
			t.Fatalf("generation calls=%d want=3", calls)
		}
		database = openDatabase(t, databasePath)
		defer database.Close()
		var count int
		if err := database.QueryRow(`SELECT COUNT(*) FROM invite_codes`).Scan(&count); err != nil || count != 3 {
			t.Fatalf("invite count=%d err=%v", count, err)
		}
		freshHash, err := auth.HashToken(testPepper, "NEW1234ABCDE")
		if err != nil {
			t.Fatal(err)
		}
		var freshCount int
		if err := database.QueryRow(`SELECT COUNT(*) FROM invite_codes WHERE code_hash=?`, freshHash).Scan(&freshCount); err != nil || freshCount != 1 {
			t.Fatalf("fresh invite count=%d err=%v", freshCount, err)
		}
	})

	t.Run("collision retry exhaustion fails without opening database", func(t *testing.T) {
		databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
		var stdout, stderr bytes.Buffer
		code := run(context.Background(), []string{"invite", "create", "--count", "2", "--db", databasePath, "--json"}, &stdout, &stderr, commandDeps{
			lookupEnv: pepperLookup(testPepper), now: time.Now,
			randomInviteCode: func() (string, error) { return "SAME1234CODE", nil },
		})
		if code != exitFailure || stdout.Len() != 0 || stderr.String() != "error: invite creation failed\n" {
			t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
		}
		if _, err := os.Stat(databasePath); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("database touched after retry exhaustion: %v", err)
		}
	})

	t.Run("missing pepper is redacted", func(t *testing.T) {
		databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
		var stdout, stderr bytes.Buffer
		code := run(context.Background(), []string{"invite", "create", "--count", "1", "--db", databasePath, "--json"}, &stdout, &stderr, commandDeps{
			lookupEnv: func(string) (string, bool) { return "", false }, now: time.Now, randomInviteCode: auth.RandomInviteCode,
		})
		if code != exitFailure || stdout.Len() != 0 || stderr.String() != "error: invite creation failed\n" {
			t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
		}
		if _, err := os.Stat(databasePath); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("database touched without pepper: %v", err)
		}
	})
}

func TestMatchShowReplaysSnapshotWithPlayersAndDoesNotMutateRows(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	seedMatch(t, databasePath)
	before := readMutableRows(t, databasePath)

	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"match", "show", "--id", testMatchID, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
	if code != exitOK || stderr.Len() != 0 {
		t.Fatalf("run exit=%d stderr=%q", code, stderr.String())
	}
	var response matchShowResponse
	decoder := json.NewDecoder(bytes.NewReader(stdout.Bytes()))
	if err := decoder.Decode(&response); err != nil {
		t.Fatalf("decode stdout %q: %v", stdout.String(), err)
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		t.Fatalf("stdout contains more than one JSON document: %v", err)
	}
	if !strings.HasSuffix(stdout.String(), "\n") || strings.Count(stdout.String(), "\n") != 1 {
		t.Fatalf("stdout is not one JSON line: %q", stdout.String())
	}
	if response.ID != testMatchID || response.GameID != gomoku.GameID || response.Status != "active" || response.Revision != 1 || response.Result != nil || response.WinnerUserID != nil || response.BoardSize != 15 || len(response.Board) != 225 {
		t.Fatalf("response metadata=%+v board=%d", response, len(response.Board))
	}
	wantPlayers := []matchPlayerResponse{
		{UserID: testBlackID, Seat: 0, Color: "black"},
		{UserID: testWhiteID, Seat: 1, Color: "white"},
	}
	if !reflect.DeepEqual(response.Players, wantPlayers) {
		t.Fatalf("players=%+v want=%+v", response.Players, wantPlayers)
	}
	for index, cell := range response.Board {
		want := 0
		if index == 0 {
			want = 1
		}
		if cell != want {
			t.Fatalf("board[%d]=%d want=%d", index, cell, want)
		}
	}
	after := readMutableRows(t, databasePath)
	if !reflect.DeepEqual(after, before) {
		t.Fatalf("match show mutated application rows: before=%v after=%v", before, after)
	}
}

func TestMatchShowReplaysInitialChineseCheckersBoard(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	seedChineseCheckersMatch(t, databasePath)

	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"match", "show", "--id", testMatchID, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
	if code != exitOK || stderr.Len() != 0 {
		t.Fatalf("run exit=%d stderr=%q", code, stderr.String())
	}
	var response matchShowResponse
	if err := json.Unmarshal(stdout.Bytes(), &response); err != nil {
		t.Fatalf("decode stdout %q: %v", stdout.String(), err)
	}
	if !bytes.Contains(stdout.Bytes(), []byte(`"board":[`)) {
		t.Fatalf("board is not encoded as a JSON array: %q", stdout.String())
	}
	if response.ID != testMatchID || response.GameID != chinesecheckers.GameID || response.Status != "active" || response.Revision != 0 || response.BoardSize != chinesecheckers.BoardCells || len(response.Board) != chinesecheckers.BoardCells || response.NextColor != "black" {
		t.Fatalf("response metadata=%+v board=%d", response, len(response.Board))
	}
	for index, cell := range response.Board {
		want := int(chinesecheckers.Empty)
		if index <= 9 {
			want = int(chinesecheckers.Black)
		} else if index >= 111 {
			want = int(chinesecheckers.White)
		}
		if cell != want {
			t.Fatalf("board[%d]=%d want=%d", index, cell, want)
		}
	}
}

func TestMatchShowReturnsEmptyBoardForRPS(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	seedRPSMatch(t, databasePath)

	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"match", "show", "--id", testMatchID, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
	if code != exitOK || stderr.Len() != 0 {
		t.Fatalf("run exit=%d stderr=%q", code, stderr.String())
	}
	var response matchShowResponse
	if err := json.Unmarshal(stdout.Bytes(), &response); err != nil {
		t.Fatalf("decode stdout %q: %v", stdout.String(), err)
	}
	if !bytes.Contains(stdout.Bytes(), []byte(`"board":[]`)) {
		t.Fatalf("RPS board is not encoded as an empty JSON array: %q", stdout.String())
	}
	if response.GameID != rps.GameID || response.BoardSize != 0 || len(response.Board) != 0 || response.Format != rps.FormatSingleRound || response.Round != 1 || len(response.Scores) != 0 {
		t.Fatalf("RPS response metadata=%+v board=%d", response, len(response.Board))
	}
}

func TestMatchShowUnknownAndInvalidIDsHaveStableNonzeroExit(t *testing.T) {
	databasePath := filepath.Join(t.TempDir(), "gamebox.sqlite")
	seedMatch(t, databasePath)
	tests := []struct {
		name       string
		id         string
		wantExit   int
		wantStderr string
	}{
		{name: "unknown", id: "22222222-2222-4222-8222-222222222222", wantExit: exitFailure, wantStderr: "error: match not found\n"},
		{name: "noncanonical", id: "11111111-1111-4111-8111-111111111111 ", wantExit: exitUsage, wantStderr: matchUsage + "\n"},
		{name: "not uuid", id: "secret-match", wantExit: exitUsage, wantStderr: matchUsage + "\n"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var stdout, stderr bytes.Buffer
			code := run(context.Background(), []string{"match", "show", "--id", test.id, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
			if code != test.wantExit || stdout.Len() != 0 || stderr.String() != test.wantStderr || strings.Contains(stderr.String(), test.id) {
				t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
			}
		})
	}
}

func TestMatchShowMissingDatabaseLeavesDirectoryUnchanged(t *testing.T) {
	directory := t.TempDir()
	databasePath := filepath.Join(directory, "missing.sqlite")
	before := snapshotDirectory(t, directory)
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"match", "show", "--id", testMatchID, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
	if code != exitFailure || stdout.Len() != 0 || stderr.String() != matchFailed+"\n" {
		t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
	}
	if after := snapshotDirectory(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("missing match query changed directory: before=%+v after=%+v", before, after)
	}
}

func TestMatchShowPreservesDatabaseSchemaBytesMetadataAndDirectory(t *testing.T) {
	directory := t.TempDir()
	databasePath := filepath.Join(directory, "gamebox.sqlite")
	seedMatch(t, databasePath)
	beforeRows := readMutableRows(t, databasePath)
	before := snapshotDirectory(t, directory)

	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"match", "show", "--id", testMatchID, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
	if code != exitOK || stderr.Len() != 0 {
		t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
	}
	if after := snapshotDirectory(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("match show changed filesystem state: before=%+v after=%+v", before, after)
	}
	if afterRows := readMutableRows(t, databasePath); !reflect.DeepEqual(afterRows, beforeRows) {
		t.Fatalf("match show changed application rows: before=%+v after=%+v", beforeRows, afterRows)
	}
}

func TestMatchShowReadsLatestLiveWALWithoutMutatingSourceFiles(t *testing.T) {
	directory := t.TempDir()
	databasePath := filepath.Join(directory, "gamebox.sqlite")
	seedMatch(t, databasePath)
	writable := openDatabase(t, databasePath)
	defer writable.Close()
	now := time.Date(2026, time.August, 20, 1, 2, 4, 0, time.UTC).UnixMilli()
	transaction, err := writable.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := transaction.Exec(`UPDATE matches SET revision=2,updated_at=? WHERE id=?`, now, testMatchID); err != nil {
		_ = transaction.Rollback()
		t.Fatal(err)
	}
	if _, err := transaction.Exec(`INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at) VALUES (?,?,?,?,?,?,?)`,
		testMatchID, 2, gomoku.MoveAccepted, "dddddddd-dddd-4ddd-8ddd-dddddddddddd", testWhiteID,
		`{"x":1,"y":0,"color":"white","userId":"`+testWhiteID+`"}`, now); err != nil {
		_ = transaction.Rollback()
		t.Fatal(err)
	}
	if err := transaction.Commit(); err != nil {
		t.Fatal(err)
	}
	before := snapshotDirectory(t, directory)
	for _, name := range []string{"gamebox.sqlite", "gamebox.sqlite-wal", "gamebox.sqlite-shm"} {
		if _, exists := before[name]; !exists {
			t.Fatalf("live source missing %s: %+v", name, before)
		}
	}

	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"match", "show", "--id", testMatchID, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
	if code != exitOK || stderr.Len() != 0 {
		t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
	}
	var response matchShowResponse
	if err := json.Unmarshal(stdout.Bytes(), &response); err != nil {
		t.Fatalf("decode live WAL response: %v", err)
	}
	if response.Revision != 2 || response.Board[0] != int(gomoku.Black) || response.Board[1] != int(gomoku.White) {
		t.Fatalf("live WAL response revision/board=(%d,%d,%d)", response.Revision, response.Board[0], response.Board[1])
	}
	if after := snapshotDirectory(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("match show changed live source bytes or metadata: before=%+v after=%+v", before, after)
	}
}

func TestMatchShowRejectsUnmigratedAndInsecureDatabasesWithoutMutation(t *testing.T) {
	t.Run("unmigrated", func(t *testing.T) {
		directory := t.TempDir()
		databasePath := filepath.Join(directory, "unmigrated.sqlite")
		database, err := sql.Open("sqlite", "file:"+databasePath)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := database.Exec(`CREATE TABLE placeholder (id INTEGER PRIMARY KEY)`); err != nil {
			_ = database.Close()
			t.Fatal(err)
		}
		if err := database.Close(); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(databasePath, 0o600); err != nil {
			t.Fatal(err)
		}
		assertMatchShowFailsWithoutFilesystemMutation(t, directory, databasePath)
	})

	t.Run("insecure mode", func(t *testing.T) {
		directory := t.TempDir()
		databasePath := filepath.Join(directory, "insecure.sqlite")
		seedMatch(t, databasePath)
		if err := os.Chmod(databasePath, 0o644); err != nil {
			t.Fatal(err)
		}
		assertMatchShowFailsWithoutFilesystemMutation(t, directory, databasePath)
	})

	t.Run("database symlink", func(t *testing.T) {
		directory := t.TempDir()
		target := filepath.Join(directory, "target.sqlite")
		seedMatch(t, target)
		databasePath := filepath.Join(directory, "link.sqlite")
		if err := os.Symlink(target, databasePath); err != nil {
			t.Fatal(err)
		}
		assertMatchShowFailsWithoutFilesystemMutation(t, directory, databasePath)
	})
}

func TestHelpAndUnknownCommandsUseDocumentedExitCodes(t *testing.T) {
	tests := []struct {
		args     []string
		wantExit int
		stdout   bool
	}{
		{args: []string{"--help"}, wantExit: exitOK, stdout: true},
		{args: []string{"invite", "create", "--help"}, wantExit: exitOK, stdout: true},
		{args: []string{"match", "show", "--help"}, wantExit: exitOK, stdout: true},
		{args: nil, wantExit: exitUsage},
		{args: []string{"unknown"}, wantExit: exitUsage},
	}
	for _, test := range tests {
		var stdout, stderr bytes.Buffer
		code := run(context.Background(), test.args, &stdout, &stderr, defaultCommandDeps())
		if code != test.wantExit {
			t.Fatalf("run(%v) exit=%d want=%d", test.args, code, test.wantExit)
		}
		if test.stdout {
			if stdout.Len() == 0 || stderr.Len() != 0 {
				t.Fatalf("help output stdout=%q stderr=%q", stdout.String(), stderr.String())
			}
		} else if stdout.Len() != 0 || !strings.HasPrefix(stderr.String(), "usage: gameboxctl ") {
			t.Fatalf("usage output stdout=%q stderr=%q", stdout.String(), stderr.String())
		}
	}
}

func pepperLookup(pepper string) func(string) (string, bool) {
	return func(name string) (string, bool) {
		if name == "GAMEBOX_TOKEN_PEPPER" {
			return pepper, true
		}
		return "", false
	}
}

func openDatabase(t *testing.T, path string) *sql.DB {
	t.Helper()
	database, err := store.Open(context.Background(), path)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	return database
}

func sameStringSet(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	counts := make(map[string]int, len(left))
	for _, value := range left {
		counts[value]++
	}
	for _, value := range right {
		counts[value]--
	}
	for _, count := range counts {
		if count != 0 {
			return false
		}
	}
	return true
}

func seedMatch(t *testing.T, path string) {
	t.Helper()
	database := openDatabase(t, path)
	now := time.Date(2026, time.August, 20, 1, 2, 3, 0, time.UTC).UnixMilli()
	statements := []struct {
		query string
		args  []any
	}{
		{`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES (?,?,?,?,?)`, []any{testBlackID, "Alice", "alice", now, now}},
		{`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES (?,?,?,?,?)`, []any{testWhiteID, "Bob", "bob", now, now}},
		{`INSERT INTO matches(id,game_id,status,revision,created_at,updated_at) VALUES (?,?,?,?,?,?)`, []any{testMatchID, gomoku.GameID, "active", 1, now, now}},
		{`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,?,?)`, []any{testMatchID, testBlackID, 0, "black"}},
		{`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,?,?)`, []any{testMatchID, testWhiteID, 1, "white"}},
		{`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, []any{gomoku.GameID, testBlackID, testMatchID}},
		{`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, []any{gomoku.GameID, testWhiteID, testMatchID}},
		{`INSERT INTO match_events(match_id,revision,event_type,action_id,actor_user_id,payload_json,created_at) VALUES (?,?,?,?,?,?,?)`, []any{
			testMatchID, 1, gomoku.MoveAccepted, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", testBlackID,
			`{"x":0,"y":0,"color":"black","userId":"` + testBlackID + `"}`, now,
		}},
	}
	for _, statement := range statements {
		if _, err := database.Exec(statement.query, statement.args...); err != nil {
			database.Close()
			t.Fatalf("seed database: %v", err)
		}
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
}

func seedChineseCheckersMatch(t *testing.T, path string) {
	t.Helper()
	database := openDatabase(t, path)
	now := time.Date(2026, time.August, 20, 1, 2, 3, 0, time.UTC).UnixMilli()
	statements := []struct {
		query string
		args  []any
	}{
		{`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES (?,?,?,?,?)`, []any{testBlackID, "Alice", "alice", now, now}},
		{`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES (?,?,?,?,?)`, []any{testWhiteID, "Bob", "bob", now, now}},
		{`INSERT INTO matches(id,game_id,status,revision,created_at,updated_at) VALUES (?,?,?,?,?,?)`, []any{testMatchID, chinesecheckers.GameID, "active", 0, now, now}},
		{`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,?,?)`, []any{testMatchID, testBlackID, 0, "black"}},
		{`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,?,?)`, []any{testMatchID, testWhiteID, 1, "white"}},
		{`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, []any{chinesecheckers.GameID, testBlackID, testMatchID}},
		{`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, []any{chinesecheckers.GameID, testWhiteID, testMatchID}},
	}
	for _, statement := range statements {
		if _, err := database.Exec(statement.query, statement.args...); err != nil {
			database.Close()
			t.Fatalf("seed database: %v", err)
		}
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
}

func seedRPSMatch(t *testing.T, path string) {
	t.Helper()
	database := openDatabase(t, path)
	now := time.Date(2026, time.August, 20, 1, 2, 3, 0, time.UTC).UnixMilli()
	statements := []struct {
		query string
		args  []any
	}{
		{`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES (?,?,?,?,?)`, []any{testBlackID, "Alice", "alice", now, now}},
		{`INSERT INTO users(id,nickname,normalized_nickname,created_at,updated_at) VALUES (?,?,?,?,?)`, []any{testWhiteID, "Bob", "bob", now, now}},
		{`INSERT INTO matches(id,game_id,status,revision,game_config_json,created_at,updated_at) VALUES (?,?,?,?,?,?,?)`, []any{testMatchID, rps.GameID, "active", 0, `{"format":"single_round"}`, now, now}},
		{`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,?,?)`, []any{testMatchID, testBlackID, 0, "black"}},
		{`INSERT INTO match_players(match_id,user_id,seat,color) VALUES (?,?,?,?)`, []any{testMatchID, testWhiteID, 1, "white"}},
		{`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, []any{rps.GameID, testBlackID, testMatchID}},
		{`INSERT INTO active_game_slots(game_id,user_id,match_id) VALUES (?,?,?)`, []any{rps.GameID, testWhiteID, testMatchID}},
	}
	for _, statement := range statements {
		if _, err := database.Exec(statement.query, statement.args...); err != nil {
			database.Close()
			t.Fatalf("seed database: %v", err)
		}
	}
	if err := database.Close(); err != nil {
		t.Fatal(err)
	}
}

type mutableRows struct {
	users   []string
	matches []string
	events  int
	invites int
	refresh int
	tickets int
	resumes int
}

type fileSnapshot struct {
	Mode    os.FileMode
	Size    int64
	ModTime int64
	Hash    [sha256.Size]byte
	Link    string
}

func snapshotDirectory(t *testing.T, directory string) map[string]fileSnapshot {
	t.Helper()
	entries, err := os.ReadDir(directory)
	if err != nil {
		t.Fatal(err)
	}
	result := make(map[string]fileSnapshot, len(entries)+1)
	directoryInfo, err := os.Stat(directory)
	if err != nil {
		t.Fatal(err)
	}
	result["."] = fileSnapshot{Mode: directoryInfo.Mode(), Size: directoryInfo.Size(), ModTime: directoryInfo.ModTime().UnixNano()}
	for _, entry := range entries {
		path := filepath.Join(directory, entry.Name())
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		snapshot := fileSnapshot{Mode: info.Mode(), Size: info.Size(), ModTime: info.ModTime().UnixNano()}
		switch {
		case info.Mode().IsRegular():
			contents, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			snapshot.Hash = sha256.Sum256(contents)
		case info.Mode()&os.ModeSymlink != 0:
			snapshot.Link, err = os.Readlink(path)
			if err != nil {
				t.Fatal(err)
			}
		}
		result[entry.Name()] = snapshot
	}
	return result
}

func assertMatchShowFailsWithoutFilesystemMutation(t *testing.T, directory, databasePath string) {
	t.Helper()
	before := snapshotDirectory(t, directory)
	var stdout, stderr bytes.Buffer
	code := run(context.Background(), []string{"match", "show", "--id", testMatchID, "--db", databasePath, "--json"}, &stdout, &stderr, defaultCommandDeps())
	if code != exitFailure || stdout.Len() != 0 || stderr.String() != matchFailed+"\n" {
		t.Fatalf("run=(%d,%q,%q)", code, stdout.String(), stderr.String())
	}
	if after := snapshotDirectory(t, directory); !reflect.DeepEqual(after, before) {
		t.Fatalf("failed match show changed filesystem: before=%+v after=%+v", before, after)
	}
}

func readMutableRows(t *testing.T, path string) mutableRows {
	t.Helper()
	database := openDatabase(t, path)
	defer database.Close()
	result := mutableRows{}
	rows, err := database.Query(`SELECT id || ':' || COALESCE(last_seen_at,'null') || ':' || updated_at FROM users ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			t.Fatal(err)
		}
		result.users = append(result.users, value)
	}
	if err := rows.Close(); err != nil {
		t.Fatal(err)
	}
	rows, err = database.Query(`SELECT id || ':' || status || ':' || revision || ':' || COALESCE(both_offline_since,'null') || ':' || updated_at FROM matches ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var value string
		if err := rows.Scan(&value); err != nil {
			t.Fatal(err)
		}
		result.matches = append(result.matches, value)
	}
	if err := rows.Close(); err != nil {
		t.Fatal(err)
	}
	for query, destination := range map[string]*int{
		`SELECT COUNT(*) FROM match_events`:   &result.events,
		`SELECT COUNT(*) FROM invite_codes`:   &result.invites,
		`SELECT COUNT(*) FROM refresh_tokens`: &result.refresh,
		`SELECT COUNT(*) FROM launch_tickets`: &result.tickets,
		`SELECT COUNT(*) FROM resume_tokens`:  &result.resumes,
	} {
		if err := database.QueryRow(query).Scan(destination); err != nil {
			t.Fatal(err)
		}
	}
	return result
}
