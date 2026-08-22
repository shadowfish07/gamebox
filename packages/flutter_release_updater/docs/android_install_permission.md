# Android APK installation permission findings

Verified on 2026-08-22 for an ordinary Android application targeting current
Android versions.

| Candidate | Smaller app permission? | Equivalent to self-hosted APK install? | Finding |
| --- | --- | --- | --- |
| `ACTION_VIEW` / `ACTION_INSTALL_PACKAGE` | No | Yes | For targets above API 25, the requesting app must declare `REQUEST_INSTALL_PACKAGES`. |
| `PackageInstaller.Session` | No | Yes | It changes the API, but ordinary installers still require `REQUEST_INSTALL_PACKAGES` and normally require user action. |
| Xiaomi GetApps update SDK / `market://details` | Yes | No | The store owns download and installation; the app must be listed/configured for Xiaomi's service. |
| Google Play in-app updates | Yes | No | Google Play owns the update and the app must be Play-distributed. |
| Device/profile owner installation | Special management authority | No | Only managed-device scenarios qualify; this is not an option for a normal consumer app. |

The Android framework's package installer checks the requesting source through
the app-op derived from `REQUEST_INSTALL_PACKAGES` and opens that source app's
"install unknown apps" setting when access is missing. Therefore changing only
the installer API cannot downgrade this to a normal permission on HyperOS or
stock Android.

Primary references:

- Android `ACTION_INSTALL_PACKAGE` API contract:
  <https://developer.android.com/reference/android/content/Intent#ACTION_INSTALL_PACKAGE>
- Android `PackageManager.canRequestPackageInstalls()` contract:
  <https://developer.android.com/reference/android/content/pm/PackageManager#canRequestPackageInstalls()>
- Android `PackageInstaller.SessionParams.setRequireUserAction()` contract:
  <https://developer.android.com/reference/android/content/pm/PackageInstaller.SessionParams#setRequireUserAction(int)>
- AOSP `PackageInstallerActivity` source permission/app-op check:
  <https://android.googlesource.com/platform/frameworks/base/+/master/packages/PackageInstaller/src/com/android/packageinstaller/PackageInstallerActivity.java>
- Xiaomi app review FAQ identifying `REQUEST_INSTALL_PACKAGES` as app
  distribution access:
  <https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1482>
- Xiaomi Update SDK and store-detail update handoff:
  <https://dev.mi.com/xiaomihyperos/documentation/detail?pId=1315>
  and <https://dev.mi.com/xiaomihyperos/documentation/detail?pId=2006>
- Google Play in-app updates:
  <https://developer.android.com/guide/playcore/in-app-updates>

Open-source options reviewed did not replace this package's exact boundary:
`upgrader` is a prompt/store handoff, `in_app_update` is Google Play-only,
Shorebird updates Dart code rather than arbitrary native APK contents, and
direct APK installer packages still declare `REQUEST_INSTALL_PACKAGES`.
