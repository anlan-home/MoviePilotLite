import 'package:get/get.dart';
import 'package:moviepilot_mobile/modules/music/models/music_models.dart';
import 'package:moviepilot_mobile/services/api_client.dart';
import 'package:moviepilot_mobile/services/server_api_version_service.dart';

/// 音乐搜索：走 v3 通用媒体搜索（type=music），返回音乐人 / 专辑 / 单曲。
/// 与音乐库一致：仅 v3 服务端可用，入口与深链都先做版本门控。
class MusicSearchController extends GetxController {
  MusicSearchController({
    ApiClient? apiClient,
    ServerApiVersionService? versionService,
  }) : api = apiClient ?? Get.find<ApiClient>(),
       version = versionService ?? Get.find<ServerApiVersionService>();

  final ApiClient api;
  final ServerApiVersionService version;

  static const int _pageSize = 30;

  final keyword = ''.obs;
  final items = <MusicExploreItem>[].obs;
  final isLoading = false.obs;
  final hasMore = true.obs;
  final errorText = RxnString();
  final supported = Rxn<bool>();

  int _generation = 0;
  int _page = 1;

  @override
  void onInit() {
    super.onInit();
    final seed = Get.parameters['keyword']?.trim() ?? '';
    if (seed.isNotEmpty) keyword.value = seed;
  }

  @override
  void onReady() {
    super.onReady();
    if (keyword.value.isNotEmpty) {
      search();
    }
  }

  bool _current(int request) => !isClosed && request == _generation;

  Future<void> search({String? keywordOverride}) async {
    final term = (keywordOverride ?? keyword.value).trim();
    if (term.isEmpty) {
      errorText.value = '请输入搜索关键字';
      return;
    }
    final request = ++_generation;
    keyword.value = term;
    _page = 1;
    hasMore.value = true;
    items.clear();
    errorText.value = null;
    isLoading.value = true;
    try {
      final ok = await version.isV3();
      if (!_current(request)) return;
      supported.value = ok;
      if (!ok) {
        errorText.value = '音乐功能需要 MoviePilot v3 服务端';
        return;
      }
      await _loadPage(request);
    } catch (_) {
      if (_current(request)) errorText.value = '搜索失败，请稍后重试';
    } finally {
      if (_current(request)) isLoading.value = false;
    }
  }

  Future<void> loadMore() async {
    if (isClosed || isLoading.value || !hasMore.value || supported.value != true) {
      return;
    }
    final request = _generation;
    isLoading.value = true;
    try {
      await _loadPage(request);
    } catch (_) {
      if (_current(request)) errorText.value = '加载更多失败，请稍后重试';
    } finally {
      if (_current(request)) isLoading.value = false;
    }
  }

  Future<void> _loadPage(int request) async {
    final response = await api.get<dynamic>(
      '/api/v1/media/search',
      queryParameters: {
        'title': keyword.value.trim(),
        'type': 'music',
        'page': _page,
        'count': _pageSize,
      },
      skipV3EnvelopeUnwrap: true,
    );
    if (!_current(request)) return;
    final data = response.data;
    final payload = data is Map && data.containsKey('data')
        ? data['data']
        : data;
    final raw = payload is List ? payload : const <dynamic>[];
    final parsed = raw
        .whereType<Map>()
        .map(
          (e) => MusicExploreItem.fromJson(
            Map<String, dynamic>.from(e),
            fallbackSource: 'musicbrainz',
          ),
        )
        .where((item) => item.mediaId.isNotEmpty)
        .toList();
    final seen = items
        .map((e) => '${e.mediaSource}:${e.musicType}:${e.mediaId}')
        .toSet();
    for (final item in parsed) {
      final key = '${item.mediaSource}:${item.musicType}:${item.mediaId}';
      if (seen.add(key)) items.add(item);
    }
    hasMore.value = parsed.length >= _pageSize;
    _page += 1;
    if (items.isEmpty) {
      errorText.value = '没有找到匹配的音乐';
    }
  }
}
