import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:moviepilot_mobile/applog/app_log.dart';
import 'package:moviepilot_mobile/modules/search/controllers/app_setting_controller.dart';
import 'package:moviepilot_mobile/modules/search/models/app_update_info.dart';
import 'package:moviepilot_mobile/modules/search/services/update_mirror_store.dart';
import 'package:moviepilot_mobile/services/api_client.dart';
import 'package:moviepilot_mobile/services/app_service.dart';
import 'package:moviepilot_mobile/services/hive_service.dart';
import 'package:moviepilot_mobile/services/ios_shared_session_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppUpdateInfo _info({
  required bool newer,
  bool withApk = true,
  String notes = '- fix something',
}) => AppUpdateInfo(
  currentVersion: '1.2.6',
  currentBuildNumber: 1,
  latestVersion: newer ? '1.2.7' : '1.2.6',
  latestBuildNumber: newer ? 2 : 1,
  tagName: 'release-v1.2.6',
  releaseName: 'v1.2.6',
  releaseUrl: 'https://github.com/singleton-altman/MoviePilotLite/releases',
  releaseNotes: notes,
  apkDownloadUrl: withApk ? 'https://github.com/x/a.apk' : '',
  apkAssetName: withApk ? 'a.apk' : '',
  apkSize: withApk ? 1024 : null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Get.reset();
  });

  Future<AppSettingController> openDialog(
    WidgetTester tester,
    AppUpdateInfo info, {
    bool isAndroid = true,
    bool isIos = false,
  }) async {
    Get.put(AppLog());
    Get.put(AppService());
    Get.put(IosSharedSessionService());
    Get.put(HiveService());
    Get.put(ApiClient());
    Get.put(UpdateMirrorStore(), permanent: true);
    final controller = Get.put(AppSettingController());
    controller.debugIsAndroidOverride = isAndroid;
    controller.debugIsIosOverride = isIos;
    await tester.pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox())));
    await tester.pumpAndSettle();
    controller.showUpdateDialogForTest(info);
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('mirror section is shown with an update available', (tester) async {
    await openDialog(tester, _info(newer: true));
    expect(find.text('下载线路'), findsOneWidget);
    expect(find.text('管理'), findsOneWidget);
    expect(find.text('测速'), findsWidgets);
    expect(find.text('下载更新'), findsOneWidget);
  });

  testWidgets('mirror section stays reachable when already up to date', (
    tester,
  ) async {
    // 合并入口后线路选择只存在于弹框内，已是最新版本时必须仍可进入。
    await openDialog(tester, _info(newer: false));
    expect(find.text('下载线路'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('下载更新'), findsNothing);
  });

  testWidgets('mirror section is shown without an apk asset', (tester) async {
    await openDialog(tester, _info(newer: true, withApk: false));
    expect(find.text('下载线路'), findsOneWidget);
  });

  testWidgets('mirror section sits above the release notes', (tester) async {
    // 线路区放在更新内容之后会被长日志顶到看不见的地方。
    await openDialog(
      tester,
      _info(newer: true, notes: '- 一\n- 二\n- 三\n- 四\n- 五'),
    );
    final mirrorY = tester.getTopLeft(find.text('下载线路')).dy;
    final notesY = tester.getTopLeft(find.text('更新内容')).dy;
    expect(mirrorY, lessThan(notesY));
  });

  testWidgets('iOS shows mirrors with a hint and no download action', (
    tester,
  ) async {
    await openDialog(tester, _info(newer: true), isAndroid: false, isIos: true);
    expect(find.text('下载线路'), findsOneWidget);
    expect(find.text('测速'), findsWidgets);
    expect(find.textContaining('仅保存线路偏好'), findsOneWidget);
    expect(find.text('前往 Release'), findsOneWidget);
    expect(find.text('下载更新'), findsNothing);
  });

  testWidgets('other platforms keep the mirror section hidden', (tester) async {
    await openDialog(
      tester,
      _info(newer: true),
      isAndroid: false,
      isIos: false,
    );
    expect(find.text('下载线路'), findsNothing);
  });
}
