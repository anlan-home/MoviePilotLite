# Agent 公约

## Flutter 页面结构
- 涉及 Flutter/Dart 页面、组件、布局、状态、路由、构建或分析的任务，默认优先使用 `/flutter skill`；除非用户明确指定其他 skill 或任务与 Flutter 无关。
- 页面根布局使用 `Scaffold`，顶栏使用 `appBar`（默认 `AppBar`；若需 iOS 导航栏外观，可将 `CupertinoNavigationBar` 等实现 `PreferredSizeWidget` 的组件赋给 `appBar`），主内容一律放在 `body`。
- 新增页面不要用 `CupertinoPageScaffold` 作为整页根；与上述结构不一致的存量页可在改动时顺带收敛。

## API/Server 约定
- Server 文档地址：https://api.movie-pilot.org
- 所有 HTTP 请求必须严格按照 Swagger 文档定义执行（接口路径、方法、参数、请求体、Header、鉴权等均以 Swagger 为准）。

## 输出约束
- 禁止在对话回复中输出任何代码内容（包括但不限于：代码块、代码片段、行号引用、patch/diff、堆栈中的代码行、以及内联代码格式）。如需修改代码，仅允许直接改动仓库文件而不展示代码。
## Cursor Cloud specific instructions

### Environment
- Flutter 3.38.2 installed at `/opt/flutter`, Dart 3.10.0 bundled
- Android SDK at `/opt/android-sdk` (SDK 36, build-tools 36.0.0, NDK 28.2)
- PATH and ANDROID_HOME are set in `~/.bashrc`

### Commands
- **Install deps**: `flutter pub get`
- **Code gen** (freezed/json_serializable/flutter_gen): `dart run build_runner build --delete-conflicting-outputs`
- **Lint**: `flutter analyze`
- **Test**: `flutter test`
- **Build debug APK**: `flutter build apk --debug`
- **Build release APK**: `flutter build apk --release --dart-define=FLUTTER_APP_ENV=release`

### Gotchas
- `dart run build_runner build` regenerates `*.freezed.dart` files. The historical `form_block_models` duplicate-class defect (menu/group constructors colliding) **has been fixed in the source model** — regeneration is allowed; still verify `git status` so only intended generated files change. Known unrelated failure: `flutter_gen_runner` fails to parse its config (exit 78) and aborts the run after json/freezed/hive builders complete; asset generation via flutter_gen is currently broken and needs the `rive` integration pruned or the package added.
- The project targets **Android/iOS/macOS only** — no web or linux platform. Cannot run interactively in a headless VM; use `flutter build apk --debug` to verify builds.
- First Android build downloads Realm native binaries and CMake automatically — this can take ~2 minutes extra.
- `pubspec.lock` may show minor version drifts after `flutter pub get`; restore with `git checkout -- pubspec.lock` if you don't intend to update deps.
