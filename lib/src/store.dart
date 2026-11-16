import 'dart:async';
import 'dart:typed_data';

/// Where synced assets are kept: contents by hash (shared by every user and channel) and small JSON records
/// (listings, usage). On a device with a folder, files; otherwise (web, no folder) memory.
abstract interface class AssetStore {
  /// Whether this store keeps things across restarts.
  bool get durable;

  Future<bool> hasContent(String hash);

  Future<Uint8List?> readContent(String hash);

  /// A path to the content's bytes on this device, or null when the store isn't on disk.
  Future<String?> contentPath(String hash);

  /// Writes [bytes] as [hash]'s content; [verify] is called with what arrived before it's kept (throwing rejects it).
  Future<void> writeContent(String hash, Stream<List<int>> bytes, void Function(Uint8List? whole, String digest) verify);

  Future<void> deleteContent(String hash);

  /// Every content kept: hash → size.
  Future<Map<String, int>> contents();

  Future<Map<String, Object?>?> readRecord(String name);

  Future<void> writeRecord(String name, Map<String, Object?> record);

  Future<void> clear();
}
