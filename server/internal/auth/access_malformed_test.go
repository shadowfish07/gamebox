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
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	claims := base64.RawURLEncoding.EncodeToString([]byte(payload))
	signingInput := header + "." + claims
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signingInput))
	return signingInput + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
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
