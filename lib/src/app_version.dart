/// Application identity shown in the settings dialog and the about area.
///
/// The desktop bundle has no package_info_plus dependency, so the version is
/// kept here and must stay in sync with `version:` in desktop/pubspec.yaml
/// (1.1.0+2). The Rust core version is read separately through
/// `Api.instance.coreVersion()`.
const String kAppVersion = '1.1.0';
const int kAppBuildNumber = 2;

/// Product name. Mirrors the native bundle name (macOS PRODUCT_NAME, the
/// Windows resource strings, the Rust default_title) so every surface agrees.
const String kAppName = 'DBPilot';

/// Display form: "DBPilot 1.1.0 (build 2)".
String appVersionLabel() => '$kAppName $kAppVersion (build $kAppBuildNumber)';
