/// A safe, actionable UI message; the original exception is retained for logs.
class AsrModelPreparationException implements Exception {
  const AsrModelPreparationException(
    this.message, {
    this.cause,
    this.isCancelled = false,
  });

  final String message;
  final Object? cause;
  final bool isCancelled;

  @override
  String toString() => message;
}
