/// Test doubles for an app built on local_inference_flutter: local_inference's own (`ScriptedEngine`,
/// `scriptedAssistant`, `InMemoryPrefixStateStore`, the delivery fakes), so a test needs no other dependency. No
/// dependency on flutter_test; import it from tests only.
library;

export 'package:local_inference/testing.dart';
