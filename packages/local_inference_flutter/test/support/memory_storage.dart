// RetainingResumeStorage over a map instead of LocalStore (which needs the platform), so its copies run on the host:
// [live] is background_downloader's resume data, the copies go to the retained groups' folders as in the app.
import 'package:background_downloader/background_downloader.dart';
import 'package:local_inference_flutter/local_inference_flutter.dart';

class MemoryStorage extends RetainingResumeStorage {
  /// background_downloader's own resume data, by task id.
  final live = <String, ResumeData>{};

  /// The task ids whose resume data background_downloader removed (null: all).
  final removed = <String?>[];

  @override
  Future<void> initializeStore() async {}

  @override
  Future<ResumeData?> retrieveResumeData(String taskId) async => live[taskId];

  @override
  Future<List<ResumeData>> retrieveAllResumeData() async => List.of(live.values);

  @override
  Future<void> storeResumeData(ResumeData resumeData) async => live[resumeData.taskId] = resumeData;

  @override
  Future<void> removeStoredResumeData(String? taskId) async {
    removed.add(taskId);
    if (taskId == null) {
      live.clear();
    } else {
      live.remove(taskId);
    }
  }
}
