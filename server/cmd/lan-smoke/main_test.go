package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"me.zqydev/gamebox/server/internal/lan/httpapi"
	"me.zqydev/gamebox/server/internal/lan/room"
)

const (
	smokeRoomID      = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	smokeHostID      = "11111111-1111-4111-8111-111111111111"
	smokeAttemptID   = "33333333-3333-4333-8333-333333333333"
	smokeRoomKey     = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	smokeHostResume  = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA"
	smokeGuestResume = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA"
)

func TestRunJoinsAndConsumesPairedTicketBeforeRevisionZeroSnapshot(t *testing.T) {
	service, err := room.Open(room.Config{Root: t.TempDir(), TokenPepper: strings.Repeat("p", 32)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = service.Close() })
	_, err = service.Create(context.Background(), room.CreateRequest{
		RoomID: smokeRoomID, HostPlayerID: smokeHostID, HostNickname: "Host",
		RoomKey: smokeRoomKey, TokenPepper: strings.Repeat("p", 32),
		HostResumeToken: smokeHostResume, JoinExpiresAt: time.Now().Add(time.Minute).UnixMilli(),
	})
	if err != nil {
		t.Fatal(err)
	}
	router, err := httpapi.NewRouter(service)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = router.Close(context.Background()) })
	server := httptest.NewServer(router)
	t.Cleanup(server.Close)

	input := smokeInput{
		RoomID: smokeRoomID, Nickname: "Guest", JoinAttemptID: smokeAttemptID,
		CandidateResumeToken: smokeGuestResume, RoomKey: smokeRoomKey,
	}
	encoded, _ := json.Marshal(input)
	var output bytes.Buffer
	if err := run(context.Background(), []string{"--endpoint", strings.TrimPrefix(server.URL, "http://")}, bytes.NewReader(encoded), &output); err != nil {
		t.Fatal(err)
	}
	if got, want := strings.TrimSpace(output.String()), `{"schemaVersion":1,"roomId":"`+smokeRoomID+`","revision":0,"state":"active"}`; got != want {
		t.Fatalf("output = %q, want %q", got, want)
	}
}

func TestRunRejectsNonExactInputAndNeverFormatsCredentials(t *testing.T) {
	for name, input := range map[string]string{
		"extra":    `{"roomId":"` + smokeRoomID + `","nickname":"Guest","joinAttemptId":"` + smokeAttemptID + `","candidateResumeToken":"` + smokeGuestResume + `","roomKey":"` + smokeRoomKey + `","extra":true}`,
		"trailing": `{"roomId":"` + smokeRoomID + `","nickname":"Guest","joinAttemptId":"` + smokeAttemptID + `","candidateResumeToken":"` + smokeGuestResume + `","roomKey":"` + smokeRoomKey + `"}{}`,
	} {
		t.Run(name, func(t *testing.T) {
			var output bytes.Buffer
			err := run(context.Background(), []string{"--endpoint", "127.0.0.1:1"}, strings.NewReader(input), &output)
			if err == nil {
				t.Fatal("run() error = nil")
			}
			combined := err.Error() + output.String()
			for _, secret := range []string{smokeRoomKey, smokeGuestResume} {
				if strings.Contains(combined, secret) {
					t.Fatal("credential was formatted")
				}
			}
		})
	}
}

func TestRunRejectsRedirectWithoutFollowingOrLeakingCredentials(t *testing.T) {
	server := httptest.NewServer(httpRedirectHandler{})
	defer server.Close()
	input := smokeInput{
		RoomID: smokeRoomID, Nickname: "Guest", JoinAttemptID: smokeAttemptID,
		CandidateResumeToken: smokeGuestResume, RoomKey: smokeRoomKey,
	}
	encoded, _ := json.Marshal(input)
	var output bytes.Buffer
	err := run(context.Background(), []string{"--endpoint", strings.TrimPrefix(server.URL, "http://")}, bytes.NewReader(encoded), &output)
	if err == nil || strings.Contains(err.Error()+output.String(), smokeGuestResume) || strings.Contains(err.Error()+output.String(), smokeRoomKey) {
		t.Fatal("redirect was accepted or credential leaked")
	}
}

type httpRedirectHandler struct{}

func (httpRedirectHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	writer.Header().Set("Location", "/credential-marker")
	writer.WriteHeader(307)
}
