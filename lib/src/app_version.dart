/// Application identity shown in the settings dialog and the about area.
///
/// The desktop bundle has no package_info_plus dependency, so the version is
/// kept here and must stay in sync with `version:` in desktop/pubspec.yaml
/// (1.1.2+4). The Rust core crate version is available through the generated
/// bridge (`rapi.coreVersion()`) but is deliberately not shown in the UI: both
/// are released together, so the two numbers can never disagree.
const String kAppVersion = '1.1.2';
const int kAppBuildNumber = 4;

/// Product name. Mirrors the native bundle name (macOS PRODUCT_NAME, the
/// Windows resource strings, the Rust default_title) so every surface agrees.
const String kAppName = 'DBPilot';

/// Display form: "DBPilot 1.1.1".
///
/// Deliberately without the build number: it is the release pipeline's internal
/// counter (the `+3` in pubspec's `version: 1.1.1+3`) and means nothing to a
/// user looking at the About area. [kAppBuildNumber] stays because the release
/// process still reads it; it just never reaches the UI.
String appVersionLabel() => '$kAppName $kAppVersion';
