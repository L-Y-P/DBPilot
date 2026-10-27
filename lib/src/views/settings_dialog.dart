import 'dart:io';

import 'package:flutter/material.dart' hide Text, Tooltip;

import '../api.dart';
import '../app_state.dart';
import '../app_version.dart';
import '../data_dir_overview.dart';
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

/// Test seam for the data-directory summary shown by 「数据与卸载」.
///
/// The real call goes to the Rust core; widget tests substitute a recorder so
/// they can assert what the panel renders without touching a real user
/// directory. Production never reassigns it.
Future<Json> Function() settingsDataDirSummary = Api.instance.dataDirSummary;

/// Test seam for wiping the user data directory.
Future<Json> Function(String confirm) settingsWipeUserData =
    (String confirm) => Api.instance.wipeUserData(confirm: confirm);

/// Test seam for the 打开数据目录 action (the system file manager).
Future<bool> Function(String path) settingsRevealDataDir = revealInFileManager;

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

  // ------------------------------------------------- 数据与卸载面板的状态
  //
  // 全部是面板自己的临时状态：占用数据不放进 AppState，因为它是磁盘扫描的
  // 结果而不是持久设置，每次打开设置重新算一遍反而更准（用户可能在别的
  // 窗口删过东西）。null 表示还没算完（或算失败），面板据此显示占位。
  DataDirOverview? _dataOverview;
  bool _dataLoading = true;
  String? _dataError;
  bool _dataBusy = false;
  int? _removedBytes;

  @override
  void initState() {
    super.initState();
    // 打开设置即扫描一次：用户点进来看的就是「占了多大」，不该再点一下按钮。
    _refreshDataDir();
  }

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

  // -------------------------------------------------------- 数据与卸载展示

  /// 数据目录路径；取不到时给占位，绝不显示空白行。
  String get _dataPathLabel {
    final path = _dataOverview?.path ?? '';
    if (path.isNotEmpty) return path;
    return _dataLoading ? '正在读取数据目录…' : '数据目录不可用';
  }

  /// 占用摘要：`共 12 个文件，3.20 MB`。
  ///
  /// 目录还没创建时不能写 0 B：那会让人以为有东西却清不掉。
  String get _dataSizeLabel {
    final overview = _dataOverview;
    if (overview == null) {
      return _dataLoading ? '正在统计占用…' : '占用未知';
    }
    if (!overview.exists) return '尚未创建';
    if (overview.fileCount <= 0) return '空目录（0 B）';
    final size = formatBytes(overview.totalBytes);
    return pickText(
      '共 ${overview.fileCount} 个文件，$size',
      '${overview.fileCount} files, $size',
    );
  }

  /// 内容摘要的条目；读不到时为空，调用方据此整块隐藏。
  List<DataDirEntry> get _dataEntries =>
      _dataOverview?.entries ?? const <DataDirEntry>[];

  /// 路径可用才允许「打开数据目录」。
  bool get _dataCanOpen => (_dataOverview?.path ?? '').isNotEmpty;

  /// 目录里确实还有文件才允许清空，免得对着空目录也弹一次确认。
  bool get _dataCanWipe {
    final overview = _dataOverview;
    return overview != null && overview.exists && overview.fileCount > 0;
  }

  // ------------------------------------------------------ 数据与卸载动作

  /// 重新扫描数据目录；失败只记录错误，不抛出。
  ///
  /// Rust 核心未就绪（例如桥接层还没初始化）是很正常的状态，面板必须显示
  /// 占位而不是让整个设置页崩掉，所以这里把所有异常都收敛成 [_dataError]。
  Future<void> _refreshDataDir() async {
    if (mounted) setState(() => _dataLoading = true);
    DataDirOverview? overview;
    String? error;
    try {
      overview = DataDirOverview.fromJson(await settingsDataDirSummary());
    } catch (e) {
      error = e.toString();
    }
    if (!mounted) return;
    setState(() {
      _dataLoading = false;
      _dataOverview = overview;
      _dataError = error;
    });
  }

  /// 清空用户数据：二次确认 → 调 Rust → 重新扫描体积。
  ///
  /// 刻意不自动退出应用：Rust 侧保留着指向刚被删文件的连接池与备份索引，
  /// 退出重启的时机交给用户（提示里写明需要重启才生效）。
  Future<void> _wipeUserData() async {
    if (_dataBusy) return;
    final overview = _dataOverview;
    final confirmed = await confirmDialog(
      context,
      message: '确定清空用户数据吗？',
      detail: overview == null || overview.path.isEmpty
          ? null
          // 路径是数据，先替换进中文原文再交给词典（英文条目里是 {path}）；
          // 直接 noTranslate 会让英文界面露出整句中文。
          : '将删除 {path} 里的全部文件（连接配置、查询历史、设置与备份），此操作不可撤销。'
              .replaceAll('{path}', overview.path),
      confirmLabel: '清空',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    setState(() {
      _dataBusy = true;
      _dataError = null;
      _removedBytes = null;
    });
    try {
      // 确认短语由 API 层提供，UI 不自己拼字面量：Rust 拿不到它就一个文件
      // 都不会动，这是删除路径上唯一的一道硬闸。
      final result = await settingsWipeUserData(wipeUserDataConfirmToken);
      final removed = result['removed_bytes'];
      _removedBytes = removed is num ? removed.toInt() : null;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dataBusy = false;
        _dataError = pickText('清空失败：$e', 'Failed to clear user data: $e');
      });
      return;
    }
    if (!mounted) return;
    setState(() => _dataBusy = false);
    await _refreshDataDir();
  }

  /// 在系统文件管理器里打开数据目录。
  ///
  /// 目录可能还不存在（全新安装，或刚清空后 Rust 尚未重建），此时只提示、
  /// 不抛异常：安装包场景下“点了一下没反应”比一句提示更让人困惑。
  Future<void> _openDataDir() async {
    final path = _dataOverview?.path ?? '';
    if (path.isEmpty) return;
    bool ok;
    try {
      ok = await settingsRevealDataDir(path);
    } catch (_) {
      // 平台进程拉起失败（没有文件管理器、沙箱拒绝）同样只提示。
      if (mounted) setState(() => _dataError = '无法打开目录：$path');
      return;
    }
    if (!mounted) return;
    setState(() {
      if (!ok) _dataError = '无法打开目录：$path';
    });
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
            // 放在「备份」之后、「关于」之前：这是用户要卸载前才会找的东西，
            // 靠后但仍在滚动区内；放在「关于」前也让“数据在哪 / 卸载会不会删”
            // 和版本、更新这些尾部信息连成一段。
            _Section(title: '数据与卸载', children: <Widget>[
              _infoRow(
                '数据目录',
                Text(
                  _dataPathLabel,
                  key: const ValueKey('settings-data-path'),
                  // 路径是数据不是文案：翻译器绝不该改写它。
                  noTranslate: true,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(size: 12, color: AppColors.bodyText),
                ),
              ),
              _infoRow(
                '占用空间',
                Text(
                  _dataSizeLabel,
                  key: const ValueKey('settings-data-size'),
                  noTranslate: true,
                  style: TextStyle(fontSize: 13, color: AppColors.bodyText),
                ),
              ),
              if (_dataEntries.isNotEmpty) ...<Widget>[
                _infoRow(
                  '内容',
                  Column(
                    key: const ValueKey('settings-data-contents'),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (final entry in _dataEntries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            // 文件名与体积是数据，计数是文案：先按语言拼好再点 noTranslate，
                            // 否则英文界面会露出“个文件”。
                            entryRowText(entry),
                            noTranslate: true,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 12, color: AppColors.bodyText),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Btn(
                    '打开数据目录',
                    key: const ValueKey('settings-data-open'),
                    onPressed: _dataCanOpen ? _openDataDir : null,
                  ),
                  Btn(
                    '执行清空…',
                    key: const ValueKey('settings-data-wipe'),
                    danger: true,
                    busy: _dataBusy,
                    onPressed:
                        (_dataBusy || !_dataCanWipe) ? null : _wipeUserData,
                  ),
                  Btn(
                    '刷新',
                    key: const ValueKey('settings-data-refresh'),
                    small: true,
                    busy: _dataLoading && !_dataBusy,
                    onPressed: (_dataLoading || _dataBusy)
                        ? null
                        : _refreshDataDir,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              // 清空成功后的结果提示：说清删了多少、以及为什么现在还不生效。
              if (_removedBytes != null) ...<Widget>[
                AlertBox(
                  '已清空用户数据（释放 ${formatBytes(_removedBytes)}）。重新启动应用后生效。',
                  key: const ValueKey('settings-data-wipe-result'),
                  tone: AlertTone.ok,
                  liveRegion: true,
                ),
                const SizedBox(height: 8),
              ],
              if (_dataError != null) ...<Widget>[
                AlertBox(
                  _dataError!,
                  key: const ValueKey('settings-data-error'),
                  tone: AlertTone.error,
                  liveRegion: true,
                ),
                const SizedBox(height: 8),
              ],
              // 两句话在源码里就是**一个**字符串字面量（相邻字面量拼接）：
              // 英文词典按整句精确匹配，写成两段会被拼成带换行/空格的另一串，
              // 表面看着一样却匹配不上，英文界面就会露出中文（test 已钉住）。
              Text(
                '卸载应用不会自动删除这个目录：卸载前请在这里清空，或卸载后手动删除该路径。'
                    'Windows 安装包在卸载时会询问是否删除用户数据。',
                key: const ValueKey('settings-data-uninstall-hint'),
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
              // 只显示三段式版本号，不带 (build N)：build number 是发版流水线
              // 的内部序号，对用户没有意义；核心版本行也已删除（Rust 与 Dart
              // 同源发布，两个号永远一致，多一行只会让人问「哪个才是版本」）。
              _infoRow(
                '应用版本',
                Text(
                  kAppVersion,
                  key: const ValueKey('settings-version'),
                  noTranslate: true,
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
