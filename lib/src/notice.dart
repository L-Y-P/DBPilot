import 'dart:async';

import 'package:flutter/foundation.dart';

import 'i18n_literals.dart';

/// Success-toast controller, mirroring web/src/notice.ts.
///
/// The web composable held a message for 3s, fading the last 400ms. Errors are
/// NOT toasts in this app: every view keeps a separate persistent error, which
/// is why this only ever carries a success string.
class Notice extends ChangeNotifier {
  Notice({this.duration = const Duration(seconds: 3)});

  final Duration duration;
  Timer? _fadeTimer;
  Timer? _hideTimer;

  String _message = '';
  bool _fading = false;

  String get message => _message;
  bool get fading => _fading;
  bool get visible => _message.isNotEmpty;

  /// Show a success message, restarting the timers like the web watcher did.
  void show(String message) {
    _fadeTimer?.cancel();
    _hideTimer?.cancel();
    _fading = false;
    // Success toasts are app prompts: translate the UI copy, while keeping any
    // interpolated value (file path, row count) and any backend detail intact.
    _message = trLiteral(message);
    notifyListeners();
    if (message.isEmpty) return;
    // Fade starts 400ms before the message is removed, matching notice.ts.
    final fadeAfter = duration - const Duration(milliseconds: 400);
    _fadeTimer = Timer(fadeAfter.isNegative ? Duration.zero : fadeAfter, () {
      _fading = true;
      notifyListeners();
    });
    _hideTimer = Timer(duration, () {
      _message = '';
      _fading = false;
      notifyListeners();
    });
  }

  void clear() {
    _fadeTimer?.cancel();
    _hideTimer?.cancel();
    _message = '';
    _fading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    _hideTimer?.cancel();
    super.dispose();
  }
}
