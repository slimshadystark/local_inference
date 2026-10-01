/// Which model the first-launch setup is about.
library;

import 'package:local_inference/local_inference.dart';

/// Chooses the model the setup shows; see [pickSetupEntry].
typedef SetupEntryPicker = ModelEntry? Function(ModelManager manager, String? chosenId);

/// The model the first-launch screens are about, from a ready [manager]. A download already under way comes first
/// (the one the user chose, else any: restored after a relaunch, or started before the memory reading moved the
/// recommendation), since offering another model would start a second one. Then one that failed, whose view offers
/// "Retry". Then the one the user chose ([chosenId]), the one recommended for this device, and when no model fits
/// the device the least demanding one, whose consent view says why with its button off.
ModelEntry? pickSetupEntry(ModelManager manager, String? chosenId) {
  bool downloading(ModelEntry entry) => manager.statusOf(entry.id).isActive;
  bool failed(ModelEntry entry) => manager.statusOf(entry.id).state == ModelState.failed;
  final chosen = chosenId == null ? null : manager.entryFor(chosenId);
  final leastDemanding =
      [
        for (final entry in manager.entries)
          if (entry.isActive) entry,
      ]..sort(
        (a, b) => a.minPhysicalRamMB != b.minPhysicalRamMB
            ? a.minPhysicalRamMB.compareTo(b.minPhysicalRamMB)
            : a.minAvailableMemoryMB.compareTo(b.minAvailableMemoryMB),
      );
  return (chosen != null && (downloading(chosen) || failed(chosen)) ? chosen : null) ??
      manager.entries.where(downloading).firstOrNull ??
      manager.entries.where(failed).firstOrNull ??
      chosen ??
      manager.recommended ??
      leastDemanding.firstOrNull;
}
