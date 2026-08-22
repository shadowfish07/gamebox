import 'dart:convert';

import 'package:flutter_release_updater/flutter_release_updater.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'compares semantic versions including prereleases and build metadata',
    () {
      expect(VersionComparator.compare('v1.1.0', '1.0.9+12'), greaterThan(0));
      expect(VersionComparator.compare('1.0.0', '1.0.0+7'), 0);
      expect(VersionComparator.compare('1.0.0-rc.2', '1.0.0'), lessThan(0));
      expect(
        VersionComparator.compare('1.0.0-rc.2', '1.0.0-rc.10'),
        lessThan(0),
      );
    },
  );

  test('uses the GitHub asset SHA-256 digest when present', () async {
    late http.Request request;
    final checksum = List.filled(64, 'a').join();
    var requests = 0;
    final service = GitHubReleaseService(
      client: MockClient((captured) async {
        request = captured;
        requests += 1;
        return http.Response(
          jsonEncode(_release(assets: [_apkAsset(digest: 'sha256:$checksum')])),
          200,
        );
      }),
      repository: 'owner/repo',
      userAgent: 'Example-update-check',
    );

    final result = await service.checkForUpdate(currentVersion: '1.0.0+4');

    expect(result.update?.version, '1.1.0');
    expect(result.update?.apkName, 'example-v1.1.0.apk');
    expect(result.update?.sha256, checksum);
    expect(request.url.path, '/repos/owner/repo/releases/latest');
    expect(request.headers['User-Agent'], 'Example-update-check');
    expect(requests, 1);
  });

  test('falls back to checksums.txt and supports APK selection', () async {
    final checksum = List.filled(64, 'B').join();
    var requests = 0;
    final service = GitHubReleaseService(
      client: MockClient((request) async {
        requests += 1;
        if (request.url.path.endsWith('/checksums.txt')) {
          return http.Response('$checksum  example-arm64.apk\n', 200);
        }
        return http.Response(
          jsonEncode(
            _release(
              assets: [
                _apkAsset(name: 'example-x86_64.apk'),
                _apkAsset(name: 'example-arm64.apk'),
                {
                  'name': 'checksums.txt',
                  'browser_download_url':
                      'https://downloads.example/checksums.txt',
                },
              ],
            ),
          ),
          200,
        );
      }),
      repository: 'owner/repo',
      userAgent: 'Example-update-check',
      apkAssetMatcher: (name) => name.contains('arm64'),
    );

    final result = await service.checkForUpdate(currentVersion: '1.0.0');

    expect(result.update?.apkName, 'example-arm64.apk');
    expect(result.update?.sha256, checksum.toLowerCase());
    expect(requests, 2);
  });

  test('rejects an update that has no authenticated APK checksum', () async {
    final service = GitHubReleaseService(
      client: MockClient(
        (_) async =>
            http.Response(jsonEncode(_release(assets: [_apkAsset()])), 200),
      ),
      repository: 'owner/repo',
      userAgent: 'Example-update-check',
    );

    await expectLater(
      service.checkForUpdate(currentVersion: '1.0.0'),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.failure,
          'failure',
          UpdateCheckFailure.missingChecksum,
        ),
      ),
    );
  });

  test('does not require release assets when already current', () async {
    final service = GitHubReleaseService(
      client: MockClient(
        (_) async => http.Response(jsonEncode({'tag_name': 'v1.0.0'}), 200),
      ),
      repository: 'owner/repo',
      userAgent: 'Example-update-check',
    );

    final result = await service.checkForUpdate(currentVersion: '1.0.0+7');

    expect(result.hasUpdate, isFalse);
  });

  test('classifies invalid release versions', () async {
    final service = GitHubReleaseService(
      client: MockClient(
        (_) async => http.Response(jsonEncode({'tag_name': 'rolling'}), 200),
      ),
      repository: 'owner/repo',
      userAgent: 'Example-update-check',
    );

    await expectLater(
      service.checkForUpdate(currentVersion: '1.0.0'),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.failure,
          'failure',
          UpdateCheckFailure.invalidVersion,
        ),
      ),
    );
  });
}

Map<String, Object?> _release({required List<Map<String, Object?>> assets}) => {
  'tag_name': 'v1.1.0',
  'name': 'Example 1.1.0',
  'body': 'Release notes',
  'html_url': 'https://github.com/owner/repo/releases/tag/v1.1.0',
  'published_at': '2026-08-21T00:00:00Z',
  'assets': assets,
};

Map<String, Object?> _apkAsset({
  String name = 'example-v1.1.0.apk',
  String? digest,
}) => {
  'name': name,
  'browser_download_url': 'https://downloads.example/$name',
  if (digest != null) 'digest': digest,
};
