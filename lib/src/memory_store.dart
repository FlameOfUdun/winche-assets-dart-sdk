import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'store.dart';

/// Assets in memory: gone when the app stops (the web, or no folder given).
final class MemoryAssetStore implements AssetStore {
  final _contents = <String, Uint8List>{};
  final _records = <String, Map<String, Object?>>{};

  @override
  bool get durable => false;

  @override
  Future<bool> hasContent(String hash) async => _contents.containsKey(hash);

  @override
  Future<Uint8List?> readContent(String hash) async => _contents[hash];

  @override
  Future<String?> contentPath(String hash) async => null;

  @override
  Future<void> writeContent(String hash, Stream<List<int>> bytes, void Function(Uint8List? whole, String digest) verify) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      builder.add(chunk);
    }
    final whole = builder.takeBytes();
    verify(whole, sha256.convert(whole).toString());
    _contents[hash] = whole;
  }

  @override
  Future<void> deleteContent(String hash) async => _contents.remove(hash);

  @override
  Future<Map<String, int>> contents() async => {for (final e in _contents.entries) e.key: e.value.length};

  @override
  Future<Map<String, Object?>?> readRecord(String name) async => _records[name];

  @override
  Future<void> writeRecord(String name, Map<String, Object?> record) async => _records[name] = record;

  @override
  Future<void> clear() async {
    _contents.clear();
    _records.clear();
  }
}
