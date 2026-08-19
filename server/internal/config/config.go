// Package config loads the server's process configuration.
package config

import (
	"errors"
	"fmt"
	"os"
)

const (
	defaultAddr            = "127.0.0.1:8080"
	defaultDBPath          = "server/data/gamebox.db"
	minimumSecretByteCount = 32
)

// ErrInvalidConfiguration is deliberately fixed so configuration errors never
// echo secret environment values.
var ErrInvalidConfiguration = errors.New("invalid configuration")

// Config is the typed server configuration shared by composition roots. Secret
// fields remain values rather than process-global lookups so services and tests
// receive their dependencies explicitly.
type Config struct {
	Addr        string
	DBPath      string
	JWTSecret   string
	TokenPepper string
}

// String exposes only non-secret routing fields. It intentionally redacts both
// authentication values for logging and diagnostic formatting.
func (config Config) String() string {
	return fmt.Sprintf("Config{Addr:%q DBPath:%q JWTSecret:<redacted> TokenPepper:<redacted>}", config.Addr, config.DBPath)
}

// GoString keeps %#v redacted as well.
func (config Config) GoString() string {
	return config.String()
}

// Load reads the supported GAMEBOX_* environment variables.
func Load() (Config, error) {
	return loadFromLookup(os.LookupEnv)
}

func loadFromLookup(lookup func(string) (string, bool)) (Config, error) {
	if lookup == nil {
		return Config{}, ErrInvalidConfiguration
	}
	jwtSecret, jwtPresent := lookup("GAMEBOX_JWT_SECRET")
	tokenPepper, pepperPresent := lookup("GAMEBOX_TOKEN_PEPPER")
	if !jwtPresent || !pepperPresent || len([]byte(jwtSecret)) < minimumSecretByteCount || len([]byte(tokenPepper)) < minimumSecretByteCount {
		return Config{}, ErrInvalidConfiguration
	}
	addr := defaultAddr
	if value, present := lookup("GAMEBOX_ADDR"); present && value != "" {
		addr = value
	}
	dbPath := defaultDBPath
	if value, present := lookup("GAMEBOX_DB_PATH"); present && value != "" {
		dbPath = value
	}
	return Config{
		Addr:        addr,
		DBPath:      dbPath,
		JWTSecret:   jwtSecret,
		TokenPepper: tokenPepper,
	}, nil
}
