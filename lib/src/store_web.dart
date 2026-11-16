import 'memory_store.dart';
import 'store.dart';

/// On the web assets are kept in memory: there's no folder (a reload syncs again).
AssetStore openAssetStore(String? root) => MemoryAssetStore();
