/// Every text of the UI kit in one value, Italian and English built in, and its LocalizationsDelegate.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../adapters/scope.dart';
import '../internal/resolved.dart';
import 'a11y_strings.dart';
import 'chat_strings.dart';
import 'formats.dart';
import 'setup_strings.dart';

/// The UI kit's texts: the chat's, the model setup's, what screen readers say, and the number formats. Conversation
/// text (replies, questions, Yes and No, tool labels) comes from the assistant's config and is never translated here.
@immutable
final class LocalInferenceStrings {
  const LocalInferenceStrings({required this.chat, required this.setup, required this.a11y, required this.formats});

  /// Italian.
  static const italian = LocalInferenceStrings(
    chat: ChatStrings.italian,
    setup: ModelSetupStrings.italian,
    a11y: A11yStrings.italian,
    formats: LocalizedFormats.italian,
  );

  /// English.
  static const english = LocalInferenceStrings(
    chat: ChatStrings.english,
    setup: ModelSetupStrings.english,
    a11y: A11yStrings.english,
    formats: LocalizedFormats.english,
  );

  final ChatStrings chat;
  final ModelSetupStrings setup;
  final A11yStrings a11y;
  final LocalizedFormats formats;

  /// [italian] for an Italian locale, [english] for any other.
  static LocalInferenceStrings forLocale(Locale locale) => locale.languageCode == 'it' ? italian : english;

  /// The texts at [context]: [override]; else the enclosing chat view's; else the scope's
  /// (`LocalInferenceScope(strings:)`), else [LocalInferenceLocalizations.delegate]'s, else [forLocale] of the
  /// app's locale (English without one). The scope's `stringsOverride` then applies to all but [override].
  static LocalInferenceStrings of(BuildContext context, [LocalInferenceStrings? override]) {
    if (override != null) return override;
    final resolved = ResolvedLook.maybeOf(context);
    if (resolved != null) return resolved.strings;
    final scope = LocalInferenceScope.maybeOf(context);
    final strings =
        scope?.strings ??
        Localizations.of<LocalInferenceStrings>(context, LocalInferenceStrings) ??
        forLocale(Localizations.maybeLocaleOf(context) ?? const Locale('en'));
    return scope?.stringsOverride?.call(strings) ?? strings;
  }

  LocalInferenceStrings copyWith({
    ChatStrings? chat,
    ModelSetupStrings? setup,
    A11yStrings? a11y,
    LocalizedFormats? formats,
  }) => LocalInferenceStrings(
    chat: chat ?? this.chat,
    setup: setup ?? this.setup,
    a11y: a11y ?? this.a11y,
    formats: formats ?? this.formats,
  );
}

/// The UI kit's texts for `MaterialApp.localizationsDelegates`: Italian for `it`, English for `en`.
abstract final class LocalInferenceLocalizations {
  static const LocalizationsDelegate<LocalInferenceStrings> delegate = _Delegate();

  static const List<Locale> supportedLocales = [Locale('it'), Locale('en')];
}

final class _Delegate extends LocalizationsDelegate<LocalInferenceStrings> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => const ['it', 'en'].contains(locale.languageCode);

  @override
  Future<LocalInferenceStrings> load(Locale locale) => SynchronousFuture(LocalInferenceStrings.forLocale(locale));

  @override
  bool shouldReload(covariant LocalizationsDelegate<LocalInferenceStrings> old) => false;
}
