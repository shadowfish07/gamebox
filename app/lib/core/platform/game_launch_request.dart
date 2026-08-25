enum GameLaunchSource { public, lan }

/// An immutable, validated request for launching a game in the native host.
final class GameLaunchRequest {
  GameLaunchRequest({
    required this.gameId,
    required this.matchId,
    required this.launchTicket,
    required this.wsUrl,
    this.source = GameLaunchSource.public,
    this.resumeToken,
    this.localUserId,
  }) {
    if (gameId.trim().isEmpty) {
      throw ArgumentError('gameId must not be blank');
    }
    if (!_isCanonicalUuid(matchId)) {
      throw ArgumentError('matchId must be a canonical UUID');
    }
    if (launchTicket.trim().isEmpty) {
      throw ArgumentError('launchTicket must not be blank');
    }
    if (!_isValidWebSocketUrl(wsUrl)) {
      throw ArgumentError('wsUrl must use a valid ws or wss URL');
    }
    if (source == GameLaunchSource.lan) {
      if (resumeToken == null || resumeToken!.trim().isEmpty) {
        throw ArgumentError('LAN launches require a resume token');
      }
      if (localUserId == null || !_isCanonicalUuid(localUserId!)) {
        throw ArgumentError('LAN launches require a canonical local user ID');
      }
    } else if (resumeToken != null) {
      throw ArgumentError('public launches must not include a resume token');
    } else if (localUserId != null) {
      throw ArgumentError('public launches must not include a local user ID');
    }
  }

  final String gameId;
  final String matchId;
  final String launchTicket;
  final String wsUrl;
  final GameLaunchSource source;
  final String? resumeToken;
  final String? localUserId;

  static final RegExp _canonicalUuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  static bool _isCanonicalUuid(String value) {
    return value != '00000000-0000-0000-0000-000000000000' &&
        _canonicalUuid.hasMatch(value);
  }

  static bool _isValidWebSocketUrl(String value) {
    if (_containsAsciiWhitespaceOrControl(value)) {
      return false;
    }
    final schemeSeparator = value.indexOf('://');
    if (schemeSeparator < 0) {
      return false;
    }
    final scheme = value.substring(0, schemeSeparator);
    if (scheme != 'ws' && scheme != 'wss') {
      return false;
    }
    final authorityAndSuffix = value.substring(schemeSeparator + 3);
    var authorityEnd = authorityAndSuffix.length;
    for (final delimiter in ['/', '?', '#']) {
      final delimiterIndex = authorityAndSuffix.indexOf(delimiter);
      if (delimiterIndex >= 0 && delimiterIndex < authorityEnd) {
        authorityEnd = delimiterIndex;
      }
    }
    final authority = authorityAndSuffix.substring(0, authorityEnd);
    if (authority.isEmpty ||
        authority.contains('@') ||
        authority.contains(r'\') ||
        authority.contains('%')) {
      return false;
    }
    if (authority.startsWith('[')) {
      return _isValidBracketedIpv6Authority(authority);
    }
    if (authority.contains('[') || authority.contains(']')) {
      return false;
    }
    return _isValidHostAuthority(authority);
  }

  static bool _containsAsciiWhitespaceOrControl(String value) {
    return value.codeUnits.any((code) => code <= 32 || code == 127);
  }

  static bool _isValidBracketedIpv6Authority(String authority) {
    final closingBracket = authority.indexOf(']');
    if (closingBracket <= 1) {
      return false;
    }
    final host = authority.substring(1, closingBracket);
    return _isValidIpv6(host) &&
        _isValidPortSuffix(authority.substring(closingBracket + 1));
  }

  static bool _isValidIpv6(String host) {
    if (!host.contains(':') || host.indexOf('::') != host.lastIndexOf('::')) {
      return false;
    }
    final hasCompressedGroups = host.contains('::');
    final rawGroups = host.split(':');
    if (!hasCompressedGroups && rawGroups.any((group) => group.isEmpty)) {
      return false;
    }
    final groups = rawGroups.where((group) => group.isNotEmpty).toList();
    if (hasCompressedGroups) {
      if (groups.length > 7) {
        return false;
      }
    } else if (groups.length != 8) {
      return false;
    }
    return groups.every(
      (group) => group.length <= 4 && RegExp(r'^[0-9a-fA-F]+$').hasMatch(group),
    );
  }

  static bool _isValidHostAuthority(String authority) {
    final portSeparator = authority.lastIndexOf(':');
    final host = portSeparator >= 0
        ? authority.substring(0, portSeparator)
        : authority;
    final portSuffix = portSeparator >= 0
        ? authority.substring(portSeparator)
        : '';
    return host.isNotEmpty &&
        !host.contains(':') &&
        _isValidHostnameOrIpv4(host) &&
        _isValidPortSuffix(portSuffix);
  }

  static bool _isValidHostnameOrIpv4(String host) {
    if (host.length > 253) {
      return false;
    }
    return _looksLikeIpv4(host) ? _isValidIpv4(host) : _isValidHostname(host);
  }

  static bool _looksLikeIpv4(String host) {
    return host.contains('.') && RegExp(r'^[0-9.]+$').hasMatch(host);
  }

  static bool _isValidIpv4(String host) {
    final octets = host.split('.');
    return octets.length == 4 &&
        octets.every(
          (octet) =>
              RegExp(r'^[0-9]{1,3}$').hasMatch(octet) &&
              int.parse(octet) <= 255,
        );
  }

  static bool _isValidHostname(String host) {
    return host.split('.').every((label) {
      return label.isNotEmpty &&
          label.length <= 63 &&
          RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$').hasMatch(label);
    });
  }

  static bool _isValidPortSuffix(String suffix) {
    if (suffix.isEmpty) {
      return true;
    }
    if (!suffix.startsWith(':')) {
      return false;
    }
    final port = suffix.substring(1);
    if (!RegExp(r'^[0-9]{1,5}$').hasMatch(port)) {
      return false;
    }
    final portNumber = int.parse(port);
    return portNumber >= 1 && portNumber <= 65535;
  }
}
