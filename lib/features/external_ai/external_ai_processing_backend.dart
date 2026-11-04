abstract class ExternalAiProcessingBackend {
  Future<Map<String, dynamic>> modelStatus(List<String> ids);
  Future<Map<String, dynamic>> modelPreview(List<String> ids);
  Future<void> prepareModels(List<String> ids, void Function() guard);
  Future<Map<String, dynamic>> defaultsPreview(Map<String, dynamic> changes);
  Future<void> updateDefaults(
    Map<String, dynamic> changes,
    void Function() guard,
  );
}
