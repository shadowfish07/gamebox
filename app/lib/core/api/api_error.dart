/// A bounded, user-safe API failure.
///
/// Raw response bodies, status codes, request bodies, and credentials are
/// intentionally not retained.
final class ApiError implements Exception {
  const ApiError({required this.code, required this.message});

  final String code;
  final String message;

  @override
  String toString() => 'ApiError(code: $code)';
}
