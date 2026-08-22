import 'dart:io';

import 'package:flutter_release_updater/src/github_release_service.dart';
import 'package:http/http.dart' as http;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run tool/live_github_smoke.dart <owner/repo> <current-version>',
    );
    exitCode = 2;
    return;
  }

  final repository = arguments[0];
  final client = http.Client();
  try {
    final result = await GitHubReleaseService(
      client: client,
      repository: repository,
      userAgent: 'flutter-release-updater-live-smoke',
    ).checkForUpdate(currentVersion: arguments[1]);
    final update = result.update;
    if (update == null) {
      stdout.writeln('$repository: no newer stable release');
      return;
    }
    stdout.writeln(
      '$repository: v${update.version}, ${update.apkName}, SHA-256 available',
    );
  } on UpdateCheckException catch (error) {
    stderr.writeln('$repository: ${error.message}');
    exitCode = 1;
  } finally {
    client.close();
  }
}
