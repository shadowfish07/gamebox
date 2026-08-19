package auth

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"
	"testing"

	"me.zqydev/gamebox/server/internal/clock"
)

const malformedJWTMarker = "malformed-jwt-private-marker"

func signRawJWTClaims(payload, secret string) string {
	return signRawJWTDocuments([]byte(`{"alg":"HS256","typ":"JWT"}`), []byte(payload), secret)
}

func signRawJWTDocuments(header, payload []byte, secret string) string {
	headerSegment := base64.RawURLEncoding.EncodeToString(header)
	claims := base64.RawURLEncoding.EncodeToString(payload)
	signingInput := headerSegment + "." + claims
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signingInput))
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func canonicalClaimsJSON(now int64, extra string) string {
	return fmt.Sprintf(`{"iss":"gamebox","sub":"access-user","iat":%d,"exp":%d%s}`, now, now+900, extra)
}

func nestedJSONObject(depth int) string {
	value := `{}`
	for level := 1; level < depth; level++ {
		value = `{"nested":` + value + `}`
	}
	return value
}

func assertFixedUnauthorizedWithoutJWTDisclosure(t *testing.T, service *Service, raw string) {
	t.Helper()
	identity, err := service.ParseAccess(raw)
	errorText := ""
	if err != nil {
		errorText = err.Error()
	}
	zeroIdentity := identity == (AccessIdentity{})
	unauthorized := errors.Is(err, ErrUnauthorized)
	fixedText := errorText == ErrUnauthorized.Error()
	redacted := !strings.Contains(errorText, malformedJWTMarker) &&
		!strings.Contains(strings.ToLower(errorText), "jwt") &&
		!strings.Contains(strings.ToLower(errorText), "token") &&
		!strings.Contains(errorText, raw)
	if !zeroIdentity || !unauthorized || !fixedText || !redacted {
		t.Fatalf("ParseAccess rejection contract: zeroIdentity=%t unauthorized=%t fixedText=%t redacted=%t", zeroIdentity, unauthorized, fixedText, redacted)
	}
}

func TestParseAccessMalformedCorpusIsFixedAndSecretFree(t *testing.T) {
	fixture := newAuthFixture(t)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	now := fixture.now.UTC().Unix()
	validClaims := fmt.Sprintf(`{"iss":"gamebox","sub":"access-user","iat":%d,"exp":%d,"marker":"%s"}`, now, now+900, malformedJWTMarker)

	tests := []struct {
		name string
		raw  string
	}{
		{name: "incorrect signature", raw: signRawJWTClaims(validClaims, strings.Repeat("w", 32))},
		{name: "missing exp", raw: signRawJWTClaims(fmt.Sprintf(`{"iss":"gamebox","sub":"access-user","iat":%d,"marker":"%s"}`, now, malformedJWTMarker), testJWTSecret)},
		{name: "two segments", raw: "header." + malformedJWTMarker},
		{name: "four segments", raw: "one.two.three." + malformedJWTMarker},
		{name: "bad header base64", raw: "*.e30.signature-" + malformedJWTMarker},
		{name: "bad claims base64", raw: "e30.*.signature-" + malformedJWTMarker},
		{name: "bad claims JSON", raw: signRawJWTClaims(`{"iss":`, testJWTSecret)},
		{name: "subject wrong type", raw: signRawJWTClaims(fmt.Sprintf(`{"iss":"gamebox","sub":7,"iat":%d,"exp":%d,"marker":"%s"}`, now, now+900, malformedJWTMarker), testJWTSecret)},
		{name: "issued at wrong type", raw: signRawJWTClaims(fmt.Sprintf(`{"iss":"gamebox","sub":"access-user","iat":{},"exp":%d,"marker":"%s"}`, now+900, malformedJWTMarker), testJWTSecret)},
		{name: "expiry wrong type", raw: signRawJWTClaims(fmt.Sprintf(`{"iss":"gamebox","sub":"access-user","iat":%d,"exp":"later","marker":"%s"}`, now, malformedJWTMarker), testJWTSecret)},
		{name: "empty claims", raw: signRawJWTClaims(`{}`, testJWTSecret)},
		{name: "oversize", raw: strings.Repeat(malformedJWTMarker, maximumAccessTokenTextBytes)},
		{name: "duplicate subject", raw: signRawJWTClaims(fmt.Sprintf(`{"iss":"gamebox","sub":"%s","sub":"access-user","iat":%d,"exp":%d}`, malformedJWTMarker, now, now+900), testJWTSecret)},
		{name: "duplicate issued at", raw: signRawJWTClaims(fmt.Sprintf(`{"iss":"gamebox","sub":"access-user","iat":0,"iat":%d,"exp":%d,"marker":"%s"}`, now, now+900, malformedJWTMarker), testJWTSecret)},
		{name: "duplicate expiry", raw: signRawJWTClaims(fmt.Sprintf(`{"iss":"gamebox","sub":"access-user","iat":%d,"exp":0,"exp":%d,"marker":"%s"}`, now, now+900, malformedJWTMarker), testJWTSecret)},
	}

	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			assertFixedUnauthorizedWithoutJWTDisclosure(t, service, test.raw)
		})
	}

	insertSessionUser(t, fixture, "access-user", "Alice", true)
	issued, err := service.Issue(context.Background(), "access-user")
	if err != nil {
		t.Fatalf("Issue valid access credential: %v", err)
	}
	identity, err := service.ParseAccess(issued.AccessToken)
	if err != nil || identity.UserID != "access-user" {
		t.Fatalf("valid HS256 path: authenticated=%t fixedUser=%t", err == nil, identity.UserID == "access-user")
	}
}

func TestSessionAndServiceConfigFormattingRedactsSecretsForAllFmtVerbs(t *testing.T) {
	accessMarker := "access-private-format-marker"
	refreshMarker := "refresh-private-format-marker"
	jwtMarker := "jwt-private-format-marker"
	pepperMarker := "pepper-private-format-marker"
	session := Session{AccessToken: accessMarker, RefreshToken: refreshMarker}
	config := ServiceConfig{JWTSecret: []byte(jwtMarker), TokenPepper: pepperMarker}
	service := Service{jwtSecret: []byte(jwtMarker), pepper: pepperMarker}

	for _, value := range []any{session, &session, config, &config, service, &service} {
		for _, format := range []string{"%v", "%+v", "%#v"} {
			formatted := fmt.Sprintf(format, value)
			if strings.Contains(formatted, accessMarker) || strings.Contains(formatted, refreshMarker) || strings.Contains(formatted, jwtMarker) || strings.Contains(formatted, pepperMarker) {
				t.Fatalf("secret-safe formatting failed: valueType=%T format=%s", value, format)
			}
		}
	}
}

func TestParseAccessRejectsRegisteredClaimAndHeaderCaseFoldConfusion(t *testing.T) {
	fixture := newAuthFixture(t)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	now := fixture.now.UTC().Unix()
	tests := []struct {
		name string
		raw  string
	}{
		{name: "subject uppercase", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"SUB":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "issuer uppercase", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"ISS":"gamebox","marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "issued at uppercase", raw: signRawJWTClaims(canonicalClaimsJSON(now, fmt.Sprintf(`,"IAT":%d,"marker":"%s"`, now, malformedJWTMarker)), testJWTSecret)},
		{name: "expiry uppercase", raw: signRawJWTClaims(canonicalClaimsJSON(now, fmt.Sprintf(`,"EXP":%d,"marker":"%s"`, now+900, malformedJWTMarker)), testJWTSecret)},
		{name: "audience uppercase", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"AUD":"gamebox","marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "not before uppercase", raw: signRawJWTClaims(canonicalClaimsJSON(now, fmt.Sprintf(`,"NBF":%d,"marker":"%s"`, now, malformedJWTMarker)), testJWTSecret)},
		{name: "JWT ID uppercase", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"JTI":"one","marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "escaped uppercase subject", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"\u0053UB":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "Unicode fold subject", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"\u017Fub":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "header algorithm uppercase companion", raw: signRawJWTDocuments([]byte(`{"alg":"HS256","ALG":"HS256","typ":"JWT"}`), []byte(canonicalClaimsJSON(now, `,"marker":"`+malformedJWTMarker+`"`)), testJWTSecret)},
		{name: "header type uppercase companion", raw: signRawJWTDocuments([]byte(`{"alg":"HS256","typ":"JWT","TYP":"JWT"}`), []byte(canonicalClaimsJSON(now, `,"marker":"`+malformedJWTMarker+`"`)), testJWTSecret)},
		{name: "header key id uppercase companion", raw: signRawJWTDocuments([]byte(`{"alg":"HS256","typ":"JWT","kid":"one","KID":"two"}`), []byte(canonicalClaimsJSON(now, `,"marker":"`+malformedJWTMarker+`"`)), testJWTSecret)},
		{name: "escaped uppercase header algorithm", raw: signRawJWTDocuments([]byte(`{"alg":"HS256","\u0041LG":"HS256","typ":"JWT"}`), []byte(canonicalClaimsJSON(now, `,"marker":"`+malformedJWTMarker+`"`)), testJWTSecret)},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			assertFixedUnauthorizedWithoutJWTDisclosure(t, service, test.raw)
		})
	}
}

func TestParseAccessRequiresStrictUnicodeAndPairedSurrogates(t *testing.T) {
	fixture := newAuthFixture(t)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	now := fixture.now.UTC().Unix()
	validPayload := []byte(canonicalClaimsJSON(now, `,"marker":"`+malformedJWTMarker+`"`))
	invalidUTF8Payload := append([]byte(canonicalClaimsJSON(now, `,"custom":"`)), 0xff)
	invalidUTF8Payload = append(invalidUTF8Payload, []byte(`"}`)...)
	invalidUTF8Header := append([]byte(`{"alg":"HS256","typ":"JWT","custom":"`), 0xff)
	invalidUTF8Header = append(invalidUTF8Header, []byte(`"}`)...)
	tests := []struct {
		name string
		raw  string
	}{
		{name: "invalid UTF-8 claims", raw: signRawJWTDocuments([]byte(`{"alg":"HS256","typ":"JWT"}`), invalidUTF8Payload, testJWTSecret)},
		{name: "invalid UTF-8 header", raw: signRawJWTDocuments(invalidUTF8Header, validPayload, testJWTSecret)},
		{name: "unpaired high surrogate value", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"custom":"\uD800","marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "unpaired low surrogate value", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"custom":"\uDC00","marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "unpaired high surrogate key", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"\uD800":"custom","marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "unpaired low surrogate key", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"\uDC00":"custom","marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			assertFixedUnauthorizedWithoutJWTDisclosure(t, service, test.raw)
		})
	}

	paired := signRawJWTClaims(canonicalClaimsJSON(now, `,"custom":"\uD83D\uDE00"`), testJWTSecret)
	identity, err := service.ParseAccess(paired)
	if err != nil || identity.UserID != "access-user" {
		t.Fatalf("paired surrogate path: authenticated=%t expectedUser=%t", err == nil, identity.UserID == "access-user")
	}
	escapedLiteral := signRawJWTClaims(canonicalClaimsJSON(now, `,"custom":"\\uD800"`), testJWTSecret)
	identity, err = service.ParseAccess(escapedLiteral)
	if err != nil || identity.UserID != "access-user" {
		t.Fatalf("escaped surrogate text path: authenticated=%t expectedUser=%t", err == nil, identity.UserID == "access-user")
	}
}

func TestParseAccessRequiresTopLevelObjectsUniqueHeadersAndBoundedDepth(t *testing.T) {
	fixture := newAuthFixture(t)
	service := newSessionService(t, fixture, clock.NewFake(fixture.now))
	now := fixture.now.UTC().Unix()
	header := []byte(`{"alg":"HS256","typ":"JWT"}`)
	validPayload := []byte(canonicalClaimsJSON(now, `,"marker":"`+malformedJWTMarker+`"`))
	tests := []struct {
		name string
		raw  string
	}{
		{name: "claims top-level array", raw: signRawJWTDocuments(header, []byte(`[]`), testJWTSecret)},
		{name: "claims top-level string", raw: signRawJWTDocuments(header, []byte(`"`+malformedJWTMarker+`"`), testJWTSecret)},
		{name: "header top-level array", raw: signRawJWTDocuments([]byte(`[]`), validPayload, testJWTSecret)},
		{name: "header top-level string", raw: signRawJWTDocuments([]byte(`"header"`), validPayload, testJWTSecret)},
		{name: "header duplicate algorithm", raw: signRawJWTDocuments([]byte(`{"alg":"HS256","alg":"HS256","typ":"JWT"}`), validPayload, testJWTSecret)},
		{name: "depth 33", raw: signRawJWTClaims(canonicalClaimsJSON(now, `,"custom":`+nestedJSONObject(32)+`,"marker":"`+malformedJWTMarker+`"`), testJWTSecret)},
	}
	for _, test := range tests {
		test := test
		t.Run(test.name, func(t *testing.T) {
			assertFixedUnauthorizedWithoutJWTDisclosure(t, service, test.raw)
		})
	}

	depth32 := signRawJWTClaims(canonicalClaimsJSON(now, `,"custom":`+nestedJSONObject(31)), testJWTSecret)
	identity, err := service.ParseAccess(depth32)
	if err != nil || identity.UserID != "access-user" {
		t.Fatalf("depth 32 boundary: authenticated=%t expectedUser=%t", err == nil, identity.UserID == "access-user")
	}
	exactKnownKeys := signRawJWTDocuments(
		[]byte(`{"alg":"HS256","typ":"JWT","kid":"one"}`),
		[]byte(canonicalClaimsJSON(now, fmt.Sprintf(`,"aud":"gamebox","nbf":%d,"jti":"one"`, now))),
		testJWTSecret,
	)
	identity, err = service.ParseAccess(exactKnownKeys)
	if err != nil || identity.UserID != "access-user" {
		t.Fatalf("canonical optional keys: authenticated=%t expectedUser=%t", err == nil, identity.UserID == "access-user")
	}
}
