import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_update.dart';

abstract class ReleaseService {
  Future<UpdateCheckResult> checkForUpdate({required String currentVersion});

  void dispose() {}
}

enum UpdateCheckFailure {
  rateLimited,
  noRelease,
  http,
  responseTooLarge,
  invalidResponse,
  invalidVersion,
  missingApk,
  missingChecksum,
  network,
}

final class UpdateCheckException implements Exception {
  const UpdateCheckException(this.failure, this.message, {this.statusCode});

  final UpdateCheckFailure failure;
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

typedef ApkAssetMatcher = bool Function(String assetName);

final class GitHubReleaseService extends ReleaseService {
  GitHubReleaseService({
    required http.Client client,
    required this.repository,
    required this.userAgent,
    this.apiBaseUrl = 'https://api.github.com',
    this.timeout = const Duration(seconds: 10),
    ApkAssetMatcher? apkAssetMatcher,
  }) : _client = client,
       apkAssetMatcher = apkAssetMatcher ?? _defaultApkAssetMatcher {
    if (!RegExp(r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$').hasMatch(repository)) {
      throw ArgumentError.value(
        repository,
        'repository',
        'Expected owner/repo',
      );
    }
    if (userAgent.trim().isEmpty || userAgent.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError.value(
        userAgent,
        'userAgent',
        'Invalid HTTP user agent',
      );
    }
    final apiBase = Uri.tryParse(apiBaseUrl);
    if (apiBase == null || apiBase.scheme != 'https' || apiBase.host.isEmpty) {
      throw ArgumentError.value(
        apiBaseUrl,
        'apiBaseUrl',
        'Expected an HTTPS URL',
      );
    }
  }

  static const maxResponseBytes = 1024 * 1024;
  static const maxChecksumBytes = 64 * 1024;

  final http.Client _client;
  final String repository;
  final String userAgent;
  final String apiBaseUrl;
  final Duration timeout;
  final ApkAssetMatcher apkAssetMatcher;

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
            headers: _headers,
          )
          .timeout(timeout);
      _requireSuccess(response, isChecksum: false);
      if (response.bodyBytes.length > maxResponseBytes) {
        throw const UpdateCheckException(
          UpdateCheckFailure.responseTooLarge,
          'GitHub 更新响应异常过大',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<Object?, Object?>) {
        throw const UpdateCheckException(
          UpdateCheckFailure.invalidResponse,
          'GitHub 更新响应格式无效',
        );
      }
      final tagName = decoded['tag_name'];
      if (tagName is! String || tagName.trim().isEmpty) {
        throw const UpdateCheckException(
          UpdateCheckFailure.invalidResponse,
          'GitHub Release 缺少版本号',
        );
      }
      final releaseVersion = VersionComparator.normalize(tagName);
      if (!VersionComparator.isNewer(releaseVersion, currentVersion)) {
        return const UpdateCheckResult();
      }

      final releaseUrl = decoded['html_url'];
      if (releaseUrl is! String || !isSafeWebUrl(releaseUrl)) {
        throw const UpdateCheckException(
          UpdateCheckFailure.invalidResponse,
          'GitHub Release 缺少有效页面',
        );
      }
      final assets = decoded['assets'];
      if (assets is! List<Object?>) {
        throw const UpdateCheckException(
          UpdateCheckFailure.missingApk,
          'GitHub Release 缺少 APK',
        );
      }
      final apk = _findAsset(
        assets,
        (asset) =>
            asset.name.toLowerCase().endsWith('.apk') &&
            apkAssetMatcher(asset.name),
      );
      if (apk == null) {
        throw const UpdateCheckException(
          UpdateCheckFailure.missingApk,
          'GitHub Release 缺少 APK',
        );
      }
      final checksum =
          _sha256FromDigest(apk.digest) ??
          await _loadChecksumFromAsset(assets: assets, apkName: apk.name);

      return UpdateCheckResult(
        update: AppUpdate(
          version: releaseVersion,
          title: switch (decoded['name']) {
            final String value when value.trim().isNotEmpty => value.trim(),
            _ => '$repository $releaseVersion',
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
      throw const UpdateCheckException(
        UpdateCheckFailure.invalidVersion,
        'GitHub Release 版本号无效',
      );
    } on Object {
      throw const UpdateCheckException(
        UpdateCheckFailure.network,
        '暂时无法检查更新，请检查网络连接',
      );
    }
  }

  Map<String, String> get _headers => {
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': userAgent,
  };

  void _requireSuccess(http.Response response, {required bool isChecksum}) {
    if (response.statusCode == 200) return;
    if (isChecksum) {
      throw const UpdateCheckException(
        UpdateCheckFailure.missingChecksum,
        '无法读取 APK 校验文件',
      );
    }
    throw switch (response.statusCode) {
      403 => const UpdateCheckException(
        UpdateCheckFailure.rateLimited,
        'GitHub 更新服务请求过于频繁，请稍后再试',
        statusCode: 403,
      ),
      404 => const UpdateCheckException(
        UpdateCheckFailure.noRelease,
        'GitHub 暂无可用的正式版本',
        statusCode: 404,
      ),
      final status => UpdateCheckException(
        UpdateCheckFailure.http,
        'GitHub 更新检查失败（HTTP $status）',
        statusCode: status,
      ),
    };
  }

  Future<String> _loadChecksumFromAsset({
    required List<Object?> assets,
    required String apkName,
  }) async {
    final checksums = _findAsset(
      assets,
      (asset) => asset.name.toLowerCase() == 'checksums.txt',
    );
    if (checksums == null) {
      throw const UpdateCheckException(
        UpdateCheckFailure.missingChecksum,
        'GitHub Release 缺少 APK 校验值',
      );
    }
    final response = await _client
        .get(Uri.parse(checksums.url), headers: _headers)
        .timeout(timeout);
    _requireSuccess(response, isChecksum: true);
    if (response.bodyBytes.length > maxChecksumBytes) {
      throw const UpdateCheckException(
        UpdateCheckFailure.missingChecksum,
        'APK 校验文件异常过大',
      );
    }
    for (final line in const LineSplitter().convert(response.body)) {
      final match = RegExp(
        r'^([0-9a-fA-F]{64})\s+\*?(.+)$',
      ).firstMatch(line.trim());
      if (match != null && match.group(2) == apkName) {
        return match.group(1)!.toLowerCase();
      }
    }
    throw const UpdateCheckException(
      UpdateCheckFailure.missingChecksum,
      'APK 校验文件不完整',
    );
  }

  _ReleaseAsset? _findAsset(
    List<Object?> assets,
    bool Function(_ReleaseAsset asset) matches,
  ) {
    for (final encodedAsset in assets.take(100)) {
      if (encodedAsset is! Map<Object?, Object?>) continue;
      final name = encodedAsset['name'];
      final url = encodedAsset['browser_download_url'];
      if (name is! String ||
          !isSafeAssetName(name) ||
          url is! String ||
          !isSafeWebUrl(url)) {
        continue;
      }
      final asset = _ReleaseAsset(
        name: name,
        url: url,
        digest: encodedAsset['digest'] is String
            ? encodedAsset['digest']! as String
            : null,
      );
      if (matches(asset)) return asset;
    }
    return null;
  }

  static String? _sha256FromDigest(String? digest) {
    if (digest == null) return null;
    final match = RegExp(r'^sha256:([0-9a-fA-F]{64})$').firstMatch(digest);
    return match?.group(1)?.toLowerCase();
  }

  static bool _defaultApkAssetMatcher(String assetName) =>
      assetName.toLowerCase().endsWith('.apk');
}

final class _ReleaseAsset {
  const _ReleaseAsset({
    required this.name,
    required this.url,
    required this.digest,
  });

  final String name;
  final String url;
  final String? digest;
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
    if (match == null) throw const FormatException('Invalid semantic version');
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
