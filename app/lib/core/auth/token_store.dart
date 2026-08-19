import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class TokenStore {
  Future<String?> readRefreshToken();

  Future<void> writeRefreshToken(String refreshToken);

  Future<void> deleteRefreshToken();
}

/// Android-backed storage for the sole long-lived client credential.
final class SecureTokenStore implements TokenStore {
  SecureTokenStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(),
    ),
  }) : _storage = storage;

  static const refreshTokenKey = 'gamebox.refresh_token.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<void> deleteRefreshToken() {
    return _storage.delete(key: refreshTokenKey);
  }

  @override
  Future<String?> readRefreshToken() {
    return _storage.read(key: refreshTokenKey);
  }

  @override
  Future<void> writeRefreshToken(String refreshToken) {
    if (refreshToken.isEmpty) {
      throw ArgumentError('Refresh token must not be empty');
    }
    return _storage.write(key: refreshTokenKey, value: refreshToken);
  }
}
