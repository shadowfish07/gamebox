# flutter_release_updater

Reusable Android self-update plumbing for Flutter applications distributed as
APK files on GitHub Releases. The package is UI-independent and provides:

- semantic-version checks against `releases/latest`, with a configurable cache;
- APK selection plus a required SHA-256 from GitHub's asset digest or
  `checksums.txt`;
- streaming download into application-private storage;
- package name, version code, and signing-certificate checks on Android;
- handoff to Android's system package installer and explicit handling of the
  per-app "install unknown apps" setting.

## Android permission boundary

The plugin manifest declares `android.permission.REQUEST_INSTALL_PACKAGES`.
Android requires this special access when an ordinary app asks to install an
APK that it downloaded. Switching from `ACTION_VIEW` to `PackageInstaller`
does not remove that requirement. The plugin does not request the privileged
`INSTALL_PACKAGES` permission and cannot install silently.

If an application must avoid this permission, use a trusted-store update API
instead; that changes the workflow because the store owns download and install.
The evaluated alternatives and primary Android/Xiaomi references are recorded
in [`docs/android_install_permission.md`](docs/android_install_permission.md).

## Use from this repository

```yaml
dependencies:
  flutter_release_updater:
    path: ../packages/flutter_release_updater
```

After the package is available on a shared Git branch, another project such as
NextPlay can use the same source directly:

```yaml
dependencies:
  flutter_release_updater:
    git:
      url: https://github.com/shadowfish07/gamebox.git
      path: packages/flutter_release_updater
      ref: <commit-or-tag>
```

Create and start the controller once near application startup:

```dart
final updates = await UpdateController.production(
  repository: 'shadowfish07/NextPlay',
  userAgent: 'NextPlay-update-check',
  cacheKeyPrefix: 'nextplay.update',
  // Optional for repositories containing more than one APK:
  apkAssetMatcher: (name) => name.endsWith('-android.apk'),
);
await updates.start();
```

Observe `UpdateController` as a `ChangeNotifier`. Show
`availableUpdate`, `status`, `downloadProgress`, and `errorMessage` in the host
application's own UI. Call `checkNow()` for an explicit check and
`downloadAndInstall()` after user confirmation. If status becomes
`permissionRequired`, Android has opened the app-specific system setting; call
`downloadAndInstall()` again after the user returns.

For tests, construct `UpdateController` directly and inject a `ReleaseService`,
`ApkInstaller`, HTTP client, preferences, and private update directory.

To exercise the real GitHub boundary without downloading an APK:

```bash
dart run tool/live_github_smoke.dart shadowfish07/gamebox 0.0.0
```

This repository currently has no license file, so the package intentionally
uses `publish_to: none` and is not ready for pub.dev publication.
