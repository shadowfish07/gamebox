import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Android application explicitly disables credential backup', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      RegExp(
        r'<application\b[^>]*android:allowBackup="false"',
        dotAll: true,
      ).hasMatch(manifest),
      isTrue,
    );
  });

  test('Android installer privilege is owned by the reusable plugin', () {
    final appManifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final pluginManifest = File.fromUri(
      _packageRoot('flutter_release_updater')
          .resolve('android/src/main/AndroidManifest.xml'),
    ).readAsStringSync();
    expect(
      appManifest,
      isNot(contains('android.permission.REQUEST_INSTALL_PACKAGES')),
    );
    expect(appManifest, isNot(contains('android.permission.INSTALL_PACKAGES')));
    expect(
      appManifest,
      isNot(contains('application/vnd.android.package-archive')),
    );
    expect(
      pluginManifest,
      contains('android.permission.REQUEST_INSTALL_PACKAGES'),
    );
    expect(
      pluginManifest,
      isNot(contains('android.permission.INSTALL_PACKAGES')),
    );
    expect(pluginManifest, contains('FlutterReleaseUpdaterFileProvider'));
    expect(
      pluginManifest,
      contains(r'${applicationId}.flutter_release_updater.fileprovider'),
    );
    expect(pluginManifest, contains('application/vnd.android.package-archive'));
  });

  test('Android release keeps the Godot JNI bridge names intact', () {
    final buildScript = File('android/app/build.gradle.kts').readAsStringSync();
    final proguardRules = File('android/app/proguard-rules.pro')
        .readAsStringSync();

    expect(buildScript, contains('"proguard-rules.pro"'));
    expect(
      proguardRules,
      contains('-keep class org.godotengine.godot.** { *; }'),
    );
  });

  test('Android game process uses a private disposable task', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final gameActivity = RegExp(
      r'<activity\b(?=[^>]*android:name="\.GameActivity")[^>]*>',
      dotAll: true,
    ).firstMatch(manifest)?.group(0);

    expect(gameActivity, isNotNull);
    expect(gameActivity, contains('android:process=":game"'));
    expect(
      gameActivity,
      contains(r'android:taskAffinity="${applicationId}.game"'),
    );
    expect(gameActivity, contains('android:excludeFromRecents="true"'));
    expect(gameActivity, contains('android:launchMode="singleTask"'));
  });

  test('Android launcher exposes adaptive and monochrome icon layers', () {
    const resourceRoot = 'android/app/src/main/res';
    final adaptiveIcon = File(
      '$resourceRoot/mipmap-anydpi-v26/ic_launcher.xml',
    );
    final themedIcon = File(
      '$resourceRoot/mipmap-anydpi-v33/ic_launcher.xml',
    );

    expect(adaptiveIcon.existsSync(), isTrue);
    expect(themedIcon.existsSync(), isTrue);

    final adaptiveXml = adaptiveIcon.readAsStringSync();
    final themedXml = themedIcon.readAsStringSync();
    expect(adaptiveXml, contains('@drawable/ic_launcher_background'));
    expect(adaptiveXml, contains('@mipmap/ic_launcher_foreground'));
    expect(adaptiveXml, isNot(contains('<monochrome')));
    expect(themedXml, contains('@drawable/ic_launcher_background'));
    expect(themedXml, contains('@mipmap/ic_launcher_foreground'));
    expect(themedXml, contains('@mipmap/ic_launcher_monochrome'));

    for (final density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
      for (final layer in ['foreground', 'monochrome']) {
        final iconLayer = File(
          '$resourceRoot/mipmap-$density/ic_launcher_$layer.png',
        );
        expect(
          iconLayer.existsSync(),
          isTrue,
          reason: 'missing $density launcher $layer layer',
        );
        expect(iconLayer.lengthSync(), greaterThan(0));
      }
    }
  });
}

Uri _packageRoot(String packageName) {
  final packageConfigFile = File('.dart_tool/package_config.json');
  final packageConfig = jsonDecode(packageConfigFile.readAsStringSync());
  final packages = (packageConfig as Map<String, Object?>)['packages'];
  final package = (packages as List<Object?>)
      .cast<Map<String, Object?>>()
      .singleWhere((entry) => entry['name'] == packageName);
  return packageConfigFile.parent.uri.resolve(package['rootUri']! as String);
}
