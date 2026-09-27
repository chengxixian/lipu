/// 应用版本标识。
///
/// 改版本号时**两处一起改**（保持可核对）：
///   1. `pubspec.yaml` 的 `version:`（决定 APK 的 versionName/versionCode）
///   2. 这里的 [kAppVersion]（界面上显示给用户看，用来确认装的是哪个包）
///
/// [kAppBuildNote] 只作版本记录（README / 提交说明里用），
/// **不再显示在标题栏**——按用户要求，标题栏只留版本号。
library;

/// 界面上显示的版本号（与 pubspec.yaml 的 version 保持一致）
const String kAppVersion = '1.8.3 (build 35)';

/// 这个版本的关键变化（只作记录，不显示在界面上）
const String kAppBuildNote = '增强包改成抽屉（毛玻璃面板）+ 可导入 .mnn 模型（实验槽位）+ 界面毛玻璃化';
