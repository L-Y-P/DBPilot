import 'dart:io';

import 'package:flutter/material.dart' hide Text, Tooltip;

import '../app_state.dart';
import '../app_version.dart';
import '../external_links.dart';
import '../i18n.dart';
import '../i18n_literals.dart';
import '../sqlite_sources.dart';
import '../text.dart';
import '../theme.dart';
import '../tooltip.dart';
import '../update_apply.dart';
import '../update_check.dart';
import '../update_download.dart';
import '../update_source.dart';
import '../widgets.dart';

/// Test seam for the native folder chooser.
///
/// `flutter test` has no platform channel, so a widget test that presses
/// 更改 substitutes this function instead of opening a real dialog. Production
/// code never reassigns it.
Future<String?> Function({String? title}) settingsDirPicker = pickFolder;

/// Production update check used by the settings dialog.
Future<UpdateCheckResult> checkUpdatesForSettings(
        String manifestUrl, String currentVersion) =>
    checkForUpdates(manifestUrl: manifestUrl, currentVersion: currentVersion);

/// Test seam for the update check. Production never reassigns it.
Future<UpdateCheckResult> Function(String manifestUrl, String currentVersion)
    settingsUpdateCheck = checkUpdatesForSettings;

/// Test seam for downloading an update package.
Future<File> Function({
  required String url,
  required Directory directory,
  required String fileName,
  required void Function(UpdateDownloadProgress progress) onProgress,
  required bool Function() isCancelled,
}) settingsDownloadUpdate = downloadUpdatePackage;

/// Test seam for installing a downloaded update package.
Future<void> Function(File package, String version) settingsApplyUpdate =
    applyUpdateAndRestart;

/// Test seam for quitting the app once an update has been applied.
void Function(int code) settingsExitApp = exit;

/// The settings dialog: language, appearance, backups and the update check.
///
/// Opened from the topbar's 设置 button. Every change applies immediately (the
/// palette is swapped through [AppColors]) and is persisted through [AppState];
/// the dialog itself only owns the transient update-check state.
Future<void> showSettingsDialog(BuildContext context) async {
  final handle = ModalHandle();
  await showModalShell<void>(
    context: context,
    title: '设置',
    handle: handle,
    builder: (context, _) => const _SettingsBody(),
    actions: <Widget>[
      Btn('关闭', onPressed: () => handle.close()),
    ],
  );
}

class _SettingsBody extends StatefulWidget {
  const _SettingsBody();

  @override
  State<_SettingsBody> createState() => _SettingsBodyState();
}

class _SettingsBodyState extends State<_SettingsBody> {
  bool _checking = false;
  UpdateCheckResult? _result;
  bool _linkOpenFailed = false;

  /// Non-null while the automatic download/install is running.
  _UpdatePhase? _phase;
  int _received = 0;
  int? _total;
  String? _updateError;
  bool _cancelRequested = false;

  Future<void> _setLanguage(AppLang lang) async {
    await AppState.instance.setLanguage(lang);
    if (mounted) setState(() {});
  }

  Future<void> _setMode(String mode) async {
    await AppState.instance.setThemeMode(mode);
    if (mounted) setState(() {});
  }

  Future<void> _setColor(String presetId) async {
    await AppState.instance.setThemeColor(presetId);
    if (mounted) setState(() {});
  }

  Future<void> _setAutoColumnWidth(bool value) async {
    await AppState.instance.setAutoColumnWidth(value);
    if (mounted) setState(() {});
  }

  Future<void> _setLazyBigFields(bool value) async {
    await AppState.instance.setLazyBigFields(value);
    if (mounted) setState(() {});
  }

  Future<void> _changeBackupDir() async {
    String? dir;
    try {
      dir = await settingsDirPicker(title: '选择备份保存目录');
    } catch (_) {
      // A failed/cancelled native dialog must not break the settings page.
      dir = null;
    }
    if (dir == null || dir.isEmpty) return;
    await AppState.instance.setBackupDir(dir);
    if (mounted) setState(() {});
  }

  Future<void> _resetBackupDir() async {
    await AppState.instance.setBackupDir('');
    if (mounted) setState(() {});
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    final state = AppState.instance;
    setState(() {
      _checking = true;
      _result = null;
    });
    // The manifest address is fixed at compile time ([kUpdateManifestUrl]); the
    // user can no longer point the check somewhere else, so there is nothing to
    // persist before the request goes out.
    final result = await settingsUpdateCheck(
      kUpdateManifestUrl,
      state.appVersion,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _result = result;
      _updateError = null;
    });
    // Requirement: unlike a plain "is there a newer version?" check, this
    // flow downloads and installs the update automatically, then restarts.
    if (result.hasUpdate) {
      await _autoUpdate(result);
    }
  }

  /// Downloads the package for [result] and applies it, restarting the app.
  ///
  /// Automatically started right after a check reports a newer version, so
  /// the only user action is pressing 检查更新. Failures stay in the dialog
  /// with a retry button and the manual browser link as a fallback.
  Future<void> _autoUpdate(UpdateCheckResult result) async {
    if (_phase != null) return;
    final url = autoUpdateAssetUrl(result);
    if (url == null) return; // panel shows the manual fallback
    _cancelRequested = false;
    setState(() {
      _phase = _UpdatePhase.downloading;
      _received = 0;
      _total = null;
      _updateError = null;
    });
    final directory = Directory(
        '${Directory.systemTemp.path}/dbpilot-update-${DateTime.now().millisecondsSinceEpoch}');
    try {
      final package = await settingsDownloadUpdate(
        url: url,
        directory: directory,
        fileName: updateFileNameFromUrl(url),
        onProgress: (UpdateDownloadProgress progress) {
          if (!mounted) return;
          setState(() {
            _received = progress.received;
            _total = progress.total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      setState(() => _phase = _UpdatePhase.installing);
      await settingsApplyUpdate(package, result.latestVersion);
      if (mounted) settingsExitApp(0);
    } on UpdateCancelledException {
      if (!mounted) return;
      setState(() {
        _phase = null;
        _updateError = '已取消更新';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = null;
        _updateError = e is UpdateDownloadException ||
                e is UpdateApplyException
            ? e.toString()
            : '更新失败：$e';
      });
    }
  }

  Future<void> _openUrl(String url) async {
    final ok = await openExternalUrl(url);
    if (!mounted) return;
    setState(() => _linkOpenFailed = !ok);
  }

  /// A link-styled URL that opens in the user's default browser on click.
  ///
  /// Only http(s) URLs reach the OS (see [openUrlInBrowser]); URLs are
  /// language-neutral, hence noTranslate.
  Widget _externalLink(String url, {Key? key}) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => _openUrl(url),
          child: Text(
            url,
            key: key,
            noTranslate: true,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.link,
              decoration: TextDecoration.underline,
              decorationColor: AppColors.link,
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(
          <Listenable>[AppState.instance, AppColors.notifier, I18n.lang]),
      builder: (context, _) {
        final state = AppState.instance;
        final effectiveBackupDir = state.backupDir.isNotEmpty
            ? state.backupDir
            : state.defaultBackupDir();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Section(title: '语言', children: <Widget>[
              Row(children: <Widget>[
                Btn('中文',
                    key: const ValueKey('settings-lang-zh'),
                    primary: I18n.current == AppLang.zh,
                    onPressed: () => _setLanguage(AppLang.zh)),
                const SizedBox(width: 8),
                Btn('English',
                    key: const ValueKey('settings-lang-en'),
                    primary: I18n.current == AppLang.en,
                    onPressed: () => _setLanguage(AppLang.en)),
              ]),
            ]),
            _Section(title: '个性化', children: <Widget>[
              _labeled(
                '主题',
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final entry in <List<String>>[
                      <String>['system', '跟随系统'],
                      <String>['light', '浅色'],
                      <String>['dark', '深色'],
                    ])
                      Btn(entry[1],
                          key: ValueKey('settings-mode-${entry[0]}'),
                          small: true,
                          primary: state.themeMode == entry[0],
                          onPressed: () => _setMode(entry[0])),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _labeled(
                '主题色',
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: <Widget>[
                    for (final preset in kThemePresets)
                      _ColorDot(
                        key: ValueKey('settings-color-${preset.id}'),
                        preset: preset,
                        selected: state.themeColor == preset.id,
                        onTap: () => _setColor(preset.id),
                      ),
                  ],
                ),
              ),
            ]),
            // Placed between 个性化 and 备份: both switches change how the
            // data grids render, so they sit next to the appearance controls
            // and ahead of the file-system settings.
            _Section(title: '性能', children: <Widget>[
              CheckBox(
                key: const ValueKey('settings-auto-width'),
                label: '自动调整列宽',
                value: state.autoColumnWidth,
                onChanged: _setAutoColumnWidth,
              ),
              CheckBox(
                key: const ValueKey('settings-lazy-fields'),
                label: '大字段延迟加载',
                value: state.lazyBigFields,
                onChanged: _setLazyBigFields,
              ),
              const SizedBox(height: 6),
              Text(
                '关闭自动列宽后所有列使用固定宽度，宽表首帧更快；'
                '大字段延迟加载只渲染长值的前 120 个字符，双击单元格仍可查看完整内容。',
                key: const ValueKey('settings-perf-hint'),
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ]),
            _Section(title: '备份', children: <Widget>[
              _infoRow(
                '备份目录',
                Text(
                  effectiveBackupDir.isEmpty ? '未设置' : effectiveBackupDir,
                  key: const ValueKey('settings-backup-path'),
                  noTranslate: true,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(size: 12, color: AppColors.bodyText),
                ),
              ),
              Row(children: <Widget>[
                Btn('更改',
                    key: const ValueKey('settings-backup-change'),
                    onPressed: _changeBackupDir),
                const SizedBox(width: 8),
                Btn('恢复默认',
                    key: const ValueKey('settings-backup-reset'),
                    onPressed: _resetBackupDir),
              ]),
              const SizedBox(height: 8),
              Text(
                '备份文件默认保存在数据目录的 backups 子目录，可另选一个位置。',
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
            ]),
            _Section(title: '关于', children: <Widget>[
              Row(children: <Widget>[
                // Product mark packaged from assets/icon/dbpilot_source.png. A
                // missing asset must never break the dialog, hence the empty
                // fallback instead of a thrown exception.
                Image.asset(
                  'assets/images/dbpilot.png',
                  width: 36,
                  height: 36,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
                const SizedBox(width: 10),
                Text(kAppName,
                    noTranslate: true,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.bodyText)),
              ]),
              const SizedBox(height: 8),
              _infoRow(
                '项目地址',
                _externalLink(kUpdateRepoUrl,
                    key: const ValueKey('settings-project-url')),
              ),
              _infoRow(
                '应用版本',
                Text(
                  '$kAppVersion (build $kAppBuildNumber)',
                  key: const ValueKey('settings-version'),
                  noTranslate: true,
                  style: TextStyle(fontSize: 13, color: AppColors.bodyText),
                ),
              ),
              _infoRow(
                '核心版本',
                Text(
                  state.coreVersion.isEmpty ? '未知' : state.coreVersion,
                  key: const ValueKey('settings-core-version'),
                  noTranslate: state.coreVersion.isNotEmpty,
                  style: TextStyle(fontSize: 13, color: AppColors.bodyText),
                ),
              ),
              const SizedBox(height: 4),
              // The update source is fixed (kUpdateManifestUrl), so the row is
              // just the button plus a read-only caption. That removes the old
              // address field, its controller and the P3-11 LayoutBuilder: a
              // single hugging button can no longer overflow a narrow window,
              // and it stays reachable in the default 1282x817 window because
              // the caption wraps instead of pushing it sideways.
              Wrap(
                spacing: 10,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  _checkUpdateButton(),
                  Text(
                    pickText(
                      '更新源：GitHub · $kUpdateRepoLabel',
                      'Update source: GitHub · $kUpdateRepoLabel',
                    ),
                    key: const ValueKey('settings-update-source'),
                    // The caption is already in its final language (pickText
                    // chose it), so the literal translator must not touch it
                    // again — same rule as every other noTranslate value.
                    noTranslate: true,
                    style: TextStyle(fontSize: 12, color: AppColors.muted),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '发现新版本后自动下载并安装（Windows 会请求管理员权限），完成后应用将重启。',
                key: const ValueKey('settings-update-check-hint'),
                style: TextStyle(fontSize: 12, color: AppColors.muted),
              ),
              if (_linkOpenFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '无法打开浏览器，请手动复制链接。',
                    key: const ValueKey('settings-link-error'),
                    style: TextStyle(fontSize: 12, color: AppColors.danger),
                  ),
                ),
              if (_result != null) _resultPanel(_result!),
            ]),
          ],
        );
      },
    );
  }

  Widget _checkUpdateButton() => Btn(
        '检查更新',
        key: const ValueKey('settings-check-update'),
        busy: _checking,
        onPressed: (_checking || _phase != null) ? null : _checkUpdate,
      );

  /// A muted caption followed by its control, mirroring [FormRow]'s rhythm.
  Widget _labeled(String label, Widget child) => Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          SizedBox(
            width: 90,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ),
          Expanded(child: child),
        ],
      );

  Widget _infoRow(String label, Widget value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox(
              width: 90,
              child: Text(label,
                  style: TextStyle(fontSize: 12, color: AppColors.muted)),
            ),
            Expanded(child: value),
          ],
        ),
      );

  Widget _resultPanel(UpdateCheckResult result) {
    if (result.error != null) {
      return AlertBox(
        result.error!,
        key: const ValueKey('settings-update-result'),
        tone: AlertTone.error,
        liveRegion: true,
      );
    }
    if (!result.hasUpdate) {
      return AlertBox(
        '已是最新版本',
        key: const ValueKey('settings-update-result'),
        tone: AlertTone.ok,
        liveRegion: true,
      );
    }
    return Container(
      key: const ValueKey('settings-update-result'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: AppColors.infoBg,
        border: Border.all(color: AppColors.infoBorder),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(children: <Widget>[
            Text('发现新版本：',
                style: TextStyle(fontSize: 13, color: AppColors.infoText)),
            Text(result.latestVersion,
                noTranslate: true,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.infoText)),
          ]),
          if (result.notes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text('更新说明',
                style: TextStyle(fontSize: 12, color: AppColors.infoText)),
            Text(result.notes,
                noTranslate: true,
                style: TextStyle(fontSize: 12, color: AppColors.infoText)),
          ],
          if (result.downloadUrl.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text('下载地址',
                style: TextStyle(fontSize: 12, color: AppColors.infoText)),
            _externalLink(result.downloadUrl,
                key: const ValueKey('settings-download-url')),
          ],
          if (_phase != null) ...<Widget>[
            const SizedBox(height: 8),
            _updateProgressPanel(),
          ] else if (_updateError != null) ...<Widget>[
            const SizedBox(height: 8),
            AlertBox(
              _updateError!,
              key: const ValueKey('settings-update-error'),
              tone: AlertTone.error,
              liveRegion: true,
            ),
            if (autoUpdateAssetUrl(result) != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Btn(
                  '重试自动更新',
                  key: const ValueKey('settings-retry-update'),
                  onPressed: () => _autoUpdate(result),
                ),
              ),
          ] else if (autoUpdateAssetUrl(result) == null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                pickText(
                  '当前安装方式不支持应用内自动更新，请用上面的下载链接手动更新。',
                  'This installation cannot be updated in place; use the download link above to update manually.',
                ),
                key: const ValueKey('settings-update-unsupported'),
                noTranslate: true,
                style: TextStyle(fontSize: 12, color: AppColors.infoText),
              ),
            ),
        ],
      ),
    );
  }

  /// Progress + cancel UI for the automatic download/install flow.
  Widget _updateProgressPanel() {
    final total = _total;
    final downloading = _phase == _UpdatePhase.downloading;
    final fraction = (downloading && total != null && total > 0)
        ? (_received / total).clamp(0.0, 1.0).toDouble()
        : null;
    final receivedMb = (_received / (1024 * 1024)).toStringAsFixed(1);
    final totalMb =
        total == null ? null : (total / (1024 * 1024)).toStringAsFixed(1);
    final label = !downloading
        ? pickText('正在安装更新，应用即将重启…',
            'Installing the update; the app will restart…')
        : _cancelRequested
            ? pickText('正在取消下载…', 'Cancelling the download…')
            : pickText('正在下载更新…', 'Downloading the update…');
    final sizeText = totalMb == null
        ? pickText('已下载 $receivedMb MB', 'Downloaded $receivedMb MB')
        : pickText('已下载 $receivedMb / $totalMb MB',
            'Downloaded $receivedMb / $totalMb MB');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          key: const ValueKey('settings-update-phase'),
          noTranslate: true,
          style: TextStyle(fontSize: 12, color: AppColors.infoText),
        ),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: fraction, minHeight: 6),
        if (downloading) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            sizeText,
            key: const ValueKey('settings-update-progress'),
            noTranslate: true,
            style: TextStyle(fontSize: 12, color: AppColors.infoText),
          ),
          if (!_cancelRequested)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Btn(
                '取消',
                key: const ValueKey('settings-cancel-update'),
                onPressed: () => setState(() => _cancelRequested = true),
              ),
            ),
        ],
      ],
    );
  }
}

/// Where the automatic update flow currently is.
enum _UpdatePhase { downloading, installing }

/// One titled block of the settings dialog.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(title,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.cardHeading)),
          const SizedBox(height: 6),
          Container(height: 1, color: AppColors.border),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

/// One accent-colour swatch of the theme picker.
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    super.key,
    required this.preset,
    required this.selected,
    required this.onTap,
  });

  final AppThemePreset preset;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // P3-08b: [AppThemePreset.labelEn] carried the English names but nothing
    // ever read it, so the swatch's accessibility label (and the tooltip
    // source string) stayed Chinese in English mode. Resolve the name once,
    // for the current language, and mark the tooltip as already-final copy.
    final label = pickText(preset.labelZh, preset.labelEn);
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Tooltip(
        message: label,
        noTranslate: true,
        constraints: kTooltipConstraints,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: preset.swatch,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.bodyText : AppColors.border,
                  width: selected ? 3 : 1,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, size: 14, color: Colors.white)
                  : null,
            ),
          ),
        ),
      ),
    );
  }
}
