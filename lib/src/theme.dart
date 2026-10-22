import 'package:flutter/material.dart';

/// Design tokens copied verbatim from the web app's style.css :root block plus
/// the hard-coded colours used outside it.
///
/// The values no longer live in [AppColors] as compile-time constants: the
/// settings dialog lets the user pick a colour scheme and a light/dark mode, so
/// every token is now read through a runtime [AppPalette]. The **default**
/// palette still carries the exact hex values the web build used, so an
/// untouched install renders identically to before.
///
/// [AppColors] keeps its historical static field names (AppColors.bg,
/// AppColors.accent, ...) so no widget had to change shape; they are getters
/// over the active palette now. Widgets that used them inside a const
/// expression had to drop that const, because the values are no longer
/// compile-time constants.

/// One selectable colour scheme (the theme colour picker in settings).
///
/// A preset only carries the tokens that carry the app's identity - accent,
/// topbar and link colours - for both a light and a dark base. Every neutral
/// surface token comes from [AppPalette.lightBase] / [AppPalette.darkBase], so
/// adding a preset is a handful of colours rather than a whole palette.
class AppThemePreset {
  const AppThemePreset({
    required this.id,
    required this.labelZh,
    required this.labelEn,
    required this.accent,
    required this.header,
    required this.header2,
    required this.link,
    required this.linkHover,
    required this.focusRing,
    required this.focusBorder,
    required this.darkAccent,
    required this.darkHeader,
    required this.darkHeader2,
    required this.darkLink,
    required this.darkLinkHover,
    required this.darkFocusRing,
    required this.darkFocusBorder,
  });

  final String id;
  final String labelZh;
  final String labelEn;

  final Color accent;
  final Color header;
  final Color header2;
  final Color link;
  final Color linkHover;
  final Color focusRing;
  final Color focusBorder;

  final Color darkAccent;
  final Color darkHeader;
  final Color darkHeader2;
  final Color darkLink;
  final Color darkLinkHover;
  final Color darkFocusRing;
  final Color darkFocusBorder;

  /// Swatch shown in the settings picker (the light accent).
  Color get swatch => accent;
}

/// Every colour scheme the app offers. 'default' reproduces the original web
/// palette exactly; the others only swap the identity colours.
const List<AppThemePreset> kThemePresets = <AppThemePreset>[
  AppThemePreset(
    id: 'default',
    labelZh: '默认',
    labelEn: 'Default',
    accent: Color(0xFFF5A623),
    header: Color(0xFF2B3A55),
    header2: Color(0xFF1F2B40),
    link: Color(0xFF1B5FAA),
    linkHover: Color(0xFF0C3F7A),
    focusRing: Color(0xFFCFE0F5),
    focusBorder: Color(0xFF8FB4E0),
    darkAccent: Color(0xFFF5A623),
    darkHeader: Color(0xFF1B2433),
    darkHeader2: Color(0xFF141B26),
    darkLink: Color(0xFF6FA8E8),
    darkLinkHover: Color(0xFF8FBEF5),
    darkFocusRing: Color(0xFF27405E),
    darkFocusBorder: Color(0xFF3E6FA8),
  ),
  AppThemePreset(
    id: 'indigo',
    labelZh: '靛蓝',
    labelEn: 'Indigo',
    accent: Color(0xFF4F46E5),
    header: Color(0xFF2A2F5B),
    header2: Color(0xFF1E2244),
    link: Color(0xFF4338CA),
    linkHover: Color(0xFF322CA0),
    focusRing: Color(0xFFD8D6FB),
    focusBorder: Color(0xFF9A93EE),
    darkAccent: Color(0xFF8B85F5),
    darkHeader: Color(0xFF1E2140),
    darkHeader2: Color(0xFF171932),
    darkLink: Color(0xFF9C97F8),
    darkLinkHover: Color(0xFFB6B2FA),
    darkFocusRing: Color(0xFF2A2A5C),
    darkFocusBorder: Color(0xFF4A45A8),
  ),
  AppThemePreset(
    id: 'teal',
    labelZh: '青绿',
    labelEn: 'Teal',
    accent: Color(0xFF0D9488),
    header: Color(0xFF1F4448),
    header2: Color(0xFF173436),
    link: Color(0xFF0F766E),
    linkHover: Color(0xFF0B5A54),
    focusRing: Color(0xFFCFEAE7),
    focusBorder: Color(0xFF6FC7BF),
    darkAccent: Color(0xFF2DD4BF),
    darkHeader: Color(0xFF16383A),
    darkHeader2: Color(0xFF102B2D),
    darkLink: Color(0xFF5EEAD4),
    darkLinkHover: Color(0xFF99F6E4),
    darkFocusRing: Color(0xFF1E4A47),
    darkFocusBorder: Color(0xFF2E8B80),
  ),
  AppThemePreset(
    id: 'forest',
    labelZh: '森林',
    labelEn: 'Forest',
    accent: Color(0xFF16A34A),
    header: Color(0xFF22492F),
    header2: Color(0xFF183723),
    link: Color(0xFF15803D),
    linkHover: Color(0xFF106029),
    focusRing: Color(0xFFD2EEDA),
    focusBorder: Color(0xFF7CC79A),
    darkAccent: Color(0xFF4ADE80),
    darkHeader: Color(0xFF1B3A26),
    darkHeader2: Color(0xFF142C1D),
    darkLink: Color(0xFF86EFAC),
    darkLinkHover: Color(0xFFBBF7D0),
    darkFocusRing: Color(0xFF1F4A30),
    darkFocusBorder: Color(0xFF2F8A54),
  ),
  AppThemePreset(
    id: 'rose',
    labelZh: '玫瑰',
    labelEn: 'Rose',
    accent: Color(0xFFE11D48),
    header: Color(0xFF4C2431),
    header2: Color(0xFF3A1B25),
    link: Color(0xFFBE123C),
    linkHover: Color(0xFF93102F),
    focusRing: Color(0xFFF7D4DC),
    focusBorder: Color(0xFFE88AA0),
    darkAccent: Color(0xFFFB7185),
    darkHeader: Color(0xFF3A1D26),
    darkHeader2: Color(0xFF2C161D),
    darkLink: Color(0xFFFDA4AF),
    darkLinkHover: Color(0xFFFECDD3),
    darkFocusRing: Color(0xFF4E2230),
    darkFocusBorder: Color(0xFFA84256),
  ),
  AppThemePreset(
    id: 'violet',
    labelZh: '紫罗兰',
    labelEn: 'Violet',
    accent: Color(0xFF7C3AED),
    header: Color(0xFF3B2A5C),
    header2: Color(0xFF2C1F45),
    link: Color(0xFF6D28D9),
    linkHover: Color(0xFF531FA8),
    focusRing: Color(0xFFE4D9FB),
    focusBorder: Color(0xFFB392F0),
    darkAccent: Color(0xFFA78BFA),
    darkHeader: Color(0xFF2C2145),
    darkHeader2: Color(0xFF211936),
    darkLink: Color(0xFFC4B5FD),
    darkLinkHover: Color(0xFFDDD6FE),
    darkFocusRing: Color(0xFF3A2C5C),
    darkFocusBorder: Color(0xFF7A5FC4),
  ),
];

/// Ids accepted by the theme colour picker / the Rust theme_color setting.
const List<String> kThemePresetIds = <String>[
  'default',
  'indigo',
  'teal',
  'forest',
  'rose',
  'violet',
];

/// Ids accepted for the light/dark setting (mirrors Settings.theme).
const List<String> kThemeModes = <String>['system', 'light', 'dark'];

const String kDefaultThemeMode = 'system';
const String kDefaultThemePreset = 'default';

/// Resolve a preset id, falling back to 'default' for unknown values (an old
/// settings file, or a hand-edited one).
AppThemePreset themePresetById(String id) {
  for (final preset in kThemePresets) {
    if (preset.id == id) return preset;
  }
  return kThemePresets.first;
}

String normalizeThemeMode(String raw) =>
    kThemeModes.contains(raw) ? raw : kDefaultThemeMode;

String normalizeThemePreset(String? raw) {
  final id = raw ?? '';
  return kThemePresetIds.contains(id) ? id : kDefaultThemePreset;
}

/// A complete, immutable colour set. Widgets never read this directly; they use
/// the [AppColors] getters, which read the active instance.
class AppPalette {
  const AppPalette({
    required this.dark,
    required this.presetId,
    required this.bg,
    required this.panel,
    required this.border,
    required this.header,
    required this.header2,
    required this.accent,
    required this.link,
    required this.linkHover,
    required this.muted,
    required this.danger,
    required this.ok,
    required this.code,
    required this.sidebar,
    required this.bodyText,
    required this.topbarMeta,
    required this.topbarLink,
    required this.logoutBorder,
    required this.logoutHoverBg,
    required this.sidebarHead,
    required this.dbItemHover,
    required this.dbItemActive,
    required this.tableLink,
    required this.btnHoverBg,
    required this.btnHoverBorder,
    required this.focusRing,
    required this.focusBorder,
    required this.cardHeading,
    required this.chipBg,
    required this.dbPickBg,
    required this.rowEven,
    required this.rowSelected,
    required this.filterRow,
    required this.nullText,
    required this.blobText,
    required this.blobBg,
    required this.typeText,
    required this.errBg,
    required this.errBorder,
    required this.errText,
    required this.okBg,
    required this.okBorder,
    required this.okText,
    required this.infoBg,
    required this.infoBorder,
    required this.infoText,
    required this.warnBg,
    required this.warnBorder,
    required this.warnText,
    required this.sqlPreviewBg,
    required this.sqlPreviewText,
  });

  /// True when this is the dark variant.
  final bool dark;

  /// The identity preset this palette was built from.
  final String presetId;

  final Color bg;
  final Color panel;
  final Color border;
  final Color header;
  final Color header2;
  final Color accent;
  final Color link;
  final Color linkHover;
  final Color muted;
  final Color danger;
  final Color ok;
  final Color code;
  final Color sidebar;
  final Color bodyText;

  // Topbar
  final Color topbarMeta;
  final Color topbarLink;
  final Color logoutBorder;
  final Color logoutHoverBg;

  // Sidebar
  final Color sidebarHead;
  final Color dbItemHover;
  final Color dbItemActive;
  final Color tableLink;

  // Controls
  final Color btnHoverBg;
  final Color btnHoverBorder;
  final Color focusRing;
  final Color focusBorder;

  // Cards / chips
  final Color cardHeading;
  final Color chipBg;
  final Color dbPickBg;

  // Tables
  final Color rowEven;
  final Color rowSelected;
  final Color filterRow;
  final Color nullText;
  final Color blobText;
  final Color blobBg;
  final Color typeText;

  // Alerts
  final Color errBg;
  final Color errBorder;
  final Color errText;
  final Color okBg;
  final Color okBorder;
  final Color okText;
  final Color infoBg;
  final Color infoBorder;
  final Color infoText;
  final Color warnBg;
  final Color warnBorder;
  final Color warnText;

  final Color sqlPreviewBg;
  final Color sqlPreviewText;

  LinearGradient get topbarGradient => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[header, header2],
      );

  /// Copy of this palette with the identity tokens of [preset] applied.
  /// The preset's dark colours are used when this palette is dark.
  AppPalette withPreset(AppThemePreset preset) {
    return AppPalette(
      dark: dark,
      presetId: preset.id,
      bg: bg,
      panel: panel,
      border: border,
      header: dark ? preset.darkHeader : preset.header,
      header2: dark ? preset.darkHeader2 : preset.header2,
      accent: dark ? preset.darkAccent : preset.accent,
      link: dark ? preset.darkLink : preset.link,
      linkHover: dark ? preset.darkLinkHover : preset.linkHover,
      muted: muted,
      danger: danger,
      ok: ok,
      code: code,
      sidebar: sidebar,
      bodyText: bodyText,
      topbarMeta: topbarMeta,
      topbarLink: topbarLink,
      logoutBorder: logoutBorder,
      logoutHoverBg: logoutHoverBg,
      sidebarHead: sidebarHead,
      dbItemHover: dbItemHover,
      dbItemActive: dbItemActive,
      tableLink: tableLink,
      btnHoverBg: btnHoverBg,
      btnHoverBorder: btnHoverBorder,
      focusRing: dark ? preset.darkFocusRing : preset.focusRing,
      focusBorder: dark ? preset.darkFocusBorder : preset.focusBorder,
      cardHeading: cardHeading,
      chipBg: chipBg,
      dbPickBg: dbPickBg,
      rowEven: rowEven,
      rowSelected: rowSelected,
      filterRow: filterRow,
      nullText: nullText,
      blobText: blobText,
      blobBg: blobBg,
      typeText: typeText,
      errBg: errBg,
      errBorder: errBorder,
      errText: errText,
      okBg: okBg,
      okBorder: okBorder,
      okText: okText,
      infoBg: infoBg,
      infoBorder: infoBorder,
      infoText: infoText,
      warnBg: warnBg,
      warnBorder: warnBorder,
      warnText: warnText,
      sqlPreviewBg: sqlPreviewBg,
      sqlPreviewText: sqlPreviewText,
    );
  }

  /// The original web palette, verbatim. Must stay in sync with
  /// web/src/style.css - the goldens are generated against these values.
  static const AppPalette lightBase = AppPalette(
    dark: false,
    presetId: 'default',
    bg: Color(0xFFF2F4F7),
    panel: Color(0xFFFFFFFF),
    border: Color(0xFFD7DDE5),
    header: Color(0xFF2B3A55),
    header2: Color(0xFF1F2B40),
    accent: Color(0xFFF5A623),
    link: Color(0xFF1B5FAA),
    linkHover: Color(0xFF0C3F7A),
    muted: Color(0xFF6B7684),
    danger: Color(0xFFC0392B),
    ok: Color(0xFF1E7E46),
    code: Color(0xFFF6F8FA),
    sidebar: Color(0xFFEEF1F6),
    bodyText: Color(0xFF20262E),
    topbarMeta: Color(0xFFC8D2E0),
    topbarLink: Color(0xFFDCE6F5),
    logoutBorder: Color(0xFF4A5B78),
    logoutHoverBg: Color(0xFF3B4D6B),
    sidebarHead: Color(0xFF37455C),
    dbItemHover: Color(0xFFE2E8F2),
    dbItemActive: Color(0xFFD8E3F4),
    tableLink: Color(0xFF46566E),
    btnHoverBg: Color(0xFFF4F7FB),
    btnHoverBorder: Color(0xFFB9C4D2),
    focusRing: Color(0xFFCFE0F5),
    focusBorder: Color(0xFF8FB4E0),
    cardHeading: Color(0xFF37455C),
    chipBg: Color(0xFFF4F7FB),
    dbPickBg: Color(0xFFEEF2F8),
    rowEven: Color(0xFFFAFBFD),
    rowSelected: Color(0xFFE8F1FD),
    filterRow: Color(0xFFF7F9FC),
    nullText: Color(0xFF9AA4B2),
    blobText: Color(0xFF8A5A00),
    blobBg: Color(0xFFFFF4D8),
    typeText: Color(0xFF7A5BB0),
    errBg: Color(0xFFFDECEA),
    errBorder: Color(0xFFF3C0BA),
    errText: Color(0xFF8C2318),
    okBg: Color(0xFFE8F6EE),
    okBorder: Color(0xFFB7E0C8),
    okText: Color(0xFF14603A),
    infoBg: Color(0xFFEAF2FB),
    infoBorder: Color(0xFFC3D9F2),
    infoText: Color(0xFF1C4D86),
    warnBg: Color(0xFFFFF0D5),
    warnBorder: Color(0xFFE78B18),
    warnText: Color(0xFFB54708),
    sqlPreviewBg: Color(0xFF101C2E),
    sqlPreviewText: Color(0xFFD7E3F4),
  );

  /// The dark counterpart of [lightBase]. Status colours keep their meaning but
  /// are re-tuned so they stay legible on dark surfaces.
  static const AppPalette darkBase = AppPalette(
    dark: true,
    presetId: 'default',
    bg: Color(0xFF0F141A),
    panel: Color(0xFF161D26),
    border: Color(0xFF2A3542),
    header: Color(0xFF1B2433),
    header2: Color(0xFF141B26),
    accent: Color(0xFFF5A623),
    link: Color(0xFF6FA8E8),
    linkHover: Color(0xFF8FBEF5),
    muted: Color(0xFF93A0B0),
    danger: Color(0xFFE5685A),
    ok: Color(0xFF4FBF85),
    code: Color(0xFF131922),
    sidebar: Color(0xFF121922),
    bodyText: Color(0xFFE4EAF2),
    topbarMeta: Color(0xFFA8B6C9),
    topbarLink: Color(0xFFD2DEED),
    logoutBorder: Color(0xFF3B4759),
    logoutHoverBg: Color(0xFF2A3646),
    sidebarHead: Color(0xFFC3CEDD),
    dbItemHover: Color(0xFF1E2732),
    dbItemActive: Color(0xFF25313F),
    tableLink: Color(0xFFAEBBCB),
    btnHoverBg: Color(0xFF1E2733),
    btnHoverBorder: Color(0xFF3A4757),
    focusRing: Color(0xFF27405E),
    focusBorder: Color(0xFF3E6FA8),
    cardHeading: Color(0xFFC3CEDD),
    chipBg: Color(0xFF1E2733),
    dbPickBg: Color(0xFF1B232D),
    rowEven: Color(0xFF141B24),
    rowSelected: Color(0xFF1D2C3E),
    filterRow: Color(0xFF131A23),
    nullText: Color(0xFF6C7A8A),
    blobText: Color(0xFFF0C97A),
    blobBg: Color(0xFF3A2E12),
    typeText: Color(0xFFC0A6F0),
    errBg: Color(0xFF3A1F1C),
    errBorder: Color(0xFF6B3330),
    errText: Color(0xFFF3B0A8),
    okBg: Color(0xFF16301F),
    okBorder: Color(0xFF2E5B40),
    okText: Color(0xFF8FE0B4),
    infoBg: Color(0xFF16263A),
    infoBorder: Color(0xFF2C4A70),
    infoText: Color(0xFF9CC6F5),
    warnBg: Color(0xFF3A2C12),
    warnBorder: Color(0xFF8A5B12),
    warnText: Color(0xFFF0C173),
    sqlPreviewBg: Color(0xFF0B121C),
    sqlPreviewText: Color(0xFFC9D8EC),
  );
}

/// Build the palette for a mode (system / light / dark) and preset id.
///
/// [platformBrightness] is only consulted for system, so a test can force
/// either base without touching the platform channel.
AppPalette resolvePalette({
  required String mode,
  required String presetId,
  Brightness platformBrightness = Brightness.light,
}) {
  final resolved = normalizeThemeMode(mode);
  final dark = resolved == 'dark' ||
      (resolved == 'system' && platformBrightness == Brightness.dark);
  final base = dark ? AppPalette.darkBase : AppPalette.lightBase;
  return base.withPreset(themePresetById(normalizeThemePreset(presetId)));
}

/// The active palette plus the static token accessors every widget uses.
class AppColors {
  AppColors._();

  static AppPalette _palette = AppPalette.lightBase;

  /// The palette currently in effect.
  static AppPalette get palette => _palette;

  /// Fires whenever [apply] swaps the palette so the app root can rebuild the
  /// MaterialApp theme and repaint every view.
  static final ValueNotifier<AppPalette> notifier =
      ValueNotifier<AppPalette>(_palette);

  /// Bumped on every palette change; handy for ValueKeys in tests.
  static int get revision => _revision;
  static int _revision = 0;

  /// Make [next] the active palette and notify listeners.
  static void apply(AppPalette next) {
    if (identical(next, _palette)) return;
    _palette = next;
    _revision++;
    notifier.value = next;
  }

  /// Resolve and apply in one step (used by bootstrap and the settings dialog).
  static AppPalette applyAppearance({
    required String mode,
    required String presetId,
    Brightness platformBrightness = Brightness.light,
  }) {
    final next = resolvePalette(
      mode: mode,
      presetId: presetId,
      platformBrightness: platformBrightness,
    );
    apply(next);
    return next;
  }

  static Color get bg => _palette.bg;
  static Color get panel => _palette.panel;
  static Color get border => _palette.border;
  static Color get header => _palette.header;
  static Color get header2 => _palette.header2;
  static Color get accent => _palette.accent;
  static Color get link => _palette.link;
  static Color get linkHover => _palette.linkHover;
  static Color get muted => _palette.muted;
  static Color get danger => _palette.danger;
  static Color get ok => _palette.ok;
  static Color get code => _palette.code;
  static Color get sidebar => _palette.sidebar;
  static Color get bodyText => _palette.bodyText;

  // Topbar
  static Color get topbarMeta => _palette.topbarMeta;
  static Color get topbarLink => _palette.topbarLink;
  static Color get logoutBorder => _palette.logoutBorder;
  static Color get logoutHoverBg => _palette.logoutHoverBg;

  // Sidebar
  static Color get sidebarHead => _palette.sidebarHead;
  static Color get dbItemHover => _palette.dbItemHover;
  static Color get dbItemActive => _palette.dbItemActive;
  static Color get tableLink => _palette.tableLink;

  // Controls
  static Color get btnHoverBg => _palette.btnHoverBg;
  static Color get btnHoverBorder => _palette.btnHoverBorder;
  static Color get focusRing => _palette.focusRing;
  static Color get focusBorder => _palette.focusBorder;

  // Cards / chips
  static Color get cardHeading => _palette.cardHeading;
  static Color get chipBg => _palette.chipBg;
  static Color get dbPickBg => _palette.dbPickBg;

  // Tables
  static Color get rowEven => _palette.rowEven;
  static Color get rowSelected => _palette.rowSelected;
  static Color get filterRow => _palette.filterRow;
  static Color get nullText => _palette.nullText;
  static Color get blobText => _palette.blobText;
  static Color get blobBg => _palette.blobBg;
  static Color get typeText => _palette.typeText;

  // Alerts
  static Color get errBg => _palette.errBg;
  static Color get errBorder => _palette.errBorder;
  static Color get errText => _palette.errText;
  static Color get okBg => _palette.okBg;
  static Color get okBorder => _palette.okBorder;
  static Color get okText => _palette.okText;
  static Color get infoBg => _palette.infoBg;
  static Color get infoBorder => _palette.infoBorder;
  static Color get infoText => _palette.infoText;
  static Color get warnBg => _palette.warnBg;
  static Color get warnBorder => _palette.warnBorder;
  static Color get warnText => _palette.warnText;

  static Color get sqlPreviewBg => _palette.sqlPreviewBg;
  static Color get sqlPreviewText => _palette.sqlPreviewText;

  static LinearGradient get topbarGradient => _palette.topbarGradient;
}

/// Spacing / sizing constants shared by the shell and the views.
class AppMetrics {
  AppMetrics._();

  static const sidebarWidth = 268.0;
  static const sidebarWidthNarrow = 200.0;
  static const topbarHeight = 48.0;
  static const mainPadding = 16.0;
  static const mainPaddingNarrow = 10.0;
  static const cardPadding = 14.0;
  static const radiusControl = 4.0;
  static const radiusCard = 6.0;
  static const radiusModal = 8.0;
}

const List<String> kMonoFallback = <String>[
  'SF Mono',
  'Menlo',
  'Consolas',
  'Courier New',
  'monospace',
];

/// Material theme tuned so built-in widgets (dialogs, dropdowns, tooltips,
/// scrollbars) match the hand-styled UI instead of Material defaults.
///
/// Reads the active [AppColors] palette, so it must be called again after
/// [AppColors.apply] (the app root does that through [AppColors.notifier]).
ThemeData buildAppTheme() {
  final scheme = ColorScheme.light(
    primary: AppColors.header,
    onPrimary: Colors.white,
    secondary: AppColors.accent,
    onSecondary: const Color(0xFF222222),
    surface: AppColors.panel,
    onSurface: AppColors.bodyText,
    error: AppColors.danger,
    onError: Colors.white,
    outline: AppColors.border,
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: AppColors.bg,
    canvasColor: AppColors.panel,
    dividerColor: AppColors.border,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    // No explicit fontFamily: Flutter then uses the platform UI font, which on
    // macOS is San Francisco. The web app's stack starts with -apple-system,
    // so this matches, and it keeps CJK glyphs available (hard-coding a Latin
    // family such as Helvetica Neue renders Chinese as tofu boxes).
  );

  return base.copyWith(
    tooltipTheme: const TooltipThemeData(
      decoration: BoxDecoration(
        color: Color(0xF01F2B40),
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      textStyle: TextStyle(color: Colors.white, fontSize: 12),
      waitDuration: Duration(milliseconds: 400),
      // A tooltip must never cover the window. Flutter's default only sets a
      // minimum height, so a long value (a JSON cell, a stack trace, a list of
      // SQL warnings) wrapped at the width limit and grew as tall as it needed:
      // measured 592px tall on a 600px window, i.e. it effectively blanked the
      // screen. Bounding both axes keeps the popup readable; the full value
      // stays reachable through the grid's double-click viewer / copy. Sites
      // that pass their own Tooltip.constraints must repeat the maxHeight,
      // because a widget value overrides the theme.
      constraints: kTooltipConstraints,
    ),
    // The thumb used to be a fixed 33% black. That reads fine on the light
    // palette and is effectively invisible on the dark one: composited over the
    // dark panel (#161D26) it lands within ~7/255 of the background, so a
    // scrollable area looked like it had no scrollbar at all (reported as
    // "结果浏览无法左右拖动" in the query builder). Deriving it from the muted
    // text colour keeps the thumb visible on both palettes; buildAppTheme() is
    // rebuilt whenever the palette changes, so the colour follows the theme.
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(8),
      radius: const Radius.circular(4),
      thumbColor: WidgetStateProperty.resolveWith((states) => AppColors.muted
          .withValues(alpha: states.contains(WidgetState.hovered) ? 0.55 : 0.38)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
  );
}

/// Size cap for every hover tooltip.
///
/// Tooltip only sets a *minimum* height by default: the text wraps at the
/// width then grows as tall as it needs, so a long JSON cell or a stack trace
/// produced a bubble covering most of the window (measured 592px tall on a
/// 600px-high window). Both axes are capped here and every widget-level
/// Tooltip(constraints: ...) uses this helper so a long value can never
/// expand the popup over the UI. The complete value stays available through the
/// grid's double-click viewer, the copy action and EllipsisText.
const BoxConstraints kTooltipConstraints =
    BoxConstraints(maxWidth: 480, maxHeight: 320);

/// 13px regular text, the web app's base size.
///
/// These are getters, not constants, because the colour follows the active
/// palette (a const style would freeze the light-theme colour into a dark UI).
TextStyle get kBody => TextStyle(fontSize: 13, color: AppColors.bodyText);
TextStyle get kMuted => TextStyle(fontSize: 13, color: AppColors.muted);
TextStyle get kSmall => TextStyle(fontSize: 12, color: AppColors.bodyText);
TextStyle get kSmallMuted => TextStyle(fontSize: 12, color: AppColors.muted);

/// Monospace style for SQL, identifiers and cell values.
TextStyle monoStyle({double size = 13, Color? color, FontWeight? weight}) {
  return TextStyle(
    fontFamilyFallback: kMonoFallback,
    fontSize: size,
    color: color ?? AppColors.bodyText,
    fontWeight: weight,
  );
}
