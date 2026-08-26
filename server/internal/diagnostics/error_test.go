package diagnostics

import (
	"errors"
	"testing"
)

func TestWrapPreservesPublicErrorAndDiagnosticCause(t *testing.T) {
	public := errors.New("internal_error")
	cause := errors.New("sqlite: database is locked")
	wrapped := Wrap(public, cause)

	if !errors.Is(wrapped, public) || wrapped.Error() != public.Error() || Cause(wrapped) != cause {
		t.Fatalf("wrapped error = (%q, public=%t, cause=%v)", wrapped, errors.Is(wrapped, public), Cause(wrapped))
	}
}
