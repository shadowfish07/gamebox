import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_update.dart';

abstract interface class ReleaseService {
  Future<UpdateCheckResult> checkForUpdate({required String currentVersion});
}

final class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class GitHubReleaseService implements ReleaseService {
  GitHubReleaseService({
    required this._client,
    this.repository = 'shadowfish07/gamebox',
    this.apiBaseUrl = 'https://api.github.com',
  });

  final http.Client _client;
  final String repository;
  final String apiBaseUrl;

  @override
  Future<UpdateCheckResult> checkForUpdate({
    required String currentVersion,
  }) async {
    try {
      final response = await _client
          .get(
            Uri.parse(
              '${apiBaseUrl.replaceFirst(RegExp(r'/+$'), '')}/repos/$repository/releases/latest',
            ),
            headers: const {
              'Accept': 'application/vnd.github+json',
              'X-GitHub-Api-Version': '2022-11-28',
              'User-Agent': 'Gamebox-update-check',
            },
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) {
        throw UpdateCheckException(switch (response.statusCode) {
          403 => 'GitHub 更新服务请求过于频繁，请稍后再试',
          404 => 'GitHub 暂无可用的正式版本',
          _ => 'GitHub 更新检查失败（HTTP ${response.statusCode}）',
        });
      }
      if (response.bodyBytes.length > 1024 * 1024) {
        throw const UpdateCheckException('GitHub 更新响应异常过大');
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        throw const UpdateCheckException('GitHub 更新响应格式无效');
      }
      final tagName = decoded['tag_name'];
      if (tagName is! String || tagName.trim().isEmpty) {
        throw const UpdateCheckException('GitHub Release 缺少版本号');
      }
      final releaseVersion = VersionComparator.normalize(tagName);
      if (!VersionComparator.isNewer(releaseVersion, currentVersion)) {
        return const UpdateCheckResult();
      }

      final releaseUrl = _validUrl(decoded['html_url']);
      if (releaseUrl == null) {
        throw const UpdateCheckException('GitHub Release 缺少有效页面');
      }
      final assets = decoded['assets'];
      if (assets is! List<Object?>) {
        throw const UpdateCheckException('GitHub Release 缺少安装包');
      }
      final apk = _findAsset(assets, (name) => name.endsWith('.apk'));
      final checksums = _findAsset(assets, (name) => name == 'checksums.txt');
      if (apk == null || checksums == null) {
        throw const UpdateCheckException('GitHub Release 缺少 APK 或校验文件');
      }
      final checksum = await _loadChecksum(
        checksumUrl: checksums.url,
        apkName: apk.name,
      );

      return UpdateCheckResult(
        update: AppUpdate(
          version: releaseVersion,
          title: switch (decoded['name']) {
            final String value when value.trim().isNotEmpty => value.trim(),
            _ => 'Gamebox $releaseVersion',
          },
          releaseNotes: decoded['body'] is String
              ? (decoded['body']! as String).trim()
              : '',
          releaseUrl: releaseUrl,
          apkUrl: apk.url,
          apkName: apk.name,
          sha256: checksum,
          publishedAt: decoded['published_at'] is String
              ? DateTime.tryParse(decoded['published_at']! as String)?.toLocal()
              : null,
        ),
      );
    } on UpdateCheckException {
      rethrow;
    } on FormatException {
      throw const UpdateCheckException('GitHub Release 版本号无效');
    } on Object {
      throw const UpdateCheckException('暂时无法检查更新，请检查网络连接');
    }
  }

  Future<String> _loadChecksum({
    required String checksumUrl,
    required String apkName,
  }) async {
    final response = await _client
        .get(
          Uri.parse(checksumUrl),
          headers: const {'User-Agent': 'Gamebox-update-check'},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw const UpdateCheckException('无法读取 APK 校验文件');
    }
    if (response.bodyBytes.length > 64 * 1024) {
      throw const UpdateCheckException('APK 校验文件异常过大');
    }
    for (final line in const LineSplitter().convert(response.body)) {
      final match = RegExp(r'^([0-9a-fA-F]{64})\s+\*?(.+)$')
          .firstMatch(line.trim());
      if (match != null && match.group(2) == apkName) {
        return match.group(1)!.toLowerCase();
      }
    }
    throw const UpdateCheckException('APK 校验文件不完整');
  }

  _ReleaseAsset? _findAsset(
    List<Object?> assets,
    bool Function(String name) matches,
  ) {
    for (final asset in assets) {
      if (asset is! Map<String, Object?>) continue;
      final nameValue = asset['name'];
      final url = _validUrl(asset['browser_download_url']);
      if (nameValue is! String || url == null) continue;
      final name = nameValue.trim();
      if (RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(name) &&
          matches(name.toLowerCase())) {
        return _ReleaseAsset(name: name, url: url);
      }
    }
    return null;
  }

  String? _validUrl(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty
        ? value
        : null;
  }
}

final class _ReleaseAsset {
  const _ReleaseAsset({required this.name, required this.url});

  final String name;
  final String url;
}

abstract final class VersionComparator {
  static int compare(String left, String right) {
    final leftVersion = _ReleaseVersion.parse(left);
    final rightVersion = _ReleaseVersion.parse(right);
    final coreComparison = leftVersion.compareCoreTo(rightVersion);
    return coreComparison != 0
        ? coreComparison
        : leftVersion.comparePrereleaseTo(rightVersion);
  }

  static bool isNewer(String candidate, String current) =>
      compare(candidate, current) > 0;

  static String normalize(String version) =>
      _ReleaseVersion.parse(version).normalized;
}

final class _ReleaseVersion {
  const _ReleaseVersion({
    required this.major,
    required this.minor,
    required this.patch,
    required this.prerelease,
  });

  factory _ReleaseVersion.parse(String input) {
    final match = RegExp(
      r'^[vV]?(\d+)\.(\d+)\.(\d+)'
      r'(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?'
      r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
    ).firstMatch(input.trim());
    if (match == null) throw FormatException('Invalid semantic version');
    return _ReleaseVersion(
      major: int.parse(match.group(1)!),
      minor: int.parse(match.group(2)!),
      patch: int.parse(match.group(3)!),
      prerelease: match.group(4)?.split('.') ?? const [],
    );
  }

  final int major;
  final int minor;
  final int patch;
  final List<String> prerelease;

  String get normalized {
    final core = '$major.$minor.$patch';
    return prerelease.isEmpty ? core : '$core-${prerelease.join('.')}';
  }

  int compareCoreTo(_ReleaseVersion other) {
    final majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final minorResult = minor.compareTo(other.minor);
    return minorResult != 0 ? minorResult : patch.compareTo(other.patch);
  }

  int comparePrereleaseTo(_ReleaseVersion other) {
    if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
    if (prerelease.isEmpty) return 1;
    if (other.prerelease.isEmpty) return -1;
    final length = prerelease.length > other.prerelease.length
        ? prerelease.length
        : other.prerelease.length;
    for (var index = 0; index < length; index++) {
      if (index >= prerelease.length) return -1;
      if (index >= other.prerelease.length) return 1;
      final left = prerelease[index];
      final right = other.prerelease[index];
      final leftNumber = int.tryParse(left);
      final rightNumber = int.tryParse(right);
      final result = switch ((leftNumber, rightNumber)) {
        (final int left, final int right) => left.compareTo(right),
        (final int _, null) => -1,
        (null, final int _) => 1,
        _ => left.compareTo(right),
      };
      if (result != 0) return result;
    }
    return 0;
  }
}
