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
    if (value is! Map<Object?, Object?>) return null;
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
        !isSafeWebUrl(releaseUrl) ||
        apkUrl is! String ||
        !isSafeWebUrl(apkUrl) ||
        apkName is! String ||
        !isSafeAssetName(apkName) ||
        !apkName.toLowerCase().endsWith('.apk') ||
        checksum is! String ||
        !isSha256(checksum)) {
      return null;
    }

    return AppUpdate(
      version: version,
      title: title,
      releaseNotes: releaseNotes,
      releaseUrl: releaseUrl,
      apkUrl: apkUrl,
      apkName: apkName,
      sha256: checksum.toLowerCase(),
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

bool isSafeAssetName(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(value);

bool isSha256(String value) => RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);

bool isSafeWebUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      uri.scheme == 'https' &&
      uri.host.isNotEmpty &&
      uri.userInfo.isEmpty;
}
