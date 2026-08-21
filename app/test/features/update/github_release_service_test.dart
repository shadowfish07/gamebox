import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/features/update/github_release_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final checksum = List.filled(64, 'a').join();

  test('compares semantic versions including prereleases', () {
    expect(VersionComparator.compare('v1.1.0', '1.0.9+12'), greaterThan(0));
    expect(VersionComparator.compare('1.0.0', '1.0.0+7'), 0);
    expect(VersionComparator.compare('1.0.0-rc.2', '1.0.0'), lessThan(0));
    expect(VersionComparator.compare('1.0.0-rc.2', '1.0.0-rc.10'), lessThan(0));
  });

  test('loads a newer release with its exact APK checksum', () async {
    final requests = <http.Request>[];
    final service = GitHubReleaseService(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/checksums.txt')) {
          return http.Response('$checksum  gamebox-v1.1.0-android.apk\n', 200);
        }
        return http.Response(
          jsonEncode({
            'tag_name': 'v1.1.0',
            'name': 'Gamebox 1.1.0',
            'body': '修复安装流程',
            'html_url':
                'https://github.com/shadowfish07/gamebox/releases/tag/v1.1.0',
            'published_at': '2026-08-21T00:00:00Z',
            'assets': [
              {
                'name': 'gamebox-v1.1.0-android.apk',
                'browser_download_url': 'https://downloads.example/gamebox.apk',
              },
              {
                'name': 'checksums.txt',
                'browser_download_url':
                    'https://downloads.example/checksums.txt',
              },
            ],
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.checkForUpdate(currentVersion: '1.0.0+4');

    expect(result.hasUpdate, isTrue);
    expect(result.update?.version, '1.1.0');
    expect(result.update?.apkName, 'gamebox-v1.1.0-android.apk');
    expect(result.update?.sha256, checksum);
    expect(
      requests.first.url.path,
      '/repos/shadowfish07/gamebox/releases/latest',
    );
    expect(requests.first.headers['User-Agent'], 'Gamebox-update-check');
  });

  test('does not fetch assets when the installed version is current', () async {
    var requests = 0;
    final service = GitHubReleaseService(
      client: MockClient((_) async {
        requests += 1;
        return http.Response(jsonEncode({'tag_name': 'v1.0.0'}), 200);
      }),
    );

    final result = await service.checkForUpdate(currentVersion: '1.0.0+7');

    expect(result.hasUpdate, isFalse);
    expect(requests, 1);
  });

  test('rejects unsafe APK names and missing checksum metadata', () async {
    final service = GitHubReleaseService(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'tag_name': 'v2.0.0',
            'html_url':
                'https://github.com/shadowfish07/gamebox/releases/tag/v2.0.0',
            'assets': [
              {
                'name': '../gamebox.apk',
                'browser_download_url': 'https://downloads.example/gamebox.apk',
              },
            ],
          }),
          200,
        ),
      ),
    );

    await expectLater(
      service.checkForUpdate(currentVersion: '1.0.0'),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          contains('APK'),
        ),
      ),
    );
  });
}
