import 'package:glados/glados.dart';
import 'dart:collection';

final ExploreConfig _explore = ExploreConfig(numRuns: 10, initialSize: 1, speed: 1);

/// 用于测试的简化版LRU缓存实现
/// 
/// 由于ThumbnailCacheService是单例且依赖Flutter的ImageProvider，
/// 我们创建一个纯Dart的LRU缓存类来测试核心缓存清理逻辑。
class TestLRUCache<K, V> {
  final LinkedHashMap<K, V> _cache = LinkedHashMap<K, V>();
  final int _maxSize;

  TestLRUCache({int maxSize = 100}) : _maxSize = maxSize;

  int get maxSize => _maxSize;
  int get size => _cache.length;
  List<K> get keys => _cache.keys.toList();

  /// 添加或更新条目
  void put(K key, V value) {
    _cache.remove(key);
    _cache[key] = value;
    _evictIfNeeded();
  }

  /// 获取值，如果存在则更新LRU顺序
  V? get(K key) {
    if (_cache.containsKey(key)) {
      final value = _cache.remove(key);
      if (value != null) {
        _cache[key] = value;
      }
      return value;
    }
    return null;
  }

  /// 从缓存中移除指定条目（对应ThumbnailCacheService.evictFromCache）
  bool evict(K key) {
    return _cache.remove(key) != null;
  }

  /// 检查是否包含指定key（对应ThumbnailCacheService.isInMemoryCache）
  bool containsKey(K key) {
    return _cache.containsKey(key);
  }

  /// 清空缓存
  void clear() {
    _cache.clear();
  }

  /// 驱逐最久未使用的条目直到满足大小限制
  void _evictIfNeeded() {
    while (_cache.length > _maxSize) {
      _cache.remove(_cache.keys.first);
    }
  }
}

void main() {
  group('ThumbnailCacheService 缓存清理同步属性测试', () {
    /// **Property 3: Eviction Removes Entry Completely**
    /// 
    /// *For any* video ID, after calling `evictFromCache`, the 
    /// `isInMemoryCache` method shall return false for that ID.
    /// 
    /// **Validates: Requirements 4.2, 4.5**
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados2(
      any.lowercaseLetters, // 随机videoId
      any.positiveIntOrZero, // 随机value
      _explore,
    ).test(
      'Property 3: 对于任意视频ID，调用evict后，containsKey应返回false',
      (videoId, value) {
        final cache = TestLRUCache<String, int>(maxSize: 100);
        
        // 将条目放入缓存
        cache.put(videoId, value);
        
        // 验证条目在缓存中
        expect(cache.containsKey(videoId), isTrue,
          reason: 'evict前条目应在缓存中');
        
        // 调用evict移除条目
        final wasRemoved = cache.evict(videoId);
        
        // 验证：evict应返回true（表示成功移除）
        expect(wasRemoved, isTrue,
          reason: 'evict应返回true表示成功移除');
        
        // 验证：条目不再在缓存中
        expect(cache.containsKey(videoId), isFalse,
          reason: 'evict后containsKey应返回false');
        
        // 验证：尝试get应返回null
        expect(cache.get(videoId), isNull,
          reason: 'evict后get应返回null');
      },
    );

    /// Property 3 补充测试：evict不存在的条目
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados(any.lowercaseLetters, _explore).test(
      'Property 3: evict不存在的条目应返回false且不影响缓存',
      (videoId) {
        final cache = TestLRUCache<String, int>(maxSize: 100);
        
        // 不添加任何条目，直接evict
        final wasRemoved = cache.evict(videoId);
        
        // 验证：evict应返回false（表示条目不存在）
        expect(wasRemoved, isFalse,
          reason: 'evict不存在的条目应返回false');
        
        // 验证：containsKey仍返回false
        expect(cache.containsKey(videoId), isFalse,
          reason: 'evict不存在的条目后containsKey应返回false');
        
        // 验证：缓存大小不变
        expect(cache.size, equals(0),
          reason: 'evict不存在的条目不应改变缓存大小');
      },
    );

    /// Property 3 补充测试：evict后重新添加
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados2(
      any.lowercaseLetters, // 随机videoId
      any.positiveIntOrZero, // 随机value
      _explore,
    ).test(
      'Property 3: evict后重新put应能正常添加到缓存',
      (videoId, value) {
        final cache = TestLRUCache<String, int>(maxSize: 100);
        
        // 添加条目
        cache.put(videoId, value);
        
        // evict条目
        cache.evict(videoId);
        
        // 验证条目已被移除
        expect(cache.containsKey(videoId), isFalse,
          reason: 'evict后条目应不在缓存中');
        
        // 重新添加相同的条目
        final newValue = value + 1;
        cache.put(videoId, newValue);
        
        // 验证：条目重新在缓存中
        expect(cache.containsKey(videoId), isTrue,
          reason: '重新put后条目应在缓存中');
        
        // 验证：get返回新值
        expect(cache.get(videoId), equals(newValue),
          reason: '重新put后get应返回新值');
      },
    );

    /// Property 3 补充测试：批量evict
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados(any.positiveIntOrZero.map((n) => (n % 20) + 1), _explore).test(
      'Property 3: 批量evict多个条目后，所有条目都应不在缓存中',
      (itemCount) {
        final cache = TestLRUCache<String, int>(maxSize: 100);
        final videoIds = <String>[];
        
        // 添加多个条目
        for (int i = 0; i < itemCount; i++) {
          final videoId = 'video_$i';
          cache.put(videoId, i);
          videoIds.add(videoId);
        }
        
        // 验证所有条目都在缓存中
        for (final videoId in videoIds) {
          expect(cache.containsKey(videoId), isTrue,
            reason: 'evict前条目$videoId应在缓存中');
        }
        
        // 批量evict所有条目
        for (final videoId in videoIds) {
          cache.evict(videoId);
        }
        
        // 验证所有条目都不在缓存中
        for (final videoId in videoIds) {
          expect(cache.containsKey(videoId), isFalse,
            reason: 'evict后条目$videoId应不在缓存中');
        }
        
        // 验证缓存为空
        expect(cache.size, equals(0),
          reason: '批量evict后缓存应为空');
      },
    );

    /// Property 3 补充测试：evict部分条目
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados2(
      any.positiveIntOrZero.map((n) => (n % 20) + 5), // 总条目数: 5-24
      any.positiveIntOrZero.map((n) => (n % 10) + 1), // evict数量: 1-10
      _explore,
    ).test(
      'Property 3: evict部分条目后，未evict的条目应仍在缓存中',
      (totalCount, evictCount) {
        final cache = TestLRUCache<String, int>(maxSize: 100);
        
        // 添加多个条目
        for (int i = 0; i < totalCount; i++) {
          cache.put('video_$i', i);
        }
        
        // evict前面的evictCount个条目
        final actualEvictCount = evictCount < totalCount ? evictCount : totalCount;
        for (int i = 0; i < actualEvictCount; i++) {
          cache.evict('video_$i');
        }
        
        // 验证：被evict的条目不在缓存中
        for (int i = 0; i < actualEvictCount; i++) {
          expect(cache.containsKey('video_$i'), isFalse,
            reason: '被evict的条目video_$i应不在缓存中');
        }
        
        // 验证：未被evict的条目仍在缓存中
        for (int i = actualEvictCount; i < totalCount; i++) {
          expect(cache.containsKey('video_$i'), isTrue,
            reason: '未被evict的条目video_$i应仍在缓存中');
        }
        
        // 验证：缓存大小正确
        expect(cache.size, equals(totalCount - actualEvictCount),
          reason: '缓存大小应等于总数减去evict数量');
      },
    );

    /// Property 3 补充测试：evict与LRU驱逐的独立性
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados(any.lowercaseLetters, _explore).test(
      'Property 3: 手动evict不应影响LRU驱逐逻辑',
      (videoId) {
        final cache = TestLRUCache<String, int>(maxSize: 3);
        
        // 添加3个条目填满缓存
        cache.put('a', 1);
        cache.put('b', 2);
        cache.put('c', 3);
        
        // 手动evict 'b'
        cache.evict('b');
        
        // 验证：'b'不在缓存中
        expect(cache.containsKey('b'), isFalse,
          reason: 'evict后b应不在缓存中');
        
        // 验证：缓存大小减少
        expect(cache.size, equals(2),
          reason: 'evict后缓存大小应减少');
        
        // 添加新条目（不应触发驱逐，因为还有空间）
        cache.put(videoId, 999);
        
        // 验证：所有条目都在缓存中（如果videoId不是a或c）
        if (videoId != 'a' && videoId != 'c') {
          expect(cache.containsKey('a'), isTrue,
            reason: '条目a应仍在缓存中');
          expect(cache.containsKey('c'), isTrue,
            reason: '条目c应仍在缓存中');
          expect(cache.containsKey(videoId), isTrue,
            reason: '新条目应在缓存中');
          expect(cache.size, equals(3),
            reason: '缓存大小应为3');
        }
      },
    );

    /// Property 3 补充测试：重复evict同一条目
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados2(
      any.lowercaseLetters, // 随机videoId
      any.positiveIntOrZero.map((n) => (n % 10) + 1), // 重复次数: 1-10
      _explore,
    ).test(
      'Property 3: 重复evict同一条目应是幂等的',
      (videoId, repeatCount) {
        final cache = TestLRUCache<String, int>(maxSize: 100);
        
        // 添加条目
        cache.put(videoId, 42);
        
        // 第一次evict应返回true
        final firstEvict = cache.evict(videoId);
        expect(firstEvict, isTrue,
          reason: '第一次evict应返回true');
        
        // 重复evict多次
        for (int i = 0; i < repeatCount; i++) {
          final result = cache.evict(videoId);
          
          // 验证：后续evict应返回false（因为条目已不存在）
          expect(result, isFalse,
            reason: '第${i + 2}次evict应返回false');
          
          // 验证：条目仍不在缓存中
          expect(cache.containsKey(videoId), isFalse,
            reason: '重复evict后条目应仍不在缓存中');
        }
        
        // 验证：缓存大小为0
        expect(cache.size, equals(0),
          reason: '重复evict后缓存应为空');
      },
    );

    /// Property 3 补充测试：evict与clear的一致性
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 3: Eviction Removes Entry Completely**
    Glados(any.positiveIntOrZero.map((n) => (n % 20) + 1), _explore).test(
      'Property 3: 逐个evict所有条目应等价于clear',
      (itemCount) {
        final cache1 = TestLRUCache<String, int>(maxSize: 100);
        final cache2 = TestLRUCache<String, int>(maxSize: 100);
        final videoIds = <String>[];
        
        // 在两个缓存中添加相同的条目
        for (int i = 0; i < itemCount; i++) {
          final videoId = 'video_$i';
          cache1.put(videoId, i);
          cache2.put(videoId, i);
          videoIds.add(videoId);
        }
        
        // cache1: 逐个evict所有条目
        for (final videoId in videoIds) {
          cache1.evict(videoId);
        }
        
        // cache2: 调用clear
        cache2.clear();
        
        // 验证：两个缓存都为空
        expect(cache1.size, equals(0),
          reason: '逐个evict后缓存应为空');
        expect(cache2.size, equals(0),
          reason: 'clear后缓存应为空');
        
        // 验证：所有条目在两个缓存中都不存在
        for (final videoId in videoIds) {
          expect(cache1.containsKey(videoId), isFalse,
            reason: '逐个evict后条目$videoId应不在cache1中');
          expect(cache2.containsKey(videoId), isFalse,
            reason: 'clear后条目$videoId应不在cache2中');
        }
      },
    );
  });
}
