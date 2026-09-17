package main

import (
	"context"
	"encoding/json"
	"flag"
	"github.com/google/uuid"
	"io"
	"me.zqydev/gamebox/server/internal/auth"
	"me.zqydev/gamebox/server/internal/clock"
	"me.zqydev/gamebox/server/internal/store"
)

func runRecoveryCreate(ctx context.Context, args []string, out, errOut io.Writer, deps commandDeps) int {
	flags := flag.NewFlagSet("recovery create", flag.ContinueOnError)
	flags.SetOutput(errOut)
	id := flags.String("user-id", "", "account UUID")
	path := flags.String("db", "", "database path")
	asJSON := flags.Bool("json", false, "JSON output")
	if flags.Parse(args) != nil || flags.NArg() != 0 || *path == "" || !*asJSON {
		writeLine(errOut, "usage: gameboxctl recovery create --user-id UUID --db PATH --json")
		return exitUsage
	}
	if parsed, err := uuid.Parse(*id); err != nil || parsed.String() != *id {
		return exitUsage
	}
	pepper, _ := deps.lookupEnv("GAMEBOX_TOKEN_PEPPER")
	secret, _ := deps.lookupEnv("GAMEBOX_JWT_SECRET")
	if len(pepper) < 32 || len(secret) < 32 {
		writeLine(errOut, "error: recovery creation failed")
		return exitFailure
	}
	db, err := store.Open(ctx, *path)
	if err != nil {
		writeLine(errOut, "error: recovery creation failed")
		return exitFailure
	}
	defer db.Close()
	service, err := auth.NewService(db, clock.NewFake(deps.now()), auth.ServiceConfig{TokenPepper: pepper, JWTSecret: []byte(secret)})
	if err != nil {
		writeLine(errOut, "error: recovery creation failed")
		return exitFailure
	}
	code, err := service.CreateRecovery(ctx, *id)
	if err != nil {
		writeLine(errOut, "error: recovery creation failed")
		return exitFailure
	}
	if json.NewEncoder(out).Encode(code) != nil {
		return exitFailure
	}
	return exitOK
}
