import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import '../mpv/mpv_engine.dart';
import '../../utils/app_log.dart';

/// Anime4K 着色器预设
enum Anime4KProfile {
  /// Mode A — 最高画质（适合高端设备）
  /// Clamp_Highlights + Restore_CNN_M + Upscale_CNN_x2_M + AutoDownscalePre_x2 + AutoDownscalePre_x4 + Upscale_CNN_x2_S
  modeA,

  /// Mode B — 平衡画质与性能
  /// Clamp_Highlights + Restore_CNN_S + Upscale_Denoise_CNN_x2_S + AutoDownscalePre_x2 + Upscale_CNN_x2_S
  modeB,

  /// Mode C — 性能优先（适合中低端设备）
  /// Clamp_Highlights + Upscale_Denoise_CNN_x2_S + AutoDownscalePre_x2 + Upscale_CNN_x2_S
  modeC,

  /// 仅降噪（不放大）
  denoiseOnly,

  /// 自定义（用户手动选择着色器文件）
  custom,
}

/// Anime4K 着色器管理服务
///
/// 负责：
/// 1. 检测着色器文件是否已下载到设备
/// 2. 从 assets 或网络下载到本地缓存
/// 3. 根据预设配置生成着色器链
/// 4. 通过 MpvEngine.loadShaders() 应用到 mpv
class Anime4KService {
  static String? _shaderDir;

  /// 获取着色器缓存目录（首次调用时创建）
  static Future<String> getShaderDir() async {
    if (_shaderDir != null) return _shaderDir!;
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/anime4k_shaders');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _shaderDir = dir.path;
    return dir.path;
  }

  /// 检查指定着色器文件是否已缓存
  static Future<bool> isShaderCached(String fileName) async {
    final dir = await getShaderDir();
    return File('$dir/$fileName').exists();
  }

  /// 列出已缓存的着色器文件
  static Future<List<String>> listCachedShaders() async {
    final dir = await getShaderDir();
    final d = Directory(dir);
    if (!await d.exists()) return [];
    return d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.glsl'))
        .map((f) => f.path.split(Platform.pathSeparator).last)
        .toList()
      ..sort();
  }

  /// 从字符串内容写入着色器文件到缓存
  static Future<String> saveShader(String fileName, String content) async {
    final dir = await getShaderDir();
    final file = File('$dir/$fileName');
    await file.writeAsString(content);
    return file.path;
  }

  /// 删除已缓存的着色器文件
  static Future<void> deleteShader(String fileName) async {
    final dir = await getShaderDir();
    final file = File('$dir/$fileName');
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// 清空所有缓存的着色器
  static Future<void> clearAllShaders() async {
    final dir = await getShaderDir();
    final d = Directory(dir);
    if (await d.exists()) {
      await d.delete(recursive: true);
      await d.create(recursive: true);
    }
  }

  /// 根据预设配置获取着色器文件路径列表
  ///
  /// 返回本地缓存路径列表；如果缺少文件则返回空列表。
  static Future<List<String>> getShaderPaths(Anime4KProfile profile) async {
    final dir = await getShaderDir();
    final fileNames = _profileFileNames(profile);
    final paths = <String>[];

    for (final name in fileNames) {
      final path = '$dir/$name';
      if (await File(path).exists()) {
        paths.add(path);
      } else {
        AppLog.w('Anime4K', '着色器缺失: $name');
      }
    }
    return paths;
  }

  /// 应用 Anime4K 预设到当前 MPV 引擎
  static Future<bool> applyProfile(
    Anime4KProfile profile,
    MpvEngine engine,
  ) async {
    if (profile == Anime4KProfile.custom) {
      // 自定义模式不自动应用
      return false;
    }
    final paths = await getShaderPaths(profile);
    if (paths.isEmpty) {
      AppLog.w('Anime4K', '预设 ${profile.name} 无可用着色器，请先下载');
      return false;
    }
    return engine.loadShaders(paths);
  }

  /// 获取预设所需的着色器文件名列表
  static List<String> _profileFileNames(Anime4KProfile profile) {
    switch (profile) {
      case Anime4KProfile.modeA:
        return [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Restore_CNN_M.glsl',
          'Anime4K_Upscale_CNN_x2_M.glsl',
          'Anime4K_AutoDownscalePre_x2.glsl',
          'Anime4K_AutoDownscalePre_x4.glsl',
          'Anime4K_Upscale_CNN_x2_S.glsl',
        ];
      case Anime4KProfile.modeB:
        return [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Restore_CNN_S.glsl',
          'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
          'Anime4K_AutoDownscalePre_x2.glsl',
          'Anime4K_Upscale_CNN_x2_S.glsl',
        ];
      case Anime4KProfile.modeC:
        return [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Upscale_Denoise_CNN_x2_S.glsl',
          'Anime4K_AutoDownscalePre_x2.glsl',
          'Anime4K_Upscale_CNN_x2_S.glsl',
        ];
      case Anime4KProfile.denoiseOnly:
        return [
          'Anime4K_Clamp_Highlights.glsl',
          'Anime4K_Denoise_Bilateral_Mode.glsl',
        ];
      case Anime4KProfile.custom:
        return [];
    }
  }

  /// 获取预设的显示名称
  static String profileLabel(Anime4KProfile profile) {
    switch (profile) {
      case Anime4KProfile.modeA:
        return 'Mode A (最高画质)';
      case Anime4KProfile.modeB:
        return 'Mode B (平衡)';
      case Anime4KProfile.modeC:
        return 'Mode C (性能优先)';
      case Anime4KProfile.denoiseOnly:
        return '仅降噪';
      case Anime4KProfile.custom:
        return '自定义';
    }
  }

  /// 检查预设的所有着色器是否已就绪
  static Future<bool> isProfileReady(Anime4KProfile profile) async {
    if (profile == Anime4KProfile.custom) return false;
    final paths = await getShaderPaths(profile);
    final needed = _profileFileNames(profile);
    return paths.length == needed.length;
  }
}

// ===== Riverpod Providers =====

/// 当前选中的 Anime4K 预设
final anime4KProfileProvider = StateProvider<Anime4KProfile>((ref) {
  return Anime4KProfile.modeB; // 默认平衡模式
});

/// Anime4K 是否启用
final anime4KEnabledProvider = StateProvider<bool>((ref) => false);

/// Anime4K 服务实例
final anime4KServiceProvider = Provider<Anime4KService>((ref) {
  return Anime4KService();
});
