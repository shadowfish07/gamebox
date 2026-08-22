import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/platform/apk_installer.dart';
import 'app_update.dart';
import 'github_release_service.dart';

final class UpdateController extends ChangeNotifier {
  static const maxApkBytes = 500 * 1024 * 1024;

  UpdateController({
    required this.installedVersion,
    required this._releaseService,
    required this._installer,
    required this._downloadClient,
    required this._preferences,
    required this._updateDirectory,
    DateTime Function()? now,
    this.checkInterval = const Duration(hours: 6),
  }) : _now = now ?? DateTime.now;

  static const _lastCheckKey = 'update.lastCheckAt';
  static const _cachedUpdateKey = 'update.available';

  static Future<UpdateController> production() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final preferences = await SharedPreferences.getInstance();
    final supportDirectory = await getApplicationSupportDirectory();
    final releaseClient = http.Client();
    return UpdateController(
      installedVersion: packageInfo.version,
      releaseService: GitHubReleaseService(client: releaseClient),
      installer: MethodChannelApkInstaller(),
      downloadClient: http.Client(),
      preferences: preferences,
      updateDirectory: Directory('${supportDirectory.path}/updates'),
    ).._ownedReleaseClient = releaseClient;
  }

  final String installedVersion;
  final ReleaseService _releaseService;
  final ApkInstaller _installer;
  final http.Client _downloadClient;
  final SharedPreferences _preferences;
  final Directory _updateDirectory;
  final DateTime Function() _now;
  final Duration checkInterval;

  http.Client? _ownedReleaseClient;
  UpdateStatus _status = UpdateStatus.idle;
  AppUpdate? _availableUpdate;
  DateTime? _lastCheckAt;
  String _errorMessage = '';
  double? _downloadProgress;
  String? _downloadedApkPath;
  bool _started = false;
  bool _disposed = false;

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
      await _preferences.setString(
        _lastCheckKey,
        _lastCheckAt!.toUtc().toIso8601String(),
      );
      _availableUpdate = result.update;
      _errorMessage = '';
      _downloadedApkPath = null;
      if (result.update == null) {
        await _preferences.remove(_cachedUpdateKey);
        _setStatus(UpdateStatus.upToDate);
      } else {
        await _preferences.setString(
          _cachedUpdateKey,
          jsonEncode(result.update!.toJson()),
        );
        _setStatus(UpdateStatus.available);
      }
    } on UpdateCheckException catch (error) {
      _lastCheckAt = _now();
      await _preferences.setString(
        _lastCheckKey,
        _lastCheckAt!.toUtc().toIso8601String(),
      );
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
      request.headers['User-Agent'] = 'Gamebox-update-download';
      final response = await _downloadClient
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) {
        throw const UpdateDownloadException('APK 下载失败');
      }
      if (response.contentLength case final contentLength?
          when contentLength > maxApkBytes) {
        throw const UpdateDownloadException('APK 文件异常过大');
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
          if (received > maxApkBytes) {
            throw const UpdateDownloadException('APK 文件异常过大');
          }
          final total = response.contentLength;
          if (total != null && total > 0) {
            final progress = (received / total).clamp(0.0, 1.0);
            if (progress - lastReported >= 0.01 || progress == 1) {
              lastReported = progress;
              _downloadProgress = progress;
              notifyListeners();
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
        await partial.delete();
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
    final lastCheckValue = _preferences.getString(_lastCheckKey);
    _lastCheckAt = lastCheckValue == null
        ? null
        : DateTime.tryParse(lastCheckValue)?.toLocal();
    final cachedValue = _preferences.getString(_cachedUpdateKey);
    if (cachedValue == null) return;
    try {
      _availableUpdate = AppUpdate.fromJson(jsonDecode(cachedValue) as Object?);
      final cachedUpdate = _availableUpdate;
      if (cachedUpdate != null &&
          VersionComparator.isNewer(cachedUpdate.version, installedVersion)) {
        _status = UpdateStatus.available;
      } else {
        _availableUpdate = null;
        unawaited(_preferences.remove(_cachedUpdateKey));
      }
    } on FormatException {
      _availableUpdate = null;
      unawaited(_preferences.remove(_cachedUpdateKey));
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
    _downloadClient.close();
    _ownedReleaseClient?.close();
    super.dispose();
  }
}

final class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);

  final String message;
}
