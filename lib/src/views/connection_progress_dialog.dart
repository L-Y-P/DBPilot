import 'dart:async';

import 'package:flutter/material.dart' hide Text, Tooltip;

import '../api.dart';
import '../i18n_literals.dart';
import '../text.dart';
import '../theme.dart';

/// Phased feedback for "open this connection".
///
/// Opening a connection can take a long time (unreachable host, firewall, a
/// password prompt retried by the server), and the page used to answer that
/// with a disabled button and nothing else — the user could not tell whether
/// the app was working or hung. The dialog reports progress instead:
///
///  * 0-5 s   "正在连接" with an indeterminate bar, no cancel button (a fast
///            connection must not flash one);
///  * >= 5 s  the dialog adds "已用时 N 秒 · 网络较慢，请稍候" (ticking) and a
///            取消 button: from here the user can always back out;
///  * success closes the dialog and resolves to [ConnectionProgressResult.connected];
///  * failure turns the dialog into an error state with a readable message.
///
/// Cancelling is cooperative: the dialog pops immediately and reports
/// [ConnectionProgressResult.cancelled], and the caller drops whatever the
/// connection attempt returns later. The attempt itself cannot be aborted
/// inside the driver, so the caller also disconnects if it did land.
enum ConnectionProgressResult { connected, failed, cancelled }

/// Show the progress dialog for [connect] and report how it ended.
///
/// [label] is what the user recognises the connection by (name plus address).
/// [connect] performs the real work; [onError] receives the failure so the page
/// can keep showing its own error banner after the dialog closes.
Future<ConnectionProgressResult> showConnectionProgress(
  BuildContext context, {
  required String label,
  required Future<void> Function() connect,
  required void Function(Object error) onError,
}) async {
  // Only one progress dialog may exist at a time. A second call would stack a
  // dialog on top of the first, and because each one owns its own timer the
  // user would see the *lower* dialog's counter through the barrier and could
  // not reach its buttons. The caller already guards its own button, but a
  // double click or a second entry point must not be able to do this either.
  if (_showing) return ConnectionProgressResult.cancelled;
  _showing = true;
  try {
    final result = await showDialog<ConnectionProgressResult>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _ConnectionProgressDialog(
        label: label,
        connect: connect,
        onError: onError,
      ),
    );
    return result ?? ConnectionProgressResult.cancelled;
  } finally {
    _showing = false;
  }
}

/// True while a progress dialog is on screen (see [showConnectionProgress]).
bool _showing = false;

/// When the dialog admits the connection is slow AND offers to cancel.
///
/// One threshold, not two: the user's rule is "after 5 seconds it should say it
/// is still connecting and let me cancel". Before that a fast connection must
/// not flash a cancel button, and a slow one must not leave the user staring at
/// a dialog with no way out.
const Duration kConnectionSlowAfter = Duration(seconds: 5);

class _ConnectionProgressDialog extends StatefulWidget {
  const _ConnectionProgressDialog({
    required this.label,
    required this.connect,
    required this.onError,
  });

  final String label;
  final Future<void> Function() connect;
  final void Function(Object error) onError;

  @override
  State<_ConnectionProgressDialog> createState() =>
      _ConnectionProgressDialogState();
}

class _ConnectionProgressDialogState extends State<_ConnectionProgressDialog> {
  Timer? _ticker;
  int _elapsed = 0;
  bool _failed = false;
  String _error = '';
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    // One tick per second drives both the elapsed counter and the two phase
    // thresholds; a single timer keeps them from drifting apart.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsed += 1);
    });
    _run();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      await widget.connect();
      if (!mounted || _finished) return;
      _finished = true;
      _ticker?.cancel();
      Navigator.of(context).pop(ConnectionProgressResult.connected);
    } catch (error) {
      if (!mounted || _finished) return;
      setState(() {
        _failed = true;
        _error = describeDbError(error);
      });
      widget.onError(error);
    }
  }

  void _cancel() {
    if (_finished) return;
    _finished = true;
    _ticker?.cancel();
    Navigator.of(context).pop(ConnectionProgressResult.cancelled);
  }

  void _close() {
    _finished = true;
    _ticker?.cancel();
    Navigator.of(context).pop(ConnectionProgressResult.failed);
  }

  @override
  Widget build(BuildContext context) {
    final slow = _elapsed >= kConnectionSlowAfter.inSeconds;
    // Same threshold: once the dialog admits it is slow, cancelling is allowed.
    final canCancel = slow;
    return AlertDialog(
      key: const ValueKey('conn-progress'),
      backgroundColor: AppColors.panel,
      title: Text(pickText('正在连接', 'Connecting')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.label,
            key: const ValueKey('conn-progress-target'),
            style: monoStyle(size: 12, color: AppColors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 14),
          if (!_failed) ...<Widget>[
            const LinearProgressIndicator(
              key: ValueKey('conn-progress-bar'),
              minHeight: 3,
            ),
            const SizedBox(height: 10),
            Text(
              pickText('正在连接…', 'Connecting…'),
              key: const ValueKey('conn-progress-status'),
              style: TextStyle(fontSize: 13, color: AppColors.bodyText),
            ),
            if (slow) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                pickText(
                  '已用时 $_elapsed 秒 · 网络较慢，请稍候',
                  'Waiting for $_elapsed s · the server is slow to answer',
                ),
                key: const ValueKey('conn-progress-elapsed'),
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ],
          ] else
            Text(
              _error,
              key: const ValueKey('conn-progress-error'),
              style: TextStyle(fontSize: 13, color: AppColors.errText),
            ),
        ],
      ),
      actions: <Widget>[
        if (_failed)
          TextButton(
            key: const ValueKey('conn-progress-close'),
            onPressed: _close,
            child: Text(pickText('关闭', 'Close')),
          )
        else if (canCancel)
          TextButton(
            key: const ValueKey('conn-progress-cancel'),
            onPressed: _cancel,
            child: Text(pickText('取消', 'Cancel')),
          ),
      ],
    );
  }
}
