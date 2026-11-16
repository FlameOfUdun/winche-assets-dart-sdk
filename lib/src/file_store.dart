import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'memory_store.dart';
import 'store.dart';

/// Assets in [root] (`contents/<hash>`, `records/<name>.json`): kept across restarts, written whole then moved
/// into place, so a crash never leaves half a file under a hash.
final class FileAssetStore implements AssetStore {
  FileAssetStore(String root) : _root = Directory(root);

  final Directory _root;
  var _writes = 0;

  File _content(String hash) => File('${_root.path}/contents/$hash');
  File _record(String name) => File('${_root.path}/records/${Uri.encodeComponent(name)}.json');

  @override
  bool get durable => true;

  @override
  Future<bool> hasContent(String hash) => _content(hash).exists();

  @override
  Future<Uint8List?> readContent(String hash) async {
    final f = _content(hash);
    return await f.exists() ? f.readAsBytes() : null;
  }

  @override
  Future<String?> contentPath(String hash) async {
    final f = _content(hash);
    return await f.exists() ? f.path : null;
  }

  @override
  Future<void> writeContent(String hash, Stream<List<int>> bytes, void Function(Uint8List? whole, String digest) verify) async {
    final target = _content(hash);
    await target.parent.create(recursive: true);
    final temp = File('${target.path}.${DateTime.now().microsecondsSinceEpoch}.part');
    final sink = temp.openWrite();
    final digests = _DigestSink();
    final hashing = sha256.startChunkedConversion(digests);
    try {
      await for (final chunk in bytes) {
        hashing.add(chunk);
        sink.add(chunk);
      }
      hashing.close();
      await sink.close();
      verify(null, digests.value.toString());
      await temp.rename(target.path);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  @override
  Future<void> deleteContent(String hash) async {
    final f = _content(hash);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<Map<String, int>> contents() async {
    final dir = Directory('${_root.path}/contents');
    if (!await dir.exists()) return {};
    final out = <String, int>{};
    await for (final e in dir.list()) {
      if (e is File && !e.path.endsWith('.part')) out[e.uri.pathSegments.last] = await e.length();
    }
    return out;
  }

  @override
  Future<Map<String, Object?>?> readRecord(String name) async {
    final f = _record(name);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString()) as Map<String, Object?>;
    } on FormatException {
      return null;   // a torn write from an older version: as if it weren't there
    }
  }

  @override
  Future<void> writeRecord(String name, Map<String, Object?> record) async {
    final f = _record(name);
    await f.parent.create(recursive: true);
    final temp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}-${_writes++}.tmp');   // its own: writes may overlap
    await temp.writeAsString(jsonEncode(record), flush: true);
    await temp.rename(f.path);
  }

  @override
  Future<void> clear() async {
    if (await _root.exists()) await _root.delete(recursive: true);
  }
}

final class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

/// A store for [root], or memory without one.
AssetStore openAssetStore(String? root) => root == null ? MemoryAssetStore() : FileAssetStore(root);
