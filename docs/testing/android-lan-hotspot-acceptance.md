# Android offline LAN hotspot acceptance

Use this checklist only after `tool/verify.sh`, `tool/e2e_android.sh`, and
`tool/e2e_lan_android.sh` pass. Both phones must install the exact same APK.
Retain evidence under ignored `artifacts/e2e-lan-android/`; never paste a QR
payload, room key, launch/resume token, public token, or private database into
the record.

## Candidate identity

- [ ] Record UTC time, commit, version name/code, APK SHA-256 and signature.
- [ ] Record both device models, Android versions and supported APK ABIs.
- [ ] Confirm the public origin is the configured HTTPS/WSS origin and only
      private RFC1918 IPv4 LAN endpoints may use cleartext HTTP/WS.

## Offline playable loop

- [ ] Enable the host phone's system hotspot and join it from the guest.
- [ ] Disable mobile data and otherwise remove public reachability on both.
- [ ] Set distinct local nicknames without public registration.
- [ ] Create a room on the host and scan its real QR using the guest camera.
- [ ] Record assigned colors and assert both boards/revisions are equal.
- [ ] Interrupt the guest network, restore it, and assert resume reaches the
      same room, board and revision without an implicit action or resignation.
- [ ] Exit and relaunch host Godot while the host service remains alive.
- [ ] Force-stop the host app, reopen it, choose continue, and assert the same
      room/journal is restored. Rescan a credential-free recovery QR only if
      the endpoint changed.
- [ ] Finish one game and record equal SHA-256 hashes for both canonical result
      files. Assert the event streams and final revisions are identical.
- [ ] Open both history pages and confirm the same neutral card/record layout;
      there must be no public/LAN source badge or divergent result semantics.
- [ ] Restore public connectivity and confirm any pre-existing public session
      remains signed in.
- [ ] Induce nickname-sync and update-check failures; LAN and history must stay
      usable and must not delete public credentials.

## Recovery and failure semantics

- [ ] A waiting or active room does not auto-expire, migrate hosts, silently
      repair a corrupt journal, or infer resignation from disconnect/force-stop.
- [ ] Expired join QR, wrong key, duplicate/unknown QR fields, public addresses,
      redirects and oversized responses fail closed with safe UI copy.
- [ ] A host endpoint change requires explicit recovery data; a resume QR
      contains no credential.
- [ ] A terminal room is not cleaned up until the host result is durably written
      and acknowledged. Normal cleanup also waits for the guest acknowledgement;
      the explicit missing-guest override remains a separate user decision.
- [ ] Neither LAN credential nor result data is uploaded to the public service.

## Required screenshots

- [ ] Local nickname/home and public-vs-LAN choice.
- [ ] Host waiting state with the QR region masked in the retained image.
- [ ] Both joined boards, recovered guest, recovered host and terminal outcome.
- [ ] Both source-neutral history pages.

Run a recursive credential scanner before retaining artifacts. The evidence may
contain room IDs, revisions and SHA-256 hashes; it must reject QR query secrets,
43-character base64url credentials, and the names `launchTicket`, `resumeToken`,
`roomKey`, `accessToken`, or `refreshToken`.
