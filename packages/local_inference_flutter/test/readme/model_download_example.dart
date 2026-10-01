// The README's "Model download" example, verbatim: compiled by readme_examples_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

const download = BackgroundDownloadConfig(group: 'my_app_models', appName: 'Assistant');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LocalInferenceFlutter.installDownloaderStorage(download: download);
  final models = await LocalInferenceFlutter.createModelManager(
    catalog: ModelCatalog.bundled(
      () => rootBundle.loadString('assets/models/manifest.json'),
      remote: Uri.parse('https://example.org/models/manifest.json'),
    ),
    download: download,
  );
  runApp(MaterialApp(home: ModelsPage(models: models)));
  await models.init();
}

class ModelsPage extends StatelessWidget {
  const ModelsPage({super.key, required this.models});

  final ModelManager models;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListenableBuilder(
      listenable: ChangeSourceListenable(models),
      builder: (context, _) => ListView(
        children: [
          if (models.isReady)
            for (final entry in models.entries)
              ListTile(
                title: Text(entry.displayName),
                subtitle: Text(describe(entry)),
                onTap: () => models.download(entry.id),
              ),
        ],
      ),
    ),
  );

  String describe(ModelEntry entry) {
    const strings = ModelSetupStrings.english;
    const formats = LocalizedFormats.english;
    final problem = models.problemFor(entry);
    if (problem != null) return strings.problem(problem, formats);
    final status = models.statusOf(entry.id);
    final error = status.error;
    return switch (status.state) {
      ModelState.downloading => strings.tileDownloading(formats.percent(status.progress)),
      ModelState.failed when error != null => strings.error(error),
      ModelState.ready => strings.tileReady,
      _ => formats.bytes(entry.sizeBytes),
    };
  }
}
