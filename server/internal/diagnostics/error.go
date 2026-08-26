// Package diagnostics preserves private causes for server-side logs while
// retaining stable public errors for callers and API responses.
package diagnostics

import "errors"

// Error carries a stable public error plus the underlying diagnostic cause.
// Its text deliberately remains the public error so callers do not
// accidentally disclose implementation details.
type Error struct {
	public error
	cause  error
}

func (err *Error) Error() string { return err.public.Error() }

func (err *Error) Unwrap() error { return err.public }

// Cause returns the underlying error for trusted diagnostic logging.
func (err *Error) Cause() error { return err.cause }

// Wrap associates cause with public while preserving errors.Is(public).
func Wrap(public, cause error) error {
	if public == nil || cause == nil {
		return public
	}
	return &Error{public: public, cause: cause}
}

// Cause returns the diagnostic cause attached to err, if any.
func Cause(err error) error {
	var diagnostic *Error
	if errors.As(err, &diagnostic) && diagnostic.cause != nil {
		return diagnostic.cause
	}
	return err
}
