// Regression gate for the runtime colour palette.
//
// The settings dialog lets the user pick a light/dark mode and an accent
// preset, so every token became a runtime getter. The DEFAULT palette must
// still be byte-for-byte the web app's palette: an untouched install has to
// render exactly as the web build did. The literals pinned below are copied
// from web/src/style.css (the :root block plus the hard-coded colours used
// outside it), so this test fails the moment a token drifts.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';

/// Every token of [AppPalette.lightBase], as written in web/src/style.css.
const Map<String, Color> _webLightTokens = <String, Color>{
  // :root
  'bg': Color(0xFFF2F4F7),
  'panel': Color(0xFFFFFFFF),
  'border': Color(0xFFD7DDE5),
  'header': Color(0xFF2B3A55),
  'header2': Color(0xFF1F2B40),
  'accent': Color(0xFFF5A623),
  'link': Color(0xFF1B5FAA),
  'linkHover': Color(0xFF0C3F7A),
  'muted': Color(0xFF6B7684),
  'danger': Color(0xFFC0392B),
  'ok': Color(0xFF1E7E46),
  'code': Color(0xFFF6F8FA),
  'sidebar': Color(0xFFEEF1F6),
  // body / topbar
  'bodyText': Color(0xFF20262E),
  'topbarMeta': Color(0xFFC8D2E0),
  'topbarLink': Color(0xFFDCE6F5),
  'logoutBorder': Color(0xFF4A5B78),
  'logoutHoverBg': Color(0xFF3B4D6B),
  // sidebar
  'sidebarHead': Color(0xFF37455C),
  'dbItemHover': Color(0xFFE2E8F2),
  'dbItemActive': Color(0xFFD8E3F4),
  'tableLink': Color(0xFF46566E),
  // controls
  'btnHoverBg': Color(0xFFF4F7FB),
  'btnHoverBorder': Color(0xFFB9C4D2),
  'focusRing': Color(0xFFCFE0F5),
  'focusBorder': Color(0xFF8FB4E0),
  // cards / chips
  'cardHeading': Color(0xFF37455C),
  'chipBg': Color(0xFFF4F7FB),
  'dbPickBg': Color(0xFFEEF2F8),
  // tables
  'rowEven': Color(0xFFFAFBFD),
  'rowSelected': Color(0xFFE8F1FD),
  'filterRow': Color(0xFFF7F9FC),
  'nullText': Color(0xFF9AA4B2),
  'blobText': Color(0xFF8A5A00),
  'blobBg': Color(0xFFFFF4D8),
  'typeText': Color(0xFF7A5BB0),
  // alerts
  'errBg': Color(0xFFFDECEA),
  'errBorder': Color(0xFFF3C0BA),
  'errText': Color(0xFF8C2318),
  'okBg': Color(0xFFE8F6EE),
  'okBorder': Color(0xFFB7E0C8),
  'okText': Color(0xFF14603A),
  'infoBg': Color(0xFFEAF2FB),
  'infoBorder': Color(0xFFC3D9F2),
  'infoText': Color(0xFF1C4D86),
  'warnBg': Color(0xFFFFF0D5),
  'warnBorder': Color(0xFFE78B18),
  'warnText': Color(0xFFB54708),
  'sqlPreviewBg': Color(0xFF101C2E),
  'sqlPreviewText': Color(0xFFD7E3F4),
};

/// The CSS custom-property / hard-coded colour behind each palette token.
List<Color> _lightBaseTokenValues(AppPalette p) => <Color>[
      p.bg,
      p.panel,
      p.border,
      p.header,
      p.header2,
      p.accent,
      p.link,
      p.linkHover,
      p.muted,
      p.danger,
      p.ok,
      p.code,
      p.sidebar,
      p.bodyText,
      p.topbarMeta,
      p.topbarLink,
      p.logoutBorder,
      p.logoutHoverBg,
      p.sidebarHead,
      p.dbItemHover,
      p.dbItemActive,
      p.tableLink,
      p.btnHoverBg,
      p.btnHoverBorder,
      p.focusRing,
      p.focusBorder,
      p.cardHeading,
      p.chipBg,
      p.dbPickBg,
      p.rowEven,
      p.rowSelected,
      p.filterRow,
      p.nullText,
      p.blobText,
      p.blobBg,
      p.typeText,
      p.errBg,
      p.errBorder,
      p.errText,
      p.okBg,
      p.okBorder,
      p.okText,
      p.infoBg,
      p.infoBorder,
      p.infoText,
      p.warnBg,
      p.warnBorder,
      p.warnText,
      p.sqlPreviewBg,
      p.sqlPreviewText,
    ];

void main() {
  tearDown(() {
    // Never leak a preset into another test in this file.
    AppColors.applyAppearance(mode: 'system', presetId: 'default');
  });

  group('default light palette', () {
    test('every token equals the original web constant', () {
      const p = AppPalette.lightBase;
      expect(p.dark, isFalse);
      expect(p.presetId, 'default');
      expect(_webLightTokens.length, 50);
      expect(_lightBaseTokenValues(p).length, _webLightTokens.length,
          reason: 'a token was added/removed; update _webLightTokens too');
      final names = _webLightTokens.keys.toList();
      final values = _lightBaseTokenValues(p);
      for (var i = 0; i < names.length; i++) {
        expect(values[i], _webLightTokens[names[i]],
            reason: 'token ${names[i]} drifted from web/src/style.css');
      }
    });

    test('the resolving default mode reproduces the same tokens', () {
      final resolved =
          resolvePalette(mode: 'system', presetId: 'default', platformBrightness: Brightness.light);
      expect(resolved.dark, isFalse);
      expect(_lightBaseTokenValues(resolved), _lightBaseTokenValues(AppPalette.lightBase));
    });

    test('the dark base is dark and keeps the default identity', () {
      const p = AppPalette.darkBase;
      expect(p.dark, isTrue);
      expect(p.presetId, 'default');
      expect(p.bg, const Color(0xFF0F141A));
      expect(p.accent, const Color(0xFFF5A623));
      expect(p.bodyText, const Color(0xFFE4EAF2));
    });
  });

  group('mode / preset resolution', () {
    test('normalizeThemeMode falls back to system', () {
      expect(normalizeThemeMode('dark'), 'dark');
      expect(normalizeThemeMode('light'), 'light');
      expect(normalizeThemeMode('system'), 'system');
      expect(normalizeThemeMode('nonsense'), kDefaultThemeMode);
      expect(normalizeThemeMode(''), kDefaultThemeMode);
    });

    test('normalizeThemePreset falls back to default', () {
      expect(normalizeThemePreset('indigo'), 'indigo');
      expect(normalizeThemePreset(null), kDefaultThemePreset);
      expect(normalizeThemePreset('nonsense'), kDefaultThemePreset);
    });

    test('every advertised preset id resolves to a real preset', () {
      expect(kThemePresets.map((p) => p.id).toList(), kThemePresetIds);
      for (final id in kThemePresetIds) {
        expect(themePresetById(id).id, id);
      }
      expect(themePresetById('missing').id, 'default');
    });

    test('light / dark / system resolve the right base', () {
      expect(resolvePalette(mode: 'light', presetId: 'default').bg,
          const Color(0xFFF2F4F7));
      expect(resolvePalette(mode: 'dark', presetId: 'default').bg,
          const Color(0xFF0F141A));
      expect(
          resolvePalette(
            mode: 'system',
            presetId: 'default',
            platformBrightness: Brightness.dark,
          ).bg,
          const Color(0xFF0F141A));
      expect(
          resolvePalette(
            mode: 'system',
            presetId: 'default',
            platformBrightness: Brightness.light,
          ).bg,
          const Color(0xFFF2F4F7));
      // A bad mode is treated as system.
      expect(
          resolvePalette(
            mode: 'sepia',
            presetId: 'default',
            platformBrightness: Brightness.dark,
          ).bg,
          const Color(0xFF0F141A));
    });

    test('a preset only swaps the identity tokens', () {
      final light = resolvePalette(mode: 'light', presetId: 'indigo');
      expect(light.accent, const Color(0xFF4F46E5));
      expect(light.header, const Color(0xFF2A2F5B));
      expect(light.link, const Color(0xFF4338CA));
      // Neutral surfaces come from the base, unchanged.
      expect(light.bg, const Color(0xFFF2F4F7));
      expect(light.panel, const Color(0xFFFFFFFF));
      expect(light.bodyText, const Color(0xFF20262E));

      final dark = resolvePalette(mode: 'dark', presetId: 'indigo');
      expect(dark.accent, const Color(0xFF8B85F5));
      expect(dark.header, const Color(0xFF1E2140));
      expect(dark.bg, const Color(0xFF0F141A));

      // An unknown preset id falls back to the default identity.
      expect(resolvePalette(mode: 'light', presetId: 'nope').accent,
          const Color(0xFFF5A623));
    });
  });

  group('AppColors', () {
    test('applyAppearance swaps the getters and notifies listeners', () {
      AppColors.applyAppearance(mode: 'light', presetId: 'default');
      expect(AppColors.bg, const Color(0xFFF2F4F7));
      expect(AppColors.accent, const Color(0xFFF5A623));
      expect(AppColors.palette.presetId, 'default');

      var notifications = 0;
      void listener() => notifications++;
      AppColors.notifier.addListener(listener);
      addTearDown(() => AppColors.notifier.removeListener(listener));
      final before = AppColors.revision;

      final next = AppColors.applyAppearance(mode: 'dark', presetId: 'rose');
      expect(next.presetId, 'rose');
      expect(next.dark, isTrue);
      expect(notifications, 1);
      expect(AppColors.revision, before + 1);
      expect(AppColors.bg, const Color(0xFF0F141A));
      expect(AppColors.accent, const Color(0xFFFB7185));
      expect(AppColors.palette.dark, isTrue);
      expect(AppColors.notifier.value.presetId, 'rose');
    });

    test('getters follow the active palette instead of a frozen const', () {
      AppColors.applyAppearance(mode: 'light', presetId: 'default');
      final lightBody = AppColors.bodyText;
      AppColors.applyAppearance(mode: 'dark', presetId: 'default');
      expect(AppColors.bodyText, isNot(lightBody));
      expect(AppColors.bodyText, const Color(0xFFE4EAF2));
      expect(AppColors.topbarGradient.colors,
          <Color>[const Color(0xFF1B2433), const Color(0xFF141B26)]);
    });
  });
}
