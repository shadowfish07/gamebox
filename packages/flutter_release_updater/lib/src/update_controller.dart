import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'apk_installer.dart';
import 'app_update.dart';
import 'github_release_service.dart';

enum UpdateStatus {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  permissionRequired,
  installerOpened,
  failed,
}

final class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.installedVersion,
    required ReleaseService releaseService,
    required ApkInstaller installer,
    required http.Client downloadClient,
    required SharedPreferences preferences,
    required Directory updateDirectory,
    required this.cacheKeyPrefix,
    required this.downloadUserAgent,
    DateTime Function()? now,
    this.checkInterval = const Duration(hours: 6),
  }) : _releaseService = releaseService,
       _installer = installer,
       _downloadClient = downloadClient,
       _preferences = preferences,
       _updateDirectory = updateDirectory,
       _now = now ?? DateTime.now {
    if (cacheKeyPrefix.trim().isEmpty) {
      throw ArgumentError.value(
        cacheKeyPrefix,
        'cacheKeyPrefix',
        'Cannot be empty',
      );
    }
    if (downloadUserAgent.trim().isEmpty ||
        downloadUserAgent.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError.value(
        downloadUserAgent,
        'downloadUserAgent',
        'Invalid HTTP user agent',
      );
    }
  }

  static Future<UpdateController> production({
    required String repository,
    required String userAgent,
    String cacheKeyPrefix = 'releaseUpdater',
    String apiBaseUrl = 'https://api.github.com',
    Duration checkInterval = const Duration(hours: 6),
    ApkAssetMatcher? apkAssetMatcher,
  }) async {
    final packageInfo = await PackageInfo.fromPlatform();
    final preferences = await SharedPreferences.getInstance();
    final supportDirectory = await getApplicationSupportDirectory();
    final releaseClient = http.Client();
    final downloadClient = http.Client();
    return UpdateController(
      installedVersion: packageInfo.version,
      releaseService: GitHubReleaseService(
        client: releaseClient,
        repository: repository,
        userAgent: userAgent,
        apiBaseUrl: apiBaseUrl,
        apkAssetMatcher: apkAssetMatcher,
      ),
      installer: MethodChannelApkInstaller(),
      downloadClient: downloadClient,
      preferences: preferences,
      updateDirectory: Directory(
        '${supportDirectory.path}/flutter_release_updater',
      ),
      cacheKeyPrefix: cacheKeyPrefix,
      downloadUserAgent: userAgent,
      checkInterval: checkInterval,
    ).._ownedClients = [releaseClient, downloadClient];
  }

  final String installedVersion;
  final String cacheKeyPrefix;
  final String downloadUserAgent;
  final Duration checkInterval;
  final ReleaseService _releaseService;
  final ApkInstaller _installer;
  final http.Client _downloadClient;
  final SharedPreferences _preferences;
  final Directory _updateDirectory;
  final DateTime Function() _now;

  List<http.Client> _ownedClients = const [];
  UpdateStatus _status = UpdateStatus.idle;
  AppUpdate? _availableUpdate;
  DateTime? _lastCheckAt;
  String _errorMessage = '';
  double? _downloadProgress;
  String? _downloadedApkPath;
  bool _started = false;
  bool _disposed = false;

  String get _lastCheckKey => '$cacheKeyPrefix.lastCheckAt';
  String get _cachedUpdateKey => '$cacheKeyPrefix.available';

  UpdateStatus get status => _status;
  AppUpdate? get availableUpdate => _availableUpdate;
  DateTime? get lastCheckAt => _lastCheckAt;
  String get errorMessage => _errorMessage;
  double? get downloadProgress => _downloadProgress;
  bool get isBusy =>
      _status == UpdateStatus.checking || _status == UpdateStatus.downloading;

  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    _restoreCache();
    notifyListeners();
    await checkIfDue();
  }

  Future<void> checkIfDue() async {
    final lastCheckAt = _lastCheckAt;
    if (lastCheckAt != null && _now().difference(lastCheckAt) < checkInterval) {
      return;
    }
    await checkNow();
  }

  Future<void> checkNow() async {
    if (_disposed || isBusy) return;
    _setStatus(UpdateStatus.checking);
    try {
      final result = await _releaseService.checkForUpdate(
        currentVersion: installedVersion,
      );
      _lastCheckAt = _now();
      await _persistLastCheck();
      _availableUpdate = result.update;
      _errorMessage = '';
      _downloadedApkPath = null;
      if (result.update == null) {
        await _removeCachedUpdate();
        _setStatus(UpdateStatus.upToDate);
      } else {
        await _persistUpdate(result.update!);
        _setStatus(UpdateStatus.available);
      }
    } on UpdateCheckException catch (error) {
      _lastCheckAt = _now();
      await _persistLastCheck();
      _fail(error.message);
    } on Object {
      _fail('暂时无法检查更新');
    }
  }

  Future<void> downloadAndInstall() async {
    final update = _availableUpdate;
    if (_disposed || isBusy || update == null) return;
    final existingPath = _downloadedApkPath;
    if (existingPath != null && await File(existingPath).exists()) {
      await _launchInstaller(existingPath);
      return;
    }

    _downloadProgress = 0;
    _setStatus(UpdateStatus.downloading);
    File? partial;
    try {
      await _updateDirectory.create(recursive: true);
      partial = File('${_updateDirectory.path}/${update.apkName}.part');
      final completed = File('${_updateDirectory.path}/${update.apkName}');
      await _deleteIfPresent(partial);
      await _deleteIfPresent(completed);

      final request = http.Request('GET', Uri.parse(update.apkUrl));
      request.headers['User-Agent'] = downloadUserAgent;
      final response = await _downloadClient
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw const UpdateDownloadException('APK 下载失败');
      }
      final sink = partial.openWrite();
      var received = 0;
      var lastReported = 0.0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          sink.add(chunk);
          received += chunk.length;
          final total = response.contentLength;
          if (total != null && total > 0) {
            final progress = (received / total).clamp(0.0, 1.0);
            if (progress - lastReported >= 0.01 || progress == 1) {
              lastReported = progress;
              _downloadProgress = progress;
              if (!_disposed) notifyListeners();
            }
          }
        }
      } finally {
        await sink.close();
      }
      if (received == 0) {
        throw const UpdateDownloadException('下载的 APK 为空');
      }
      final digest = await sha256.bind(partial.openRead()).first;
      if (digest.toString() != update.sha256) {
        await _deleteIfPresent(partial);
        throw const UpdateDownloadException('APK 校验失败，请重新下载');
      }
      await partial.rename(completed.path);
      _downloadedApkPath = completed.path;
      _downloadProgress = 1;
      await _launchInstaller(completed.path);
    } on UpdateDownloadException catch (error) {
      await _deleteIfPresent(partial);
      _fail(error.message);
    } on TimeoutException {
      await _deleteIfPresent(partial);
      _fail('APK 下载超时，请检查网络后重试');
    } on Object {
      await _deleteIfPresent(partial);
      _fail('无法下载或安装更新');
    }
  }

  Future<void> _deleteIfPresent(File? file) async {
    if (file == null) return;
    try {
      if (await file.exists()) await file.delete();
    } on FileSystemException {
      // A later retry overwrites the same private temporary path.
    }
  }

  Future<void> _launchInstaller(String path) async {
    try {
      final result = await _installer.launchInstaller(path);
      _errorMessage = '';
      _setStatus(switch (result) {
        InstallLaunchResult.started => UpdateStatus.installerOpened,
        InstallLaunchResult.permissionRequired =>
          UpdateStatus.permissionRequired,
      });
    } on ApkInstallException {
      _fail('无法打开系统安装器');
    }
  }

  void _restoreCache() {
    try {
      final lastCheckValue = _preferences.getString(_lastCheckKey);
      _lastCheckAt = lastCheckValue == null
          ? null
          : DateTime.tryParse(lastCheckValue)?.toLocal();
      final cachedValue = _preferences.getString(_cachedUpdateKey);
      if (cachedValue == null) return;
      final cachedUpdate = AppUpdate.fromJson(jsonDecode(cachedValue));
      if (cachedUpdate != null &&
          VersionComparator.isNewer(cachedUpdate.version, installedVersion)) {
        _availableUpdate = cachedUpdate;
        _status = UpdateStatus.available;
      } else {
        unawaited(_removeCachedUpdate());
      }
    } on Object {
      _availableUpdate = null;
      unawaited(_removeCachedUpdate());
    }
  }

  Future<void> _persistLastCheck() async {
    try {
      await _preferences.setString(
        _lastCheckKey,
        _lastCheckAt!.toUtc().toIso8601String(),
      );
    } on Object {
      // Cache failures must not turn a successful network check into a failure.
    }
  }

  Future<void> _persistUpdate(AppUpdate update) async {
    try {
      await _preferences.setString(
        _cachedUpdateKey,
        jsonEncode(update.toJson()),
      );
    } on Object {
      // The next application launch can perform a fresh check.
    }
  }

  Future<void> _removeCachedUpdate() async {
    try {
      await _preferences.remove(_cachedUpdateKey);
    } on Object {
      // A stale cache is revalidated before it is shown on the next launch.
    }
  }

  void _setStatus(UpdateStatus value) {
    _status = value;
    if (!_disposed) notifyListeners();
  }

  void _fail(String message) {
    _errorMessage = message;
    _setStatus(UpdateStatus.failed);
  }

  @override
  void dispose() {
    _disposed = true;
    _releaseService.dispose();
    for (final client in _ownedClients) {
      client.close();
    }
    super.dispose();
  }
}

final class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);

  final String message;
}
