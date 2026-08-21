import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android application explicitly disables credential backup', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      RegExp(
        r'<application\b[^>]*android:allowBackup="false"',
        dotAll: true,
      ).hasMatch(manifest),
      isTrue,
    );
  });

  test(
    'Android application declares its constrained APK installer surface',
    () {
      final manifest = File(
        'android/app/src/main/AndroidManifest.xml',
      ).readAsStringSync();
      expect(manifest, contains('android.permission.REQUEST_INSTALL_PACKAGES'));
      expect(manifest, contains('androidx.core.content.FileProvider'));
      expect(manifest, contains(r'${applicationId}.fileprovider'));
      expect(manifest, contains('@xml/godot_provider_paths'));
    },
  );

  test('Android release keeps the Godot JNI bridge names intact', () {
    final buildScript = File('android/app/build.gradle.kts').readAsStringSync();
    final proguardRules = File(
      'android/app/proguard-rules.pro',
    ).readAsStringSync();

    expect(buildScript, contains('"proguard-rules.pro"'));
    expect(
      proguardRules,
      contains('-keep class org.godotengine.godot.** { *; }'),
    );
  });
}
