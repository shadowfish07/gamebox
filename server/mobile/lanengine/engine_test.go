package lanengine

import (
	"errors"
	"os/exec"
	"strings"
	"testing"
)

func TestEngineRejectsBlankRoot(t *testing.T) {
	if _, err := NewEngine(""); !errors.Is(err, ErrInvalidConfiguration) {
		t.Fatalf("NewEngine blank root error = %v", err)
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
