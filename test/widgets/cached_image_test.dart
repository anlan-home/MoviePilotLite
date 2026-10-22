import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moviepilot_mobile/utils/image_cache_manager.dart';
import 'package:moviepilot_mobile/widgets/cached_image.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('解码缓存预算', () {
    test('全局解码缓存按字节预算放宽，避免一屏海报就淘汰', () {
      AppImageCacheManager.configureGlobalDecodedCache();
      final cache = PaintingBinding.instance.imageCache;
      expect(cache.maximumSize, AppImageCacheManager.decodedImageMaximumSize);
      expect(
        cache.maximumSizeBytes,
        AppImageCacheManager.decodedImageMaximumSizeBytes,
      );
      // 单张 3 倍屏海报解码后约 2.9MB，预算至少要能放下两屏（约 30 张）。
      expect(
        AppImageCacheManager.decodedImageMaximumSizeBytes,
        greaterThanOrEqualTo(30 * 3 * 1024 * 1024),
      );
    });

    test('磁盘缓存对象数恢复到大对象上限', () {
      expect(AppImageCacheManager.diskMaximumObjects, greaterThanOrEqualTo(1000));
    });
  });

  group('CachedImage 默认动画', () {
    test('淡入时长收敛到短动画，磁盘命中不再等 300ms', () {
      const image = CachedImage(imageUrl: 'https://example.com/a.jpg');
      expect(image.fadeInDuration, const Duration(milliseconds: 120));
      expect(image.fadeOutDuration, const Duration(milliseconds: 80));
    });

    test('默认仍走缓存代理地址转换', () {
      const image = CachedImage(imageUrl: 'https://example.com/a.jpg');
      expect(image.convertProxyUrl, isTrue);
    });
  });

  group('加载失败时的缓存淘汰策略', () {
    test('404/410 才删除磁盘缓存', () {
      expect(
        shouldEvictImageOnError(
          const HttpExceptionWithStatus(404, 'not found'),
        ),
        isTrue,
      );
      expect(
        shouldEvictImageOnError(const HttpExceptionWithStatus(410, 'gone')),
        isTrue,
      );
    });

    test('网络抖动等临时错误不删缓存', () {
      expect(
        shouldEvictImageOnError(
          const HttpExceptionWithStatus(500, 'server error'),
        ),
        isFalse,
      );
      expect(
        shouldEvictImageOnError(SocketException('network is unreachable')),
        isFalse,
      );
      expect(shouldEvictImageOnError(TimeoutException('timed out')), isFalse);
      expect(shouldEvictImageOnError(Exception('unknown')), isFalse);
    });
  });
}
