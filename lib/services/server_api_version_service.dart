import 'package:get/get.dart';
import 'package:moviepilot_mobile/services/api_client.dart';

/// 服务端 API 形态判定与能力表。
///
/// 背景(2026-09-28 两台真实服务器实测):
/// - 媒体搜索接口存在两种契约:旧式「前缀标识」(/search/media/tmdb:123)与
///   新式「数字标识 + media_source」(/search/media/123?media_source=themoviedb);
/// - 新式服务端缺 media_source 会直接 422(响应体写明 Field required),
///   而旧式前缀形态在另一台服务端上会**挂住不返回**(40 秒无响应);
/// - 因此判定不能只看版本号,要"能力表优先 + 实测结果纠正"。
class ServerApiVersionService extends GetxService {
  final _apiClient = Get.find<ApiClient>();

  /// baseUrl -> 服务端广告的媒体来源取值(如 themoviedb/douban)
  final _sources = <String, Set<String>>{};

  /// baseUrl -> 实测学到的形态(true = 需要新式)。优先级高于能力表。
  final _learnedMode = <String, bool>{};

  final _inFlight = <String, Future<Set<String>?>>{};
  int _generation = 0;

  Future<bool> isV3() async {
    final key = _normalizeBaseUrl(_apiClient.baseUrl);
    if (key == null) return false;
    final learned = _learnedMode[key];
    if (learned != null) return learned;
    final values = await mediaSourceValues();
    return values != null && values.isNotEmpty;
  }

  /// 服务端媒体来源表(探测 GET /api/v1/media/source)。
  /// 返回 null 表示这次没探测成功(不缓存,下次重试);返回空集合表示探测成功
  /// 但服务端没有这个能力(旧式契约)。
  Future<Set<String>?> mediaSourceValues() {
    final baseUrl = _normalizeBaseUrl(_apiClient.baseUrl);
    if (baseUrl == null) return Future.value(null);
    final cached = _sources[baseUrl];
    if (cached != null) return Future.value(cached);
    final pending = _inFlight[baseUrl];
    if (pending != null) return pending;

    final generation = _generation;
    final detection = _detect(baseUrl, generation);
    _inFlight[baseUrl] = detection;
    return detection;
  }

  /// 服务端广告的来源取值(未探测到返回 null)
  Future<Set<String>?> sourcesCached() async => mediaSourceValues();

  /// 记录"这台服务器需要新式形态(带 media_source)"——由 422 响应实测学到
  void markMediaSourceRequired() {
    final key = _normalizeBaseUrl(_apiClient.baseUrl);
    if (key != null) _learnedMode[key] = true;
  }

  /// 兼容旧调用:详情页 422 翻转重试成功后标记该服务器实际认哪种形态
  void markV3(String? baseUrl, bool isV3) {
    final key = _normalizeBaseUrl(baseUrl ?? _apiClient.baseUrl);
    if (key == null) return;
    _learnedMode[key] = isV3;
    _inFlight.remove(key);
  }

  void reset() {
    _generation++;
    _sources.clear();
    _learnedMode.clear();
    _inFlight.clear();
  }

  void invalidate(String? baseUrl) {
    final key = _normalizeBaseUrl(baseUrl ?? _apiClient.baseUrl);
    if (key == null) return;
    _generation++;
    _sources.remove(key);
    _learnedMode.remove(key);
    _inFlight.clear();
  }

  Future<Set<String>?> _detect(String baseUrl, int generation) async {
    try {
      final response = await _apiClient.get<dynamic>(
        '/api/v1/media/source',
        skipV3EnvelopeUnwrap: true,
      );
      final status = response.statusCode ?? 0;
      if (status != 200) return null;
      final values = _extractSources(response.data);
      if (generation == _generation) {
        _sources[baseUrl] = values;
      }
      return values;
    } catch (_) {
      return null;
    } finally {
      if (generation == _generation) {
        _inFlight.remove(baseUrl);
      }
    }
  }

  /// 解析能力表:兼容裸数组与 {success,data:[...]} 两种包装
  Set<String> _extractSources(dynamic data) {
    final list = switch (data) {
      List<dynamic> l => l,
      Map<dynamic, dynamic> m when m['data'] is List => m['data'] as List<dynamic>,
      _ => const <dynamic>[],
    };
    final out = <String>{};
    for (final item in list.whereType<Map>()) {
      final raw = item['media_source'] ?? item['source'] ?? item['name'] ?? '';
      final value = raw.toString().trim().toLowerCase();
      if (value.isNotEmpty) out.add(value);
    }
    return out;
  }

  String? _normalizeBaseUrl(String? baseUrl) {
    final normalized = baseUrl?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
