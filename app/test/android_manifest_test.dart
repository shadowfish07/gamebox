import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

int readGameboxTargetSdk(String gradleProperties) {
  final matches = RegExp(
    r'^GAMEBOX_TARGET_SDK=([0-9]+)$',
    multiLine: true,
  ).allMatches(gradleProperties).toList();
  expect(matches, hasLength(1));
  return int.parse(matches.single.group(1)!);
}

void expectLocalNetworkPermissionPolicy({
  required int targetSdk,
  required String manifest,
  required String runtimePermissionSource,
}) {
  const permission = 'android.permission.ACCESS_LOCAL_NETWORK';
  final shouldRequest = targetSdk >= 37;

  expect(manifest.contains(permission), shouldRequest);
  expect(runtimePermissionSource, contains(permission));
  expect(runtimePermissionSource, contains('MIN_TARGET_SDK = 37'));
}

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

  test('Android declares the private LAN host foreground-service surface', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();

    for (final permission in <String>[
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE',
      'android.permission.CHANGE_NETWORK_STATE',
      'android.permission.POST_NOTIFICATIONS',
      'android.permission.CAMERA',
    ]) {
      expect(manifest, contains('android:name="$permission"'));
    }
    expect(
      manifest,
      contains(
        '<uses-feature android:name="android.hardware.camera.any" '
        'android:required="false" />',
      ),
    );

    final service = RegExp(
      r'<service\b(?=[^>]*android:name="\.LanHostService")[^>]*>',
      dotAll: true,
    ).firstMatch(manifest)?.group(0);
    expect(service, isNotNull);
    expect(service, contains('android:exported="false"'));
    expect(
      service,
      contains('android:foregroundServiceType="connectedDevice"'),
    );
  });

  test('local-network permission policy follows the real target SDK pin', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync();
    final gradleProperties = File('android/gradle.properties')
        .readAsStringSync();
    final buildScript = File('android/app/build.gradle.kts').readAsStringSync();
    final runtimePolicy = File(
      'android/app/src/main/kotlin/me/zqydev/gamebox/'
      'LanLocalNetworkPermissionPolicy.kt',
    ).readAsStringSync();
    final targetSdk = readGameboxTargetSdk(gradleProperties);

    expectLocalNetworkPermissionPolicy(
      targetSdk: targetSdk,
      manifest: manifest,
      runtimePermissionSource: runtimePolicy,
    );
    expect(buildScript, contains('gradleProperty("GAMEBOX_TARGET_SDK")'));
    expect(buildScript, contains('targetSdk = gameboxTargetSdk'));
  });
  test('Android launcher exposes adaptive and monochrome icon layers', () {
    const resourceRoot = 'android/app/src/main/res';
    final adaptiveIcon = File(
      '$resourceRoot/mipmap-anydpi-v26/ic_launcher.xml',
    );
    final themedIcon = File('$resourceRoot/mipmap-anydpi-v33/ic_launcher.xml');

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
