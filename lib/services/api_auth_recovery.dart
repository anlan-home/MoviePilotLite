import 'dart:async';

import 'package:dio/dio.dart';
import 'package:get/get.dart' as g;
import 'package:moviepilot_mobile/utils/toast_util.dart';

/// 401/403 的统一处置:优先用本地保存的账号静默重登恢复会话,
/// 恢复失败或无法恢复时清理会话并踢回登录页。
///
/// 从 ApiClient 拆出,只负责"处置决策与会话踢出"这一件事;
/// 会话数据本身的清理(Cookie/Token/本地档案)由宿主通过
/// [clearSession] 回调完成。
class ApiAuthRecovery {
  ApiAuthRecovery({required Future<void> Function() clearSession})
    : _clearSession = clearSession;

  final Future<void> Function() _clearSession;

  /// 401/403 时的静默恢复钩子，由 AuthRepository 注册；返回 true 表示已重新登录成功。
  Future<bool> Function()? handler;
  bool _redirecting = false;
  bool _inProgress = false;
  DateTime? _lastAt;

  /// 两次静默重登尝试之间的最小间隔，避免旧 token 的并发 401 反复触发重登。
  static const Duration _cooldown = Duration(seconds: 15);

  void maybeHandle(RequestOptions? opts, int? status) {
    if (opts?.extra['skipUnauthorizedHandling'] == true) return;
    handle(status);
  }

  void handle(int? status) {
    if (status != 401 && status != 403) return;
    if (_redirecting) return;
    if (!_hasEnteredMain()) return;
    unawaited(_recoverOrLogout());
  }

  Future<void> _recoverOrLogout() async {
    if (handler != null) {
      if (_inProgress) return;
      final last = _lastAt;
      if (last != null && DateTime.now().difference(last) < _cooldown) {
        // 冷却期内：最近一次恢复要么成功要么正在进行，静默忽略而非踢出。
        return;
      }
      _inProgress = true;
      bool recovered = false;
      try {
        recovered = await handler!();
      } catch (_) {
        recovered = false;
      } finally {
        _inProgress = false;
        _lastAt = DateTime.now();
      }
      if (recovered) {
        return;
      }
    }

    _redirecting = true;
    _clearSession();
    ToastUtil.error('会话已过期，请重新登录');
    g.Get.offAllNamed('/login');
    Future.delayed(const Duration(seconds: 1), () {
      _redirecting = false;
    });
  }

  bool _hasEnteredMain() {
    final route = g.Get.currentRoute;
    if (route.isEmpty) return false;
    return route != '/login';
  }
}
