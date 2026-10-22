import 'package:flutter/foundation.dart';

import 'i18n_keys.g.dart';

export 'i18n_keys.g.dart' show AppLang, i18nKeys;

/// Reactive language + translation lookup, mirroring web/src/i18n.ts.
///
/// The dictionary itself lives in the generated i18n_keys.g.dart so the desktop
/// strings cannot drift from the web ones. t() returns the key when it is
/// missing and interpolates {name} placeholders, exactly like the web code.
class I18n {
  I18n._();

  static final ValueNotifier<AppLang> lang = ValueNotifier<AppLang>(AppLang.zh);

  static AppLang get current => lang.value;

  static void setLang(AppLang next) {
    lang.value = next;
  }

  static String t(String key, [Map<String, Object?>? params]) {
    final table = lang.value == AppLang.en ? enDict : zhDict;
    var text = table[key] ?? zhDict[key] ?? key;
    if (params != null && params.isNotEmpty) {
      params.forEach((k, v) {
        text = text.replaceAll('{$k}', v?.toString() ?? '');
      });
    }
    return text;
  }
}

/// Convenience top-level alias so views can write t('key').
String t(String key, [Map<String, Object?>? params]) => I18n.t(key, params);
