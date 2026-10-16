/// On-device AI chat and agents for Flutter: a drop-in, customizable chat UI over an LLM that runs on the phone, with
/// tool calling, background model downloads and device checks. Offline and private.
///
/// Where to start: `LocalInferenceChat(config:, model:)` is a whole chat in one widget (the README's quick start).
///
/// The app's license page also lists the native libraries it bundles: the plugin registers their texts before
/// `main()` ([NativeLicenses]).
///
/// Re-exports local_inference, so a Flutter app lists only this package. Three ways to use it:
///  1. `LocalInferenceChat(config:, model:)`: one widget that makes, starts and disposes everything;
///  2. `ChatPage` / `ChatView` (no Scaffold) with `ModelSetupView`, `ModelLibrary` and `showModelPicker`, over an
///     `AssistantController` and a `ModelSetupController` the app keeps above its Navigator (`LocalInferenceScope`);
///  3. headless: the adapters' listenables (`AssistantController.itemIds`, `item(id)`, `composer`, `draft`), or the
///     core `Assistant.states` stream for Riverpod or BLoC.
/// The look, texts and switches: `LocalInferenceTheme`, `LocalInferenceStrings`, `ChatFeatures`, `ChatBuilders` (the
/// README, "Customizing").
library;

export 'package:local_inference/local_inference.dart';

export 'src/adapters/analytics.dart';
export 'src/adapters/assistant_controller.dart';
export 'src/adapters/change_source_listenable.dart';
export 'src/adapters/chat_scroll_controller.dart';
export 'src/adapters/model_manager_watcher.dart';
export 'src/adapters/model_setup_controller.dart';
export 'src/adapters/pick_setup_entry.dart';
export 'src/adapters/scope.dart';
export 'src/adapters/screen_request_dispatcher.dart';
export 'src/notices/native_licenses.dart';
export 'src/platform/background_model_downloader.dart';
export 'src/platform/device.dart';
export 'src/platform/diagnostics.dart';
export 'src/platform/download_config.dart' hide androidForegroundSetting;
export 'src/platform/factories.dart';
export 'src/platform/paths.dart';
export 'src/platform/retaining_resume_storage.dart';
export 'src/ui/builders.dart';
export 'src/ui/callbacks.dart';
export 'src/ui/chat/chat_view.dart';
export 'src/ui/chat/controls.dart';
export 'src/ui/chat/indicators.dart';
export 'src/ui/chat/local_inference_chat.dart';
export 'src/ui/chat/message_list.dart';
export 'src/ui/chat/message_parts.dart';
export 'src/ui/chat/message_text.dart';
export 'src/ui/chat/messages.dart';
export 'src/ui/chat/status_panel.dart' hide PanelIcon;
export 'src/ui/compliance/compliance.dart';
export 'src/ui/compliance/report.dart';
export 'src/ui/features.dart';
export 'src/ui/keys.dart';
export 'src/ui/l10n/a11y_strings.dart';
export 'src/ui/l10n/chat_strings.dart';
export 'src/ui/l10n/formats.dart';
export 'src/ui/l10n/setup_strings.dart';
export 'src/ui/l10n/strings.dart';
export 'src/ui/setup/model_library.dart';
export 'src/ui/setup/model_views.dart';
export 'src/ui/theme/local_inference_theme.dart';
export 'src/version.dart';
