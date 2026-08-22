package lanengine

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
)

func TestEngineRejectsBlankRoot(t *testing.T) {
	for _, root := range []string{"", " \t\n "} {
		if _, err := NewEngine(root); !errors.Is(err, ErrInvalidConfiguration) {
			t.Fatalf("NewEngine(%q) error = %v", root, err)
		}
	}
}

func TestNormalizeNicknameUsesSharedMobileSafeRules(t *testing.T) {
	if got := NormalizeNickname("\u2003Alice 中\u2003"); got != `{"display":"Alice 中","normalized":"alice 中","valid":true}` {
		t.Fatalf("NormalizeNickname valid = %q", got)
	}
	if got := NormalizeNickname("A\u202eB"); got != `{"display":"","normalized":"","valid":false}` {
		t.Fatalf("NormalizeNickname invalid = %q", got)
	}
}

func TestEngineHasStableEmptyStatusAndPendingErrors(t *testing.T) {
	engine, err := NewEngine("/tmp/gamebox-lanengine")
	if err != nil {
		t.Fatalf("NewEngine valid root: %v", err)
	}
	if got := engine.Status(); got != `{"schemaVersion":1,"state":"empty"}` {
		t.Fatalf("Status() = %q", got)
	}

	result, err := engine.Start(`{}`)
	assertNotReady(t, "Start", result, err)
	result, err = engine.CreateRoom(`{}`)
	assertNotReady(t, "CreateRoom", result, err)
	result, err = engine.IssueHostLaunch()
	assertNotReady(t, "IssueHostLaunch", result, err)
	assertStopNotReady(t, engine.Stop())
}

func assertNotReady(t *testing.T, method string, result string, err error) {
	t.Helper()
	if result != "" || err == nil || err.Error() != "not_ready" {
		t.Fatalf("%s() = (%q, %v), want (empty, not_ready)", method, result, err)
	}
}

func assertStopNotReady(t *testing.T, err error) {
	t.Helper()
	if err == nil || err.Error() != "not_ready" {
		t.Fatalf("Stop() error = %v, want not_ready", err)
	}
}

func TestBoundPackageHasNoForbiddenImports(t *testing.T) {
	forbidden := []string{"modernc.org/sqlite", "/internal/auth", "/internal/users", "/internal/matches"}
	output := goListDeps(t, "me.zqydev/gamebox/server/mobile/lanengine")
	for _, fragment := range forbidden {
		if strings.Contains(output, fragment) {
			t.Fatalf("mobile dependency closure contains %q", fragment)
		}
	}
}

func goListDeps(t *testing.T, packagePath string) string {
	t.Helper()
	command := exec.Command("go", "list", "-deps", packagePath)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("go list -deps %s: %v\n%s", packagePath, err, output)
	}
	return string(output)
}
