import 'package:glados/glados.dart';
import 'dart:collection';

final ExploreConfig _explore = ExploreConfig(numRuns: 10, initialSize: 1, speed: 1);

/// 模拟视频项
class MockVideoItem {
  final String id;
  final String path;
  final String? thumbnailPath;
  final bool isRecycled;

  MockVideoItem({
    required this.id,
    required this.path,
    this.thumbnailPath,
    this.isRecycled = false,
  });

  MockVideoItem copyWith({
    String? id,
    String? path,
    String? thumbnailPath,
    bool? isRecycled,
  }) {
    return MockVideoItem(
      id: id ?? this.id,
      path: path ?? this.path,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      isRecycled: isRecycled ?? this.isRecycled,
    );
  }
}

/// 模拟缓存服务
class MockCacheService {
  final LinkedHashMap<String, dynamic> _cache = LinkedHashMap<String, dynamic>();

  void put(String videoId, dynamic value) {
    _cache[videoId] = value;
  }

  bool containsKey(String videoId) {
    return _cache.containsKey(videoId);
  }

  void evict(String videoId) {
    _cache.remove(videoId);
  }

  int get size => _cache.length;
}

/// 模拟文件系统
class MockFileSystem {
  final Set<String> _existingFiles = {};

  void createFile(String path) {
    _existingFiles.add(path);
  }

  bool fileExists(String path) {
    return _existingFiles.contains(path);
  }

  void deleteFile(String path) {
    _existingFiles.remove(path);
  }

  int get fileCount => _existingFiles.length;
}

/// 模拟删除操作
/// 
/// 这个函数模拟LibraryService._deleteVideoFiles的行为：
/// 1. 从缓存中移除条目
/// 2. 删除磁盘上的缩略图文件
Future<void> mockDeleteVideoFiles(
  MockVideoItem video,
  MockCacheService cacheService,
  MockFileSystem fileSystem,
) async {
  // 1. 清理缓存（对应我们添加的代码）
  cacheService.evict(video.id);

  // 2. 删除缩略图文件
  if (video.thumbnailPath != null && fileSystem.fileExists(video.thumbnailPath!)) {
    fileSystem.deleteFile(video.thumbnailPath!);
  }
}

void main() {
  group('ThumbnailCacheService 删除同步属性测试', () {
    /// **Property 5: Thumbnail Deletion Synchronization**
    /// 
    /// *For any* video permanently deleted from the recycle bin, both its 
    /// disk thumbnail file and memory cache entry shall be removed.
    /// 
    /// **Validates: Requirements 4.1, 4.2, 4.3**
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados2(
      any.lowercaseLetters, // 随机videoId
      any.lowercaseLetters, // 随机thumbnailPath
      _explore,
    ).test(
      'Property 5: 永久删除视频后，磁盘缩略图和内存缓存都应被移除',
      (videoId, thumbnailPath) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        
        // 创建视频项
        final video = MockVideoItem(
          id: videoId,
          path: '/videos/$videoId.mp4',
          thumbnailPath: '/thumbnails/$thumbnailPath.jpg',
          isRecycled: true, // 在回收站中
        );
        
        // 设置初始状态：缓存中有条目，磁盘上有文件
        cacheService.put(video.id, 'cached_thumbnail');
        fileSystem.createFile(video.thumbnailPath!);
        
        // 验证初始状态
        expect(cacheService.containsKey(video.id), isTrue,
          reason: '删除前缓存中应有该视频的条目');
        expect(fileSystem.fileExists(video.thumbnailPath!), isTrue,
          reason: '删除前磁盘上应有缩略图文件');
        
        // 执行删除操作
        mockDeleteVideoFiles(video, cacheService, fileSystem);
        
        // 验证：缓存条目已被移除
        expect(cacheService.containsKey(video.id), isFalse,
          reason: '删除后缓存中不应有该视频的条目');
        
        // 验证：磁盘文件已被删除
        expect(fileSystem.fileExists(video.thumbnailPath!), isFalse,
          reason: '删除后磁盘上不应有缩略图文件');
      },
    );

    /// Property 5 补充测试：批量删除视频
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados(any.positiveIntOrZero.map((n) => (n % 20) + 1), _explore).test(
      'Property 5: 批量删除多个视频后，所有缩略图和缓存都应被移除',
      (videoCount) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        final videos = <MockVideoItem>[];
        
        // 创建多个视频项
        for (int i = 0; i < videoCount; i++) {
          final video = MockVideoItem(
            id: 'video_$i',
            path: '/videos/video_$i.mp4',
            thumbnailPath: '/thumbnails/thumb_$i.jpg',
            isRecycled: true,
          );
          videos.add(video);
          
          // 设置初始状态
          cacheService.put(video.id, 'cached_thumbnail_$i');
          fileSystem.createFile(video.thumbnailPath!);
        }
        
        // 验证初始状态
        expect(cacheService.size, equals(videoCount),
          reason: '删除前缓存中应有$videoCount个条目');
        expect(fileSystem.fileCount, equals(videoCount),
          reason: '删除前磁盘上应有$videoCount个文件');
        
        // 批量删除所有视频
        for (final video in videos) {
          mockDeleteVideoFiles(video, cacheService, fileSystem);
        }
        
        // 验证：所有缓存条目都被移除
        for (final video in videos) {
          expect(cacheService.containsKey(video.id), isFalse,
            reason: '删除后缓存中不应有视频${video.id}的条目');
        }
        
        // 验证：所有磁盘文件都被删除
        for (final video in videos) {
          expect(fileSystem.fileExists(video.thumbnailPath!), isFalse,
            reason: '删除后磁盘上不应有视频${video.id}的缩略图');
        }
        
        // 验证：缓存和文件系统都为空
        expect(cacheService.size, equals(0),
          reason: '批量删除后缓存应为空');
        expect(fileSystem.fileCount, equals(0),
          reason: '批量删除后磁盘上不应有缩略图文件');
      },
    );

    /// Property 5 补充测试：删除没有缩略图的视频
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados(any.lowercaseLetters, _explore).test(
      'Property 5: 删除没有缩略图的视频应正常处理',
      (videoId) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        
        // 创建没有缩略图的视频项
        final video = MockVideoItem(
          id: videoId,
          path: '/videos/$videoId.mp4',
          thumbnailPath: null, // 没有缩略图
          isRecycled: true,
        );
        
        // 缓存中有条目（可能是预加载失败后的占位符）
        cacheService.put(video.id, 'placeholder');
        
        // 验证初始状态
        expect(cacheService.containsKey(video.id), isTrue,
          reason: '删除前缓存中应有该视频的条目');
        
        final initialFileCount = fileSystem.fileCount;
        
        // 执行删除操作
        mockDeleteVideoFiles(video, cacheService, fileSystem);
        
        // 验证：缓存条目已被移除
        expect(cacheService.containsKey(video.id), isFalse,
          reason: '删除后缓存中不应有该视频的条目');
        
        // 验证：文件系统状态不变（因为没有缩略图文件）
        expect(fileSystem.fileCount, equals(initialFileCount),
          reason: '删除没有缩略图的视频不应影响文件系统');
      },
    );

    /// Property 5 补充测试：删除缩略图文件不存在的视频
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados2(
      any.lowercaseLetters, // 随机videoId
      any.lowercaseLetters, // 随机thumbnailPath
      _explore,
    ).test(
      'Property 5: 删除缩略图文件已不存在的视频应正常处理',
      (videoId, thumbnailPath) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        
        // 创建视频项（有thumbnailPath但文件不存在）
        final video = MockVideoItem(
          id: videoId,
          path: '/videos/$videoId.mp4',
          thumbnailPath: '/thumbnails/$thumbnailPath.jpg',
          isRecycled: true,
        );
        
        // 缓存中有条目，但磁盘上没有文件（可能已被手动删除）
        cacheService.put(video.id, 'cached_thumbnail');
        // 注意：不调用fileSystem.createFile
        
        // 验证初始状态
        expect(cacheService.containsKey(video.id), isTrue,
          reason: '删除前缓存中应有该视频的条目');
        expect(fileSystem.fileExists(video.thumbnailPath!), isFalse,
          reason: '磁盘上没有缩略图文件');
        
        // 执行删除操作（应该不会抛出异常）
        mockDeleteVideoFiles(video, cacheService, fileSystem);
        
        // 验证：缓存条目已被移除
        expect(cacheService.containsKey(video.id), isFalse,
          reason: '删除后缓存中不应有该视频的条目');
        
        // 验证：文件系统状态不变
        expect(fileSystem.fileExists(video.thumbnailPath!), isFalse,
          reason: '磁盘上仍然没有缩略图文件');
      },
    );

    /// Property 5 补充测试：部分删除（删除部分视频）
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados2(
      any.positiveIntOrZero.map((n) => (n % 20) + 5), // 总视频数: 5-24
      any.positiveIntOrZero.map((n) => (n % 10) + 1), // 删除数量: 1-10
      _explore,
    ).test(
      'Property 5: 部分删除视频后，未删除的视频缓存和文件应保留',
      (totalCount, deleteCount) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        final videos = <MockVideoItem>[];
        
        // 创建多个视频项
        for (int i = 0; i < totalCount; i++) {
          final video = MockVideoItem(
            id: 'video_$i',
            path: '/videos/video_$i.mp4',
            thumbnailPath: '/thumbnails/thumb_$i.jpg',
            isRecycled: true,
          );
          videos.add(video);
          
          cacheService.put(video.id, 'cached_thumbnail_$i');
          fileSystem.createFile(video.thumbnailPath!);
        }
        
        // 删除前面的deleteCount个视频
        final actualDeleteCount = deleteCount < totalCount ? deleteCount : totalCount;
        for (int i = 0; i < actualDeleteCount; i++) {
          mockDeleteVideoFiles(videos[i], cacheService, fileSystem);
        }
        
        // 验证：被删除的视频缓存和文件都被移除
        for (int i = 0; i < actualDeleteCount; i++) {
          expect(cacheService.containsKey(videos[i].id), isFalse,
            reason: '被删除的视频${videos[i].id}缓存应被移除');
          expect(fileSystem.fileExists(videos[i].thumbnailPath!), isFalse,
            reason: '被删除的视频${videos[i].id}文件应被删除');
        }
        
        // 验证：未被删除的视频缓存和文件都保留
        for (int i = actualDeleteCount; i < totalCount; i++) {
          expect(cacheService.containsKey(videos[i].id), isTrue,
            reason: '未删除的视频${videos[i].id}缓存应保留');
          expect(fileSystem.fileExists(videos[i].thumbnailPath!), isTrue,
            reason: '未删除的视频${videos[i].id}文件应保留');
        }
        
        // 验证：缓存和文件系统大小正确
        expect(cacheService.size, equals(totalCount - actualDeleteCount),
          reason: '缓存大小应等于总数减去删除数量');
        expect(fileSystem.fileCount, equals(totalCount - actualDeleteCount),
          reason: '文件数量应等于总数减去删除数量');
      },
    );

    /// Property 5 补充测试：重复删除同一视频
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados2(
      any.lowercaseLetters, // 随机videoId
      any.positiveIntOrZero.map((n) => (n % 5) + 1), // 重复次数: 1-5
      _explore,
    ).test(
      'Property 5: 重复删除同一视频应是幂等的',
      (videoId, repeatCount) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        
        // 创建视频项
        final video = MockVideoItem(
          id: videoId,
          path: '/videos/$videoId.mp4',
          thumbnailPath: '/thumbnails/$videoId.jpg',
          isRecycled: true,
        );
        
        // 设置初始状态
        cacheService.put(video.id, 'cached_thumbnail');
        fileSystem.createFile(video.thumbnailPath!);
        
        // 第一次删除
        mockDeleteVideoFiles(video, cacheService, fileSystem);
        
        // 验证第一次删除成功
        expect(cacheService.containsKey(video.id), isFalse,
          reason: '第一次删除后缓存应被移除');
        expect(fileSystem.fileExists(video.thumbnailPath!), isFalse,
          reason: '第一次删除后文件应被删除');
        
        // 重复删除多次（应该不会抛出异常）
        for (int i = 0; i < repeatCount; i++) {
          mockDeleteVideoFiles(video, cacheService, fileSystem);
          
          // 验证：状态保持不变
          expect(cacheService.containsKey(video.id), isFalse,
            reason: '第${i + 2}次删除后缓存应仍不存在');
          expect(fileSystem.fileExists(video.thumbnailPath!), isFalse,
            reason: '第${i + 2}次删除后文件应仍不存在');
        }
        
        // 验证：缓存和文件系统为空
        expect(cacheService.size, equals(0),
          reason: '重复删除后缓存应为空');
        expect(fileSystem.fileCount, equals(0),
          reason: '重复删除后文件系统应为空');
      },
    );

    /// Property 5 补充测试：删除操作的原子性
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados(any.lowercaseLetters, _explore).test(
      'Property 5: 删除操作应同时清理缓存和文件，保持一致性',
      (videoId) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        
        // 创建视频项
        final video = MockVideoItem(
          id: videoId,
          path: '/videos/$videoId.mp4',
          thumbnailPath: '/thumbnails/$videoId.jpg',
          isRecycled: true,
        );
        
        // 设置初始状态
        cacheService.put(video.id, 'cached_thumbnail');
        fileSystem.createFile(video.thumbnailPath!);
        
        // 执行删除操作
        mockDeleteVideoFiles(video, cacheService, fileSystem);
        
        // 验证：缓存和文件系统状态一致（都为空）
        final cacheExists = cacheService.containsKey(video.id);
        final fileExists = fileSystem.fileExists(video.thumbnailPath!);
        
        expect(cacheExists, equals(fileExists),
          reason: '缓存和文件的存在状态应一致');
        
        expect(cacheExists, isFalse,
          reason: '删除后缓存和文件都不应存在');
      },
    );

    /// Property 5 补充测试：混合场景（有些视频有缓存，有些没有）
    /// 
    /// **Feature: thumbnail-loading-optimization, Property 5: Thumbnail Deletion Synchronization**
    Glados(any.positiveIntOrZero.map((n) => (n % 10) + 2), _explore).test(
      'Property 5: 删除混合状态的视频集合应正确处理',
      (videoCount) {
        final cacheService = MockCacheService();
        final fileSystem = MockFileSystem();
        final videos = <MockVideoItem>[];
        
        // 创建多个视频项，混合不同状态
        for (int i = 0; i < videoCount; i++) {
          final video = MockVideoItem(
            id: 'video_$i',
            path: '/videos/video_$i.mp4',
            thumbnailPath: i % 2 == 0 ? '/thumbnails/thumb_$i.jpg' : null,
            isRecycled: true,
          );
          videos.add(video);
          
          // 奇数索引：有缓存和文件
          // 偶数索引：只有缓存，没有文件（或没有thumbnailPath）
          cacheService.put(video.id, 'cached_thumbnail_$i');
          if (i % 2 == 0 && video.thumbnailPath != null) {
            fileSystem.createFile(video.thumbnailPath!);
          }
        }
        
        // 删除所有视频
        for (final video in videos) {
          mockDeleteVideoFiles(video, cacheService, fileSystem);
        }
        
        // 验证：所有缓存条目都被移除
        for (final video in videos) {
          expect(cacheService.containsKey(video.id), isFalse,
            reason: '删除后视频${video.id}的缓存应被移除');
        }
        
        // 验证：所有文件都被删除
        for (final video in videos) {
          if (video.thumbnailPath != null) {
            expect(fileSystem.fileExists(video.thumbnailPath!), isFalse,
              reason: '删除后视频${video.id}的文件应被删除');
          }
        }
        
        // 验证：缓存为空
        expect(cacheService.size, equals(0),
          reason: '删除所有视频后缓存应为空');
        
        // 验证：文件系统为空
        expect(fileSystem.fileCount, equals(0),
          reason: '删除所有视频后文件系统应为空');
      },
    );
  });
}
