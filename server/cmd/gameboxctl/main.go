package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/games"
	"me.zqydev/gamebox/server/internal/games/chinesecheckers"
	"me.zqydev/gamebox/server/internal/games/flightchess"
	"me.zqydev/gamebox/server/internal/games/gomoku"
	"me.zqydev/gamebox/server/internal/games/rps"
	"me.zqydev/gamebox/server/internal/matches"
	"me.zqydev/gamebox/server/internal/store"
)

const (
	exitOK      = 0
	exitFailure = 1
	exitUsage   = 2

	maximumInviteCount              = 1000
	maximumInviteGenerationAttempts = maximumInviteCount * 10
	minimumPepperBytes              = 32

	rootUsage    = "usage: gameboxctl <invite create|match show> [options]"
	inviteUsage  = "usage: gameboxctl invite create --count N --db PATH --json"
	matchUsage   = "usage: gameboxctl match show --id UUID --db PATH --json"
	inviteFailed = "error: invite creation failed"
	matchFailed  = "error: match query failed"
	matchMissing = "error: match not found"
)

type commandDeps struct {
	lookupEnv        func(string) (string, bool)
	now              func() time.Time
	randomInviteCode func() (string, error)
}

func defaultCommandDeps() commandDeps {
	return commandDeps{lookupEnv: os.LookupEnv, now: time.Now, randomInviteCode: auth.RandomInviteCode}
}

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Stdout, os.Stderr, defaultCommandDeps()))
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer, deps commandDeps) int {
	if stdout == nil || stderr == nil {
		return exitFailure
	}
	if len(args) == 1 && isHelp(args[0]) {
		writeLine(stdout, rootUsage)
		return exitOK
	}
	if len(args) < 2 {
		writeLine(stderr, rootUsage)
		return exitUsage
	}
	switch {
	case args[0] == "invite" && args[1] == "create":
		return runInviteCreate(ctx, args[2:], stdout, stderr, deps)
	case args[0] == "match" && args[1] == "show":
		return runMatchShow(ctx, args[2:], stdout, stderr)
	default:
		writeLine(stderr, rootUsage)
		return exitUsage
	}
}

type inviteOptions struct {
	count int
	db    string
}

type inviteCandidate struct {
	plaintext string
	digest    string
}

func runInviteCreate(ctx context.Context, args []string, stdout, stderr io.Writer, deps commandDeps) int {
	if len(args) == 1 && isHelp(args[0]) {
		writeLine(stdout, inviteUsage)
		return exitOK
	}
	options, ok := parseInviteOptions(args)
	if !ok {
		writeLine(stderr, inviteUsage)
		return exitUsage
	}
	if ctx == nil || deps.lookupEnv == nil || deps.now == nil || deps.randomInviteCode == nil {
		writeLine(stderr, inviteFailed)
		return exitFailure
	}
	pepper, present := deps.lookupEnv("GAMEBOX_TOKEN_PEPPER")
	if !present || len([]byte(pepper)) < minimumPepperBytes {
		writeLine(stderr, inviteFailed)
		return exitFailure
	}

	candidates := make([]inviteCandidate, 0, options.count)
	seenPlaintexts := make(map[string]struct{}, options.count)
	seenDigests := make(map[string]struct{}, options.count)
	generationAttempts := 0
	for len(candidates) < options.count {
		candidate, generated := nextInviteCandidate(deps.randomInviteCode, pepper, seenPlaintexts, seenDigests, &generationAttempts)
		if !generated {
			writeLine(stderr, inviteFailed)
			return exitFailure
		}
		candidates = append(candidates, candidate)
	}

	database, err := store.Open(ctx, options.db)
	if err != nil {
		writeLine(stderr, inviteFailed)
		return exitFailure
	}
	defer database.Close()
	transaction, err := database.BeginTx(ctx, nil)
	if err != nil {
		writeLine(stderr, inviteFailed)
		return exitFailure
	}
	committed := false
	defer func() {
		if !committed {
			_ = transaction.Rollback()
		}
	}()
	createdAt := deps.now().UTC().UnixMilli()
	for index := 0; index < len(candidates); {
		result, insertErr := transaction.ExecContext(ctx, `INSERT OR IGNORE INTO invite_codes(code_hash,created_at) VALUES (?,?)`, candidates[index].digest, createdAt)
		if insertErr != nil {
			writeLine(stderr, inviteFailed)
			return exitFailure
		}
		affected, rowsErr := result.RowsAffected()
		if rowsErr != nil {
			writeLine(stderr, inviteFailed)
			return exitFailure
		}
		if affected == 1 {
			index++
			continue
		}
		replacement, generated := nextInviteCandidate(deps.randomInviteCode, pepper, seenPlaintexts, seenDigests, &generationAttempts)
		if !generated {
			writeLine(stderr, inviteFailed)
			return exitFailure
		}
		candidates[index] = replacement
	}
	if err := transaction.Commit(); err != nil {
		writeLine(stderr, inviteFailed)
		return exitFailure
	}
	committed = true
	plaintexts := make([]string, len(candidates))
	for index, candidate := range candidates {
		plaintexts[index] = candidate.plaintext
	}
	if err := json.NewEncoder(stdout).Encode(struct {
		Invites []string `json:"invites"`
	}{Invites: plaintexts}); err != nil {
		writeLine(stderr, inviteFailed)
		return exitFailure
	}
	return exitOK
}

func nextInviteCandidate(
	generate func() (string, error),
	pepper string,
	seenPlaintexts, seenDigests map[string]struct{},
	attempts *int,
) (inviteCandidate, bool) {
	for *attempts < maximumInviteGenerationAttempts {
		*attempts = *attempts + 1
		plaintext, err := generate()
		if err != nil || plaintext == "" {
			return inviteCandidate{}, false
		}
		if _, duplicate := seenPlaintexts[plaintext]; duplicate {
			continue
		}
		digest, err := auth.HashToken(pepper, plaintext)
		if err != nil {
			return inviteCandidate{}, false
		}
		if _, duplicate := seenDigests[digest]; duplicate {
			continue
		}
		seenPlaintexts[plaintext] = struct{}{}
		seenDigests[digest] = struct{}{}
		return inviteCandidate{plaintext: plaintext, digest: digest}, true
	}
	return inviteCandidate{}, false
}

func parseInviteOptions(args []string) (inviteOptions, bool) {
	values, ok := parseStrictOptions(args, map[string]bool{"--count": true, "--db": true, "--json": false})
	if !ok || values["--json"] != "true" {
		return inviteOptions{}, false
	}
	count, err := strconv.Atoi(values["--count"])
	if err != nil || count < 1 || count > maximumInviteCount || strings.TrimSpace(values["--db"]) == "" {
		return inviteOptions{}, false
	}
	return inviteOptions{count: count, db: values["--db"]}, true
}

type matchOptions struct {
	id string
	db string
}

type matchPlayerResponse struct {
	UserID string        `json:"userId"`
	Seat   int           `json:"seat"`
	Color  matches.Color `json:"color"`
}

type matchShowResponse struct {
	ID           string                         `json:"id"`
	GameID       string                         `json:"gameId"`
	Status       string                         `json:"status"`
	Revision     int64                          `json:"revision"`
	Result       *string                        `json:"result"`
	WinnerUserID *string                        `json:"winnerUserId"`
	Players      []matchPlayerResponse          `json:"players"`
	BoardSize    int                            `json:"boardSize"`
	Board        []int                          `json:"board"`
	NextColor    string                         `json:"nextColor,omitempty"`
	Format       string                         `json:"format,omitempty"`
	Round        int                            `json:"round,omitempty"`
	Scores       map[string]int                 `json:"scores,omitempty"`
	Phase        string                         `json:"phase,omitempty"`
	Dice         int                            `json:"dice,omitempty"`
	Pieces       map[string][]flightchess.Piece `json:"pieces,omitempty"`
}

type gomokuStateView struct {
	Board     [gomoku.BoardSize * gomoku.BoardSize]uint8 `json:"board"`
	BoardSize int                                        `json:"boardSize"`
}

type chineseCheckersStateView struct {
	Board     [chinesecheckers.BoardCells]uint8 `json:"board"`
	NextColor string                            `json:"nextColor"`
}

type flightChessStateView struct {
	Phase     string                         `json:"phase"`
	NextColor string                         `json:"nextColor"`
	Dice      int                            `json:"dice"`
	Pieces    map[string][]flightchess.Piece `json:"pieces"`
}

type rpsStateView struct {
	Format string         `json:"format"`
	Round  int            `json:"round"`
	Scores map[string]int `json:"scores"`
}

func runMatchShow(ctx context.Context, args []string, stdout, stderr io.Writer) int {
	if len(args) == 1 && isHelp(args[0]) {
		writeLine(stdout, matchUsage)
		return exitOK
	}
	options, ok := parseMatchOptions(args)
	if !ok {
		writeLine(stderr, matchUsage)
		return exitUsage
	}
	if ctx == nil {
		writeLine(stderr, matchFailed)
		return exitFailure
	}
	database, err := store.OpenReadOnly(ctx, options.db)
	if err != nil {
		writeLine(stderr, matchFailed)
		return exitFailure
	}
	defer database.Close()
	service, err := matches.NewService(database, games.NewRegistry(), clock.Real{})
	if err != nil {
		writeLine(stderr, matchFailed)
		return exitFailure
	}
	snapshot, err := service.Snapshot(ctx, options.id)
	if errors.Is(err, matches.ErrMatchNotFound) {
		writeLine(stderr, matchMissing)
		return exitFailure
	}
	if err != nil {
		writeLine(stderr, matchFailed)
		return exitFailure
	}
	if len(snapshot.Players) != 2 {
		writeLine(stderr, matchFailed)
		return exitFailure
	}
	board := make([]int, 0)
	var boardSize int
	var nextColor string
	var format string
	var round int
	var scores map[string]int
	var phase string
	var dice int
	var pieces map[string][]flightchess.Piece
	switch snapshot.Match.GameID {
	case chinesecheckers.GameID:
		var state chineseCheckersStateView
		if err := json.Unmarshal(snapshot.Game.State, &state); err != nil || state.NextColor != "black" && state.NextColor != "white" {
			writeLine(stderr, matchFailed)
			return exitFailure
		}
		blackCount, whiteCount := 0, 0
		for _, cell := range state.Board {
			switch chinesecheckers.Color(cell) {
			case chinesecheckers.Black:
				blackCount++
			case chinesecheckers.White:
				whiteCount++
			case chinesecheckers.Empty:
			default:
				writeLine(stderr, matchFailed)
				return exitFailure
			}
		}
		if blackCount != 10 || whiteCount != 10 {
			writeLine(stderr, matchFailed)
			return exitFailure
		}
		board = make([]int, 0, chinesecheckers.BoardCells)
		for _, cell := range state.Board {
			board = append(board, int(cell))
		}
		boardSize = chinesecheckers.BoardCells
		nextColor = state.NextColor
	case flightchess.GameID:
		var state flightChessStateView
		if err := json.Unmarshal(snapshot.Game.State, &state); err != nil ||
			state.Phase != flightchess.PhaseAwaitingRoll && state.Phase != flightchess.PhaseAwaitingMove ||
			state.NextColor != flightchess.Black && state.NextColor != flightchess.White ||
			len(state.Pieces) != 2 || len(state.Pieces[flightchess.Black]) != flightchess.PieceCount ||
			len(state.Pieces[flightchess.White]) != flightchess.PieceCount {
			writeLine(stderr, matchFailed)
			return exitFailure
		}
		phase, nextColor, dice = state.Phase, state.NextColor, state.Dice
		pieces = map[string][]flightchess.Piece{
			flightchess.Black: append([]flightchess.Piece(nil), state.Pieces[flightchess.Black]...),
			flightchess.White: append([]flightchess.Piece(nil), state.Pieces[flightchess.White]...),
		}
	case gomoku.GameID:
		var state gomokuStateView
		if err := json.Unmarshal(snapshot.Game.State, &state); err != nil || state.BoardSize != gomoku.BoardSize {
			writeLine(stderr, matchFailed)
			return exitFailure
		}
		for _, cell := range state.Board {
			if cell > uint8(gomoku.White) {
				writeLine(stderr, matchFailed)
				return exitFailure
			}
		}
		board = make([]int, 0, gomoku.BoardSize*gomoku.BoardSize)
		for _, cell := range state.Board {
			board = append(board, int(cell))
		}
		boardSize = state.BoardSize
	case rps.GameID:
		var state rpsStateView
		if err := json.Unmarshal(snapshot.Game.State, &state); err != nil || state.Round < 1 ||
			(state.Format != rps.FormatSingleRound && state.Format != rps.FormatBestOfThree) || state.Scores == nil {
			writeLine(stderr, matchFailed)
			return exitFailure
		}
		for userID, score := range state.Scores {
			if userID == "" || score < 0 || score > 2 {
				writeLine(stderr, matchFailed)
				return exitFailure
			}
		}
		format, round, scores = state.Format, state.Round, state.Scores
	default:
		writeLine(stderr, matchFailed)
		return exitFailure
	}
	players := make([]matchPlayerResponse, len(snapshot.Players))
	for index, player := range snapshot.Players {
		players[index] = matchPlayerResponse{UserID: player.UserID, Seat: player.Seat, Color: player.Color}
	}
	response := matchShowResponse{
		ID: snapshot.Match.ID, GameID: snapshot.Match.GameID, Status: snapshot.Match.Status,
		Revision: snapshot.Match.Revision, Result: cloneString(snapshot.Match.Result),
		WinnerUserID: cloneString(snapshot.Match.WinnerUserID), Players: players,
		BoardSize: boardSize, Board: board, NextColor: nextColor, Format: format, Round: round, Scores: scores,
		Phase: phase, Dice: dice, Pieces: pieces,
	}
	if err := json.NewEncoder(stdout).Encode(response); err != nil {
		writeLine(stderr, matchFailed)
		return exitFailure
	}
	return exitOK
}

func parseMatchOptions(args []string) (matchOptions, bool) {
	values, ok := parseStrictOptions(args, map[string]bool{"--id": true, "--db": true, "--json": false})
	if !ok || values["--json"] != "true" || strings.TrimSpace(values["--db"]) == "" || !canonicalUUID(values["--id"]) {
		return matchOptions{}, false
	}
	return matchOptions{id: values["--id"], db: values["--db"]}, true
}

// parseStrictOptions accepts each declared flag exactly once. Value flags
// support both --name value and --name=value; boolean flags are bare only.
func parseStrictOptions(args []string, definitions map[string]bool) (map[string]string, bool) {
	values := make(map[string]string, len(definitions))
	for index := 0; index < len(args); index++ {
		argument := args[index]
		name, value, hasEquals := argument, "", false
		if split := strings.IndexByte(argument, '='); split >= 0 {
			name, value, hasEquals = argument[:split], argument[split+1:], true
		}
		requiresValue, known := definitions[name]
		if !known {
			return nil, false
		}
		if _, duplicate := values[name]; duplicate {
			return nil, false
		}
		if !requiresValue {
			if hasEquals {
				return nil, false
			}
			values[name] = "true"
			continue
		}
		if !hasEquals {
			index++
			if index >= len(args) {
				return nil, false
			}
			value = args[index]
		}
		if value == "" {
			return nil, false
		}
		values[name] = value
	}
	if len(values) != len(definitions) {
		return nil, false
	}
	return values, true
}

func isHelp(argument string) bool { return argument == "-h" || argument == "--help" }

func canonicalUUID(value string) bool {
	parsed, err := uuid.Parse(value)
	return err == nil && parsed.String() == value && parsed.Variant() == uuid.RFC4122
}

func cloneString(value *string) *string {
	if value == nil {
		return nil
	}
	copy := *value
	return &copy
}

func writeLine(destination io.Writer, line string) {
	_, _ = fmt.Fprintln(destination, line)
}
