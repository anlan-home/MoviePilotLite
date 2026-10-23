import 'package:flutter/foundation.dart';

/// 自更新下载线路：直连或经 GitHub 加速源。
@immutable
class UpdateMirror {
  const UpdateMirror({
    required this.id,
    required this.label,
    required this.template,
    this.builtin = false,
    this.isDirect = false,
  });

  const UpdateMirror.direct()
    : id = directId,
      label = '直连 GitHub',
      template = '',
      builtin = true,
      isDirect = true;

  static const String directId = 'direct';
  static const String urlPlaceholder = '{url}';

  final String id;
  final String label;

  /// 前缀式（`https://ghproxy.net/`）或占位符式（`https://x/{url}`）。
  final String template;
  final bool builtin;
  final bool isDirect;

  /// 把 GitHub 原始下载地址转换为该线路的实际下载地址。
  String resolve(String sourceUrl) {
    if (isDirect) return sourceUrl;
    final trimmed = template.trim();
    if (trimmed.isEmpty) return sourceUrl;
    if (trimmed.contains(urlPlaceholder)) {
      return trimmed.replaceAll(urlPlaceholder, sourceUrl);
    }
    return trimmed.endsWith('/') ? '$trimmed$sourceUrl' : '$trimmed/$sourceUrl';
  }

  /// 校验用户输入，返回错误文案；合法时返回 null。
  static String? validateTemplate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '请输入加速源地址';
    final sample = value.replaceAll(urlPlaceholder, 'https://example.com/a.apk');
    final uri = Uri.tryParse(sample);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return '地址格式不正确';
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      return '仅支持 http/https 地址';
    }
    if (!value.contains(urlPlaceholder) && value == sample) {
      // 前缀式：至少要有一个路径或结尾斜杠，避免误填成裸域名后拼出错误地址。
      if (!value.endsWith('/') && uri.path.isEmpty) {
        return '前缀式加速源请以 / 结尾，或使用 {url} 占位符';
      }
    }
    return null;
  }

  /// 用户未填写名称时，用域名作为展示名。
  static String labelFromTemplate(String raw) {
    final value = raw.trim();
    final sample = value.replaceAll(urlPlaceholder, '');
    final uri = Uri.tryParse(sample);
    final host = uri?.host ?? '';
    return host.isEmpty ? value : host;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'template': template,
  };

  static UpdateMirror? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id']?.toString().trim() ?? '';
    final template = raw['template']?.toString().trim() ?? '';
    if (id.isEmpty || template.isEmpty) return null;
    final label = raw['label']?.toString().trim() ?? '';
    return UpdateMirror(
      id: id,
      label: label.isEmpty ? labelFromTemplate(template) : label,
      template: template,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateMirror &&
      other.id == id &&
      other.label == label &&
      other.template == template &&
      other.isDirect == isDirect;

  @override
  int get hashCode => Object.hash(id, label, template, isDirect);
}
