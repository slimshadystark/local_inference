/// The failures the engine reports. Misuse (a call after dispose, a second load) throws [StateError] instead.
library;

/// A failure of the model, the runtime or a state file.
sealed class LocalInferenceException implements Exception {
  const LocalInferenceException(this.message, {this.cause});

  /// What failed.
  final String message;

  /// The underlying error, when there is one (a runtime exception, a file error).
  final Object? cause;

  String get _kind;

  @override
  String toString() => cause == null ? '$_kind: $message' : '$_kind: $message ($cause)';
}

/// The model file could not be loaded.
final class ModelLoadException extends LocalInferenceException {
  const ModelLoadException(super.message, {super.cause});

  @override
  String get _kind => 'ModelLoadException';
}

/// The model loaded, but cannot be used as asked (no chat template, a template not accepted, no tool-call format).
final class UnsupportedModelException extends LocalInferenceException {
  const UnsupportedModelException(super.message, {super.cause});

  @override
  String get _kind => 'UnsupportedModelException';
}

/// A generation failed; its text stream carries the same error.
final class GenerationException extends LocalInferenceException {
  const GenerationException(super.message, {super.cause});

  @override
  String get _kind => 'GenerationException';
}

/// A state file could not be written or read back.
final class StateFileException extends LocalInferenceException {
  const StateFileException(super.message, {super.cause});

  @override
  String get _kind => 'StateFileException';
}
