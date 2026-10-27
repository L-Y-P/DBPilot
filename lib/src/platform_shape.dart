import 'dart:io';

/// How the desktop app was packaged on Windows.
///
/// A Microsoft Store build is shipped as an **MSIX** package: Windows unpacks
/// it into `%ProgramFiles%\WindowsApps\<package family name>\`, signs it with
/// the Store certificate, and runs the app inside the MSIX container. That
/// changes two things for the update flow:
///
///  * an MSIX app may not launch an external installer (the NSIS setup) to
///    replace itself — Windows would either block it or leave two copies;
///  * the Store owns the install, and re-signs every release, so the only
///    correct way to update is the Store itself.
///
/// Nothing here is Windows-only API: the decision is a pure function of an
/// executable path and an environment snapshot, so it is unit-testable on any
/// host (CI runs `flutter test` on macOS and Linux too).

/// Environment variable Windows sets for a packaged (MSIX) process.
///
/// Present inside the MSIX container, absent when the same exe is launched
/// unpackaged (for example straight from a build directory) — exactly the
/// distinction needed here. The value is the package family name, e.g.
/// `DBPilot_8wekyb3d8bbwe`.
const String kAppxPackageFamilyNameEnv = 'APPX_PACKAGE_FAMILY_NAME';

/// Directory Windows unpacks MSIX packages into.
///
/// The surrounding separators matter: a hand-installed copy under
/// `C:\Users\me\WindowsApps-backup\...` must not look like a Store build.
const String kWindowsAppsDirName = 'WindowsApps';

/// True when the running build is an MSIX package (Microsoft Store shape).
///
/// Pure function: both inputs are explicit so every shape can be tested
/// without touching the real process.
///
///  * [executablePath] — normally [Platform.resolvedExecutable]; may be empty
///    when the platform has no such concept.
///  * [environment] — normally [Platform.environment]; injecting a map keeps
///    tests independent of the machine running them.
///
/// The environment variable wins because it is authoritative: a packaged app
/// always carries it and an unpackaged one never does. The path is the
/// fallback for a process that lost its environment. Paths are compared
/// case-insensitively and with either separator, because Windows is.
bool isMsixPackaged({
  required String executablePath,
  required Map<String, String> environment,
}) {
  if ((environment[kAppxPackageFamilyNameEnv] ?? '').trim().isNotEmpty) {
    return true;
  }
  final path = executablePath.trim();
  if (path.isEmpty) return false;
  // `\\WindowsApps\\` is matched with its own separators so a sibling folder
  // such as `WindowsApps-backup` does not count as a Store install. The
  // separators are built with fromCharCode because a raw backslash pair would
  // be read as an escape sequence inside the string literal.
  final normalized = path.replaceAll('/', '\\').toLowerCase();
  final dir = kWindowsAppsDirName.toLowerCase();
  final marker = String.fromCharCode(0x5C) + dir + String.fromCharCode(0x5C);
  return normalized.contains(marker);
}

/// [isMsixPackaged] for the running process.
///
/// The production value of [platformShapeExecutable] / [platformShapeEnvironment];
/// test seams like the ones in update_apply.dart, so a widget test can pretend
/// to be a Store install without launching one.
String Function() platformShapeExecutable = () => Platform.resolvedExecutable;
Map<String, String> Function() platformShapeEnvironment =
    () => Platform.environment;

/// Whether *this* process is the MSIX shape.
///
/// A process never changes shape while it runs, but the seams are re-read on
/// every call so tests can swap them between cases.
bool isRunningAsMsix() => isMsixPackaged(
      executablePath: platformShapeExecutable(),
      environment: platformShapeEnvironment(),
    );
