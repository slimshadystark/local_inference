// path_provider's Application Support and caches folders, set by the test.
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakePathProvider extends Fake with MockPlatformInterfaceMixin implements PathProviderPlatform {
  FakePathProvider(this.support, this.caches);

  final String support;
  final String caches;

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getApplicationCachePath() async => caches;
}
