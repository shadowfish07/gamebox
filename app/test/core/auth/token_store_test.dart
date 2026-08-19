import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gamebox/core/auth/token_store.dart';

void main() {
  test('malformed stored credential is classified as local corruption', () {
    final storage = _ReadStorage('refresh token with spaces');
    final store = SecureTokenStore(storage: storage);

    expect(
      store.readRefreshToken(),
      throwsA(
        isA<TokenStoreException>().having(
          (error) => error.kind,
          'kind',
          TokenStoreFailureKind.corrupt,
        ),
      ),
    );
    expect(storage.key, SecureTokenStore.refreshTokenKey);
  });

  test('decryption failure is classified as local corruption and redacted', () {
    const secret = 'secret-platform-diagnostic';
    final store = SecureTokenStore(
      storage: _ReadStorage(
        PlatformException(
          code: 'Exception encountered',
          message: 'BadPaddingException: $secret',
        ),
      ),
    );

    expect(
      store.readRefreshToken(),
      throwsA(
        isA<TokenStoreException>()
            .having(
              (error) => error.kind,
              'kind',
              TokenStoreFailureKind.corrupt,
            )
            .having(
              (error) => error.toString(),
              'diagnostics',
              isNot(contains(secret)),
            ),
      ),
    );
  });

  test('temporary platform storage failure remains retryable', () {
    final store = SecureTokenStore(
      storage: _ReadStorage(
        PlatformException(
          code: 'Exception encountered',
          message: 'storage service temporarily unavailable',
        ),
      ),
    );

    expect(
      store.readRefreshToken(),
      throwsA(
        isA<TokenStoreException>().having(
          (error) => error.kind,
          'kind',
          TokenStoreFailureKind.unavailable,
        ),
      ),
    );
  });
}

final class _ReadStorage extends FlutterSecureStorage {
  _ReadStorage(this.result);

  final Object? result;
  String? key;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    this.key = key;
    final value = result;
    if (value is Exception) {
      throw value;
    }
    return value as String?;
  }
}
