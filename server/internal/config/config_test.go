package config

import (
	"errors"
	"strings"
	"testing"
)

func TestLoadFromEnvironmentRequiresLongSecretsAndAppliesDefaults(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		env  map[string]string
		want Config
	}{
		{
			name: "defaults",
			env: map[string]string{
				"GAMEBOX_JWT_SECRET":   strings.Repeat("j", 32),
				"GAMEBOX_TOKEN_PEPPER": strings.Repeat("p", 32),
			},
			want: Config{
				Addr:        "127.0.0.1:8080",
				DBPath:      "server/data/gamebox.db",
				JWTSecret:   strings.Repeat("j", 32),
				TokenPepper: strings.Repeat("p", 32),
			},
		},
		{
			name: "explicit optional values and UTF-8 byte length",
			env: map[string]string{
				"GAMEBOX_ADDR":         "127.0.0.1:9090",
				"GAMEBOX_DB_PATH":      "/private/gamebox.sqlite",
				"GAMEBOX_JWT_SECRET":   strings.Repeat("密", 11),
				"GAMEBOX_TOKEN_PEPPER": strings.Repeat("椒", 11),
			},
			want: Config{
				Addr:        "127.0.0.1:9090",
				DBPath:      "/private/gamebox.sqlite",
				JWTSecret:   strings.Repeat("密", 11),
				TokenPepper: strings.Repeat("椒", 11),
			},
		},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			got, err := loadFromLookup(func(key string) (string, bool) {
				value, ok := test.env[key]
				return value, ok
			})
			if err != nil {
				t.Fatalf("loadFromLookup returned error: %v", err)
			}
			if got != test.want {
				t.Fatalf("config = %+v, want %+v", got, test.want)
			}
		})
	}
}

func TestLoadFromEnvironmentRejectsMissingOrShortSecretsWithoutLeakingThem(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		env  map[string]string
	}{
		{name: "both missing", env: map[string]string{}},
		{name: "JWT missing", env: map[string]string{"GAMEBOX_TOKEN_PEPPER": strings.Repeat("p", 32)}},
		{name: "pepper missing", env: map[string]string{"GAMEBOX_JWT_SECRET": strings.Repeat("j", 32)}},
		{name: "JWT 31 bytes", env: map[string]string{"GAMEBOX_JWT_SECRET": strings.Repeat("secret", 5) + "x", "GAMEBOX_TOKEN_PEPPER": strings.Repeat("p", 32)}},
		{name: "pepper 31 bytes", env: map[string]string{"GAMEBOX_JWT_SECRET": strings.Repeat("j", 32), "GAMEBOX_TOKEN_PEPPER": strings.Repeat("pepper", 5) + "x"}},
		{name: "multibyte still short", env: map[string]string{"GAMEBOX_JWT_SECRET": strings.Repeat("密", 10), "GAMEBOX_TOKEN_PEPPER": strings.Repeat("椒", 11)}},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			t.Parallel()
			config, err := loadFromLookup(func(key string) (string, bool) {
				value, ok := test.env[key]
				return value, ok
			})
			if config != (Config{}) || !errors.Is(err, ErrInvalidConfiguration) || err.Error() != ErrInvalidConfiguration.Error() {
				t.Fatalf("loadFromLookup = (%+v, %v), want zero config and fixed error", config, err)
			}
			for _, value := range test.env {
				if value != "" && strings.Contains(err.Error(), value) {
					t.Fatalf("configuration error leaked secret %q", value)
				}
			}
		})
	}
}

func TestLoadReadsProcessEnvironmentAndTestRestoresIt(t *testing.T) {
	// t.Setenv restores process state automatically. This test is deliberately
	// not parallel; all parallel coverage above injects an immutable lookup.
	t.Setenv("GAMEBOX_ADDR", "127.0.0.1:8181")
	t.Setenv("GAMEBOX_DB_PATH", "/tmp/gamebox-config-test.sqlite")
	t.Setenv("GAMEBOX_JWT_SECRET", strings.Repeat("j", 32))
	t.Setenv("GAMEBOX_TOKEN_PEPPER", strings.Repeat("p", 32))

	got, err := Load()
	if err != nil {
		t.Fatalf("Load returned error: %v", err)
	}
	if got.Addr != "127.0.0.1:8181" || got.DBPath != "/tmp/gamebox-config-test.sqlite" {
		t.Fatalf("Load ignored process environment: %+v", got)
	}
}
