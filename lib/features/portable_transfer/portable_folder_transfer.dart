import 'dart:io';
import '../../services/library_service.dart';
import 'portable_transfer_models.dart';
import 'portable_transfer_service.dart';

export 'portable_transfer_models.dart'
    show
        PortableFolderEstimate,
        PortablePreparedFolderPackage,
        PortableReceivedFolder,
        PortableFolderProgress,
        PortableFolderProtection,
        PortableFolderFingerprint,
        PortableFolderFiles,
        PortableFolderFile,
        PortableExportCancelled;

/// One-way folder delivery using the same verified fluentpack snapshot as export.
/// Progress synchronization remains the responsibility of the sync service.
class PortableFolderTransfer {
  PortableFolderTransfer({PortableTransferService? service})
    : _service = service ?? PortableTransferService.instance;

  final PortableTransferService _service;

  Future<PortableFolderFiles> prepareDirectFiles({
    required LibraryService library,
    required String collectionId,
    Set<String>? includeMediaIds,
    bool includeSidecars = true,
    Set<String> skipContentKeys = const {},
    Map<String, PortableFolderFingerprint> knownFingerprints = const {},
    bool Function()? isCancelled,
  }) => _service.prepareFolderTransferFiles(
    library: library,
    collectionId: collectionId,
    includeMediaIds: includeMediaIds,
    includeSidecars: includeSidecars,
    skipContentKeys: skipContentKeys,
    knownFingerprints: knownFingerprints,
    isCancelled: isCancelled,
  );

  Future<PortableFolderEstimate> estimateFolder({
    required LibraryService library,
    required String collectionId,
  }) => _service.estimateFolderTransfer(
    library: library,
    collectionId: collectionId,
  );

  Future<PortablePreparedFolderPackage> prepareFolderPackage({
    required LibraryService library,
    required String collectionId,
    required String outputPath,
    Set<String>? includeMediaIds,
    bool includeSidecars = true,
    Map<String, String> stableIds = const {},
    Map<String, dynamic> syncMetadata = const {},
    Set<String> skipContentKeys = const {},
    Map<String, PortableFolderFingerprint> knownFingerprints = const {},
    Future<void> Function(int payloadBytes)? onPayloadSize,
    PortableFolderProgress? onProgress,
    bool Function()? isCancelled,
  }) => _service.prepareFolderTransferPackage(
    library: library,
    collectionId: collectionId,
    outputPath: outputPath,
    includeMediaIds: includeMediaIds,
    includeSidecars: includeSidecars,
    stableIds: stableIds,
    syncMetadata: syncMetadata,
    skipContentKeys: skipContentKeys,
    knownFingerprints: knownFingerprints,
    onPayloadSize: onPayloadSize,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );

  Future<PortableReceivedFolder> importReceivedFolder({
    required LibraryService library,
    required String packagePath,
    required String originDeviceId,
    required String sourceCollectionId,
    Directory? receivedDirectory,
    Map<String, dynamic>? receivedManifest,
    Map<String, PortableFolderFingerprint> existingFingerprints = const {},
    String? existingTargetCollectionId,
    Map<String, String> stableIds = const {},
    Map<String, String> existingLocalIds = const {},
    Set<String> suppressedNodeIds = const {},
    Set<String> protectedNodeIds = const {},
    PortableFolderProtection? resolveProtectedNodeIds,
    Future<void> Function(int bytes)? beforeExtraLocalCopy,
    bool reconcileStructure = false,
    PortableFolderProgress? onProgress,
    bool Function()? isCancelled,
  }) => _service.importFolderTransferPackage(
    library: library,
    packagePath: packagePath,
    originDeviceId: originDeviceId,
    sourceCollectionId: sourceCollectionId,
    receivedDirectory: receivedDirectory,
    receivedManifest: receivedManifest,
    existingFingerprints: existingFingerprints,
    existingTargetCollectionId: existingTargetCollectionId,
    stableIds: stableIds,
    existingLocalIds: existingLocalIds,
    suppressedNodeIds: suppressedNodeIds,
    protectedNodeIds: protectedNodeIds,
    resolveProtectedNodeIds: resolveProtectedNodeIds,
    beforeExtraLocalCopy: beforeExtraLocalCopy,
    reconcileStructure: reconcileStructure,
    onProgress: onProgress,
    isCancelled: isCancelled,
  );
}
