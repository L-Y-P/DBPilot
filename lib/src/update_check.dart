import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Result of one update check.
///
/// Exactly one of [error] and a successful manifest read is populated: when
/// [error] is non-null the remaining fields are empty (except
/// [currentVersion]) and [hasUpdate] is false, so callers can render a single
/// "failed" branch without inspecting the other values.
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.notes,
    required this.downloadUrl,
    this.error,
  });

  /// True when the manifest advertises a newer version than the running one.
  final bool hasUpdate;

  /// The version the app reported when the check ran.
  final String currentVersion;

  /// The version from the manifest (empty when the check failed).
  final String latestVersion;

  /// Optional release notes from the manifest.
  final String notes;

  /// Optional download / release page URL from the manifest.
  final String downloadUrl;

  /// Human-readable failure reason, or null on success.
  final String? error;
}

/// Compare two version strings, most-significant segment first.
///
/// Tolerates everything a hand-written manifest throws at it: a leading
/// "v", a different number of segments (1.2 vs 1.2.0), build metadata
/// (1.2.3+build5) and non-numeric suffixes (1.2.3-rc1, 1.2.3beta).
///
/// Returns a negative number when [a] is older than [b], zero when they are
/// equal up to the missing segments, and a positive number when [a] is newer.
int compareVersions(String a, String b) {
  final left = _versionSegments(a);
  final right = _versionSegments(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l < r ? -1 : 1;
  }
  return 0;
}

/// Numeric segments of a version string; a missing/odd segment counts as 0.
List<int> _versionSegments(String raw) {
  var text = raw.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  // Build metadata (+...) and a pre-release tag (-...) do not participate in
  // the numeric comparison; only the leading release number matters here.
  final plus = text.indexOf('+');
  if (plus >= 0) text = text.substring(0, plus);
  final dash = text.indexOf('-');
  if (dash >= 0) text = text.substring(0, dash);
  if (text.isEmpty) return <int>[0];
  return <int>[
    for (final segment in text.split('.'))
      int.tryParse(RegExp(r'^[0-9]+').stringMatch(segment) ?? '') ?? 0,
  ];
}

/// Fetch [manifestUrl] and decide whether it advertises a newer build.
///
/// The manifest is a small JSON object:
///
/// {"version": "1.1.0", "url": "https://example.com/download", "notes": "..."}
///
/// Every field except "version" may be omitted. dart:io is the only
/// dependency (no package), and [client] can be injected so tests drive the
/// check against a local server without touching the network stack.
Future<UpdateCheckResult> checkForUpdates({
  required String manifestUrl,
  required String currentVersion,
  Duration timeout = const Duration(seconds: 8),
  HttpClient? client,
}) async {
  UpdateCheckResult failed(String message) => UpdateCheckResult(
        hasUpdate: false,
        currentVersion: currentVersion,
        latestVersion: '',
        notes: '',
        downloadUrl: '',
        error: message,
      );

  final url = manifestUrl.trim();
  if (url.isEmpty) return failed('未配置更新源');

  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return failed('更新检查失败：更新地址无效');
  }

  final owned = client ?? HttpClient();
  if (client == null) {
    owned.connectionTimeout = timeout;
  }
  try {
    final request = await owned.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(timeout);
      return failed('更新检查失败：HTTP ${response.statusCode}');
    }
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(timeout);

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return failed('更新检查失败：更新清单不是合法的 JSON');
    }
    if (decoded is! Map) {
      return failed('更新检查失败：更新清单不是合法的 JSON');
    }

    final latest = (decoded['version'] ?? '').toString().trim();
    if (latest.isEmpty) {
      return failed('更新检查失败：更新清单缺少 version 字段');
    }

    return UpdateCheckResult(
      hasUpdate: compareVersions(latest, currentVersion) > 0,
      currentVersion: currentVersion,
      latestVersion: latest,
      notes: (decoded['notes'] ?? '').toString(),
      downloadUrl: (decoded['url'] ?? '').toString(),
    );
  } on TimeoutException {
    return failed('检查更新超时，请稍后重试');
  } catch (e) {
    return failed('更新检查失败：$e');
  } finally {
    if (client == null) owned.close(force: true);
  }
}
