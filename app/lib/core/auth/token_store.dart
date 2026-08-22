import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';

enum TokenStoreFailureKind { unavailable, corrupt }

final class TokenStoreException implements Exception {
  const TokenStoreException.unavailable()
    : kind = TokenStoreFailureKind.unavailable;

  const TokenStoreException.corrupt() : kind = TokenStoreFailureKind.corrupt;

  final TokenStoreFailureKind kind;

  @override
  String toString() => 'TokenStoreException(${kind.name})';
}

abstract interface class TokenStore {
  Future<String?> readRefreshToken();

  Future<void> writeRefreshToken(String refreshToken);

  Future<void> deleteRefreshToken();
}

/// Android-backed storage for the sole long-lived client credential.
final class SecureTokenStore implements TokenStore {
  SecureTokenStore({
    this._storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(resetOnError: false),
    ),
  });

  static const refreshTokenKey = 'gamebox.refresh_token.v1';

  final FlutterSecureStorage _storage;

  @override
  Future<void> deleteRefreshToken() async {
    try {
      await _storage.delete(key: refreshTokenKey);
    } catch (_) {
      throw const TokenStoreException.unavailable();
    }
  }

  @override
  Future<String?> readRefreshToken() async {
    try {
      final value = await _storage.read(key: refreshTokenKey);
      if (value != null && !_isCredential(value)) {
        throw const TokenStoreException.corrupt();
      }
      return value;
    } on TokenStoreException {
      rethrow;
    } on PlatformException catch (error) {
      if (_isCorruptStorageFailure(error)) {
        throw const TokenStoreException.corrupt();
      }
      throw const TokenStoreException.unavailable();
    } catch (_) {
      throw const TokenStoreException.unavailable();
    }
  }

  @override
  Future<void> writeRefreshToken(String refreshToken) async {
    if (!_isCredential(refreshToken)) {
      throw ArgumentError('Refresh token must not be empty');
    }
    try {
      await _storage.write(key: refreshTokenKey, value: refreshToken);
    } catch (_) {
      throw const TokenStoreException.unavailable();
    }
  }

  static bool _isCredential(String value) =>
      value.isNotEmpty &&
      value.length <= 4096 &&
      value.codeUnits.every((unit) => unit >= 0x21 && unit <= 0x7e);

  static bool _isCorruptStorageFailure(PlatformException error) {
    final diagnostic = '${error.message ?? ''}\n${error.details ?? ''}';
    return const [
      'AEADBadTagException',
      'BadPaddingException',
      'IllegalBlockSizeException',
      'InvalidKeyException',
      'UnrecoverableKeyException',
      'bad base-64',
      'android.util.Base64',
      'Failed to decrypt',
      'Key mismatch after algorithm change',
      'Migration failed after algorithm change',
    ].any(diagnostic.contains);
  }
}
