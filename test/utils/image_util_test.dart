import 'package:flutter_test/flutter_test.dart';
import 'package:moviepilot_mobile/utils/image_util.dart';

void main() {
  group('ImageUtil.convertCacheImageUrl 已是 MoviePilot 代理地址时幂等', () {
    test('空地址原样返回', () {
      expect(ImageUtil.convertCacheImageUrl(''), '');
    });

    test('缓存代理地址不再二次包裹', () {
      const proxied =
          'https://mp.example.com/api/v1/system/cache/image?url=https%3A%2F%2Fimage.tmdb.org%2Ft%2Fp%2Fw200%2Fabc.jpg';
      expect(ImageUtil.convertCacheImageUrl(proxied), proxied);
    });

    test('媒体服务器图片代理地址（system/img/0）不再二次包裹', () {
      const proxied =
          'https://mp.example.com/api/v1/system/img/0?imgurl=http%3A%2F%2F192.168.31.173%3A8096%2FItems%2F6100%2FImages%2FPrimary%23mp_sig%3Dabc%26mp_purpose%3Dresource&use_cookies=true';
      expect(ImageUtil.convertCacheImageUrl(proxied), proxied);
    });

    test('插件图标代理地址（system/img/1）不再二次包裹', () {
      const proxied =
          'https://mp.example.com/api/v1/system/img/1?imgurl=https%3A%2F%2Fexample.com%2Ficon.png';
      expect(ImageUtil.convertCacheImageUrl(proxied), proxied);
    });
  });
}
