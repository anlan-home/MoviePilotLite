import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:lanplayer_player/lanplayer_player.dart' as kit;

/// 内嵌播放页路由宿主:入参为 PlayerLaunchController 组装的 PlayerSession。
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key});

  @override
  Widget build(BuildContext context) {
    final session = Get.arguments;
    if (session is! kit.PlayerSession) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: const Text('播放')),
        body: const Center(child: Text('播放参数缺失')),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: kit.PlayerHostPage(session: session),
    );
  }
}
