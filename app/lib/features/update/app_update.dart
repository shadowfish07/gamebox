final class AppUpdate {
  const AppUpdate({
    required this.version,
    required this.title,
    required this.releaseNotes,
    required this.releaseUrl,
    required this.apkUrl,
    required this.apkName,
    required this.sha256,
    this.publishedAt,
  });

  final String version;
  final String title;
  final String releaseNotes;
  final String releaseUrl;
  final String apkUrl;
  final String apkName;
  final String sha256;
  final DateTime? publishedAt;

  Map<String, Object?> toJson() => {
    'version': version,
    'title': title,
    'releaseNotes': releaseNotes,
    'releaseUrl': releaseUrl,
    'apkUrl': apkUrl,
    'apkName': apkName,
    'sha256': sha256,
    'publishedAt': publishedAt?.toUtc().toIso8601String(),
  };

  static AppUpdate? fromJson(Object? value) {
    if (value is! Map<String, Object?>) return null;
    final version = value['version'];
    final title = value['title'];
    final releaseNotes = value['releaseNotes'];
    final releaseUrl = value['releaseUrl'];
    final apkUrl = value['apkUrl'];
    final apkName = value['apkName'];
    final checksum = value['sha256'];
    if (version is! String ||
        title is! String ||
        releaseNotes is! String ||
        releaseUrl is! String ||
        apkUrl is! String ||
        apkName is! String ||
        checksum is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      return null;
    }
    return AppUpdate(
      version: version,
      title: title,
      releaseNotes: releaseNotes,
      releaseUrl: releaseUrl,
      apkUrl: apkUrl,
      apkName: apkName,
      sha256: checksum,
      publishedAt: value['publishedAt'] is String
          ? DateTime.tryParse(value['publishedAt']! as String)?.toLocal()
          : null,
    );
  }
}

final class UpdateCheckResult {
  const UpdateCheckResult({this.update});

  final AppUpdate? update;
  bool get hasUpdate => update != null;
}

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
