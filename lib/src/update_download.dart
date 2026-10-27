import 'dart:async';
import 'dart:io';

/// One progress tick of [downloadUpdatePackage].
class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.received,
    required this.total,
    this.done = false,
  });

  /// Bytes written so far.
  final int received;

  /// Total bytes announced by the server, or null when unknown.
  final int? total;

  /// True for the final tick (the package is fully written).
  final bool done;

  /// 0..1 when [total] is known, otherwise null (indeterminate).
  double? get fraction {
    final total = this.total;
    if (total == null || total <= 0) return null;
    final value = received / total;
    return value > 1 ? 1 : value;
  }
}

/// Download failed (network error, HTTP status, truncated body, ...).
class UpdateDownloadException implements Exception {
  const UpdateDownloadException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The caller cancelled the download.
class UpdateCancelledException implements Exception {
  const UpdateCancelledException();
}

/// Downloads [url] into [directory] as [fileName] and returns the written
/// file.
///
/// Only http/https URLs are accepted. The body is streamed to
/// `<fileName>.part` first and renamed into place only after the byte count
/// matches the server's Content-Length (when provided), so a truncated
/// download can never be installed. [onProgress] is called with the initial
/// zero tick, throttled while streaming and once with `done: true`.
///
/// [isCancelled] is polled for every chunk; a cancelled download deletes the
/// partial file and throws [UpdateCancelledException].
Future<File> downloadUpdatePackage({
  required String url,
  required Directory directory,
  required String fileName,
  required void Function(UpdateDownloadProgress progress) onProgress,
  required bool Function() isCancelled,
  Duration timeout = const Duration(seconds: 30),
  HttpClient? client,
}) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    throw const UpdateDownloadException('更新下载地址无效');
  }
  if (fileName.isEmpty ||
      fileName.contains('/') ||
      fileName.contains('\\') ||
      fileName == '.' ||
      fileName == '..') {
    throw const UpdateDownloadException('更新包文件名无效');
  }

  final target = File('${directory.path}/$fileName');
  final part = File('${target.path}.part');
  await directory.create(recursive: true);

  final owned = client ?? HttpClient();
  if (client == null) owned.connectionTimeout = timeout;

  IOSink? sink;
  try {
    final request = await owned.getUrl(uri).timeout(timeout);
    // Ask for the raw bytes: report progress against the real package size.
    request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    final response = await request.close().timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().timeout(timeout);
      throw UpdateDownloadException('下载失败：HTTP ${response.statusCode}');
    }

    final total = response.contentLength > 0 ? response.contentLength : null;
    var received = 0;
    sink = part.openWrite();
    onProgress(UpdateDownloadProgress(received: 0, total: total));

    var lastTick = 0;
    await for (final chunk in response.timeout(timeout)) {
      if (isCancelled()) throw const UpdateCancelledException();
      sink.add(chunk);
      received += chunk.length;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - lastTick >= 120) {
        lastTick = now;
        onProgress(UpdateDownloadProgress(received: received, total: total));
      }
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (isCancelled()) throw const UpdateCancelledException();
    if (total != null && received != total) {
      throw UpdateDownloadException(
          '下载不完整：收到 $received 字节，应为 $total 字节');
    }
    if (target.existsSync()) target.deleteSync();
    await part.rename(target.path);
    onProgress(UpdateDownloadProgress(
        received: received, total: total ?? received, done: true));
    return target;
  } on UpdateCancelledException {
    throw const UpdateCancelledException();
  } on UpdateDownloadException {
    rethrow;
  } on TimeoutException {
    throw const UpdateDownloadException('下载超时，请稍后重试');
  } catch (e) {
    throw UpdateDownloadException('下载失败：$e');
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    if (part.existsSync() && !target.existsSync()) {
      try {
        part.deleteSync();
      } catch (_) {}
    }
    if (client == null) owned.close(force: true);
  }
}
