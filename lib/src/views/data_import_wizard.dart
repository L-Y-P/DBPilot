import 'dart:async';

import 'package:flutter/material.dart' hide Text, Tooltip;

import '../text.dart';
import '../tooltip.dart';

import '../api.dart';
import '../i18n_literals.dart';
import '../import_rules.dart';
import '../notice.dart';
import '../sqlite_sources.dart';
import '../theme.dart';
import '../widgets.dart';
import 'relation_designer.dart';

/// Open the guided data-file import wizard for one table.
///
/// The wizard is a five-step dialog: choose file -> read rule (worksheet and
/// header for workbooks) -> field rule + column mapping -> execute -> build
/// relations. Every long operation (whole-file validation, import) runs as a
/// Rust job polled through [ImportJobPoller], so a huge file never freezes the
/// UI.
Future<void> showDataImportWizard(
  BuildContext context, {
  required String database,
  required String table,
  required Notice notice,
  Future<void> Function()? onImported,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DataImportWizardDialog(
      database: database,
      table: table,
      notice: notice,
      onImported: onImported,
    ),
  );
}

/// Formats the importer reads as workbooks (one row per worksheet row, values
/// typed by the cell itself) rather than as bytes.
///
/// "excel" is SpreadsheetML (the exporter's XML .xls), the other four are the
/// real workbook container formats the round-50 importer recognises.
const Set<String> _workbookFormats = <String>{
  'excel',
  'xlsx',
  'xls',
  'xlsb',
  'ods',
};

/// How many leading rows a workbook import may skip (0-20).
const int _maxSkipRows = 20;

bool _isWorkbookFormat(String? format) =>
    format != null && _workbookFormats.contains(format);

const int _maxIssuesShown = 15;

class DataImportWizardDialog extends StatefulWidget {
  const DataImportWizardDialog({
    super.key,
    required this.database,
    required this.table,
    required this.notice,
    this.onImported,
  });

  final String database;
  final String table;
  final Notice notice;
  final Future<void> Function()? onImported;

  @override
  State<DataImportWizardDialog> createState() => DataImportWizardDialogState();
}

/// Dialog state.
///
/// Public (like [CreateTableDialogState]) so widget tests can drive the wizard
/// past the native file picker; the product flow only reaches [_pickFile]
/// through the header button.
class DataImportWizardDialogState extends State<DataImportWizardDialog> {
  int _step = 0;
  bool _busy = false;
  String? _error;

  String? _path;
  Json? _inspect;
  Json? _preview;
  List<String> _tableColumns = <String>[];
  Set<String> _autoIncrementColumns = <String>{};

  ImportMappingRule _mapping = ImportMappingRule();
  bool _mappingTouched = false;
  bool _mappingKeyed = true;
  List<String> _keySources = <String>[];
  int _positionalFields = 0;

  String _readMode = 'line';
  String _fieldMode = 'delimited';
  bool _balance = true;
  bool _skipBlank = true;
  bool _trimRecord = true;
  bool _trimFields = true;
  bool _hasHeader = false;

  /// Workbook only: selected worksheet name and leading rows to skip.
  String? _sheet;
  int _skipRows = 0;

  late TextEditingController _wrapperStartCtrl;
  late TextEditingController _wrapperEndCtrl;
  late TextEditingController _recordSepCtrl;
  late TextEditingController _readQuoteCtrl;
  late TextEditingController _fieldSepCtrl;
  late TextEditingController _fieldQuoteCtrl;
  late TextEditingController _escapeCtrl;
  late TextEditingController _nullTokensCtrl;
  late TextEditingController _skipRowsCtrl;

  /// Debounce for re-previewing after typing in a rule field.
  Timer? _previewRefresh;

  Json? _readValidation;
  Json? _fieldValidation;
  Json? _probe;
  bool _readValidated = false;
  bool _fieldValidated = false;
  bool _probeOk = false;

  ImportJobPoller? _poller;
  Json? _jobStatus;
  String? _jobKind;
  bool _executing = false;
  Json? _executeResult;

  int _batchSize = 500;
  String _onError = 'stop';

  @override
  void initState() {
    super.initState();
    _wrapperStartCtrl = TextEditingController();
    _wrapperEndCtrl = TextEditingController();
    _recordSepCtrl = TextEditingController();
    _readQuoteCtrl = TextEditingController();
    _fieldSepCtrl = TextEditingController();
    _fieldQuoteCtrl = TextEditingController();
    _escapeCtrl = TextEditingController();
    _nullTokensCtrl = TextEditingController();
    _skipRowsCtrl = TextEditingController(text: '0');
    _loadStructure();
  }

  @override
  void dispose() {
    _poller?.dispose();
    _previewRefresh?.cancel();
    for (final controller in <TextEditingController>[
      _wrapperStartCtrl,
      _wrapperEndCtrl,
      _recordSepCtrl,
      _readQuoteCtrl,
      _fieldSepCtrl,
      _fieldQuoteCtrl,
      _escapeCtrl,
      _nullTokensCtrl,
      _skipRowsCtrl,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  /// Load [path] as if the native file picker had returned it.
  ///
  /// Tests cannot click a native picker, so they inject the path here and then
  /// walk the same state machine (inspect -> worksheet step -> import) a real
  /// user drives. Product code never calls this.
  @visibleForTesting
  Future<void> loadFileForTest(String path) => _loadFile(path);

  // -------------------------------------------------------------- workbook

  /// True when the inspected file is an Excel / ODS workbook.
  bool get _isExcel => _isWorkbookFormat(_inspect?['format']?.toString());

  /// Step titles; the rule step is named after what it actually configures.
  List<String> get _stepTitles => <String>[
    '选择文件',
    _isExcel ? '工作表与表头' : '读取规则',
    '字段与映射',
    '执行导入',
    '建立关联',
  ];

  /// inspect.sheets entries ({index, name, rows, cols}).
  ///
  /// Empty for text files, for a single-sheet workbook described without
  /// metadata, and for an importer build that predates worksheet support (the
  /// wizard then falls back to the default worksheet).
  List<Json> _sheets() {
    final raw = _inspect?['sheets'];
    if (raw is! List) return const <Json>[];
    return raw
        .map((e) => asJsonMap(e))
        .where((sheet) => (sheet['name'] ?? '').toString().isNotEmpty)
        .toList();
  }

  /// Dropdown label for one worksheet, e.g. Sheet1（120 行 × 5 列）.
  ///
  /// The counts are interpolated, so both variants are built here instead of
  /// relying on the rendered-string translator: the worksheet name is data and
  /// must not be translated, only the rows × cols suffix.
  String _sheetLabel(Json sheet) {
    final name = (sheet['name'] ?? '').toString();
    final rows = (sheet['rows'] as num?)?.toInt();
    final cols = (sheet['cols'] as num?)?.toInt();
    if (rows == null && cols == null) return name;
    final parts = <String>[
      if (rows != null)
        pickText('${formatCount(rows)} 行', '${formatCount(rows)} rows'),
      if (cols != null)
        pickText('${formatCount(cols)} 列', '${formatCount(cols)} cols'),
    ];
    return pickText(
      '$name（${parts.join(' × ')}）',
      '$name (${parts.join(' × ')})',
    );
  }

  /// The worksheet currently shown by the picker (falls back to the first).
  String? get _activeSheet {
    final sheets = _sheets();
    if (sheets.isEmpty) return _sheet;
    final names = sheets.map((s) => (s['name'] ?? '').toString()).toList();
    if (_sheet != null && names.contains(_sheet)) return _sheet;
    return names.first;
  }

  void _selectSheet(String? name) {
    if (name == null || name == _sheet) return;
    setState(() {
      _sheet = name;
      // Different worksheets have different headers, so a mapping built for the
      // previous one is stale: let the preview re-run the automatic mapping.
      _mappingTouched = false;
      _resetValidation();
    });
    // The preview shows the chosen worksheet, so reload it right away (a click
    // is a deliberate action, unlike typing in the skip-rows box).
    _refreshPreview();
  }

  /// Header checkbox shared by the read and field steps.
  void _setHeader(bool value) {
    setState(() {
      _hasHeader = value;
      // Whether the first row is a header changes the column identities the
      // mapping refers to; rebuild the automatic mapping from the new preview.
      _mappingTouched = false;
      _resetValidation();
    });
    _schedulePreviewRefresh();
  }

  void _onSkipRowsChanged(String raw) {
    final parsed = int.tryParse(raw.trim()) ?? 0;
    final clamped = parsed > _maxSkipRows
        ? _maxSkipRows
        : (parsed < 0 ? 0 : parsed);
    if (parsed > _maxSkipRows) {
      // Keep the field honest: the importer only ever skips at most 20 rows.
      _skipRowsCtrl.text = '$clamped';
    }
    if (clamped == _skipRows) return;
    setState(() {
      _skipRows = clamped;
      // Skipping rows can move the header line, so the mapping is rebuilt from
      // the next preview just like after a header toggle.
      _mappingTouched = false;
      _resetValidation();
    });
    _schedulePreviewRefresh();
  }

  /// Re-preview after a rule change, coalescing rapid keystrokes: a workbook is
  /// parsed as a whole by the Rust side, so refreshing on every typed digit
  /// would queue up several full-file reads.
  void _schedulePreviewRefresh() {
    _previewRefresh?.cancel();
    _previewRefresh = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _refreshPreview();
    });
  }

  // ------------------------------------------------------------- structure

  Future<void> _loadStructure() async {
    try {
      final structure = await Api.instance.structure(
        widget.database,
        widget.table,
      );
      if (!mounted) return;
      final columns = (structure['columns'] as List? ?? const <dynamic>[])
          .map((e) => asJsonMap(e))
          .toList();
      setState(() {
        _tableColumns = columns
            .map((c) => (c['name'] ?? '').toString())
            .where((n) => n.isNotEmpty)
            .toList();
        _autoIncrementColumns = columns
            .where(
              (c) => (c['EXTRA'] ?? '').toString().toLowerCase().contains(
                'auto_increment',
              ),
            )
            .map((c) => (c['name'] ?? '').toString())
            .toSet();
      });
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  // ----------------------------------------------------------------- rules

  void _applyRulesToControllers() {
    _readMode = 'line';
    _fieldMode = 'delimited';
    _balance = true;
    _skipBlank = true;
    _trimRecord = true;
    _trimFields = true;
    _hasHeader = false;
    _wrapperStartCtrl.text = '';
    _wrapperEndCtrl.text = '';
    _recordSepCtrl.text = '\\n';
    _readQuoteCtrl.text = '"';
    _fieldSepCtrl.text = ',';
    _fieldQuoteCtrl.text = '"';
    _escapeCtrl.text = '';
    _nullTokensCtrl.text = '\\N';
    _sheet = null;
    _skipRows = 0;
    _skipRowsCtrl.text = '0';
  }

  void _rulesFromInspect(Json inspect) {
    final read = ImportReadRule.fromJson(asJsonMap(inspect['read']));
    final fields = ImportFieldRule.fromJson(asJsonMap(inspect['fields']));
    final format = inspect['format']?.toString();
    _readMode = read.mode;
    _fieldMode = fields.mode;
    _balance = read.balance;
    _skipBlank = read.skipBlank;
    _trimRecord = read.trim;
    _trimFields = fields.trim;
    _hasHeader = fields.header;
    _wrapperStartCtrl.text = encodeEscapes(read.wrapperStart);
    _wrapperEndCtrl.text = encodeEscapes(read.wrapperEnd);
    _recordSepCtrl.text = encodeEscapes(read.recordSep);
    _readQuoteCtrl.text = encodeEscapes(read.quote);
    _fieldSepCtrl.text = encodeEscapes(fields.fieldSep);
    _fieldQuoteCtrl.text = encodeEscapes(fields.quote);
    _escapeCtrl.text = encodeEscapes(fields.escape);

    // Workbook files ignore the text-splitting controls completely: one record
    // is one worksheet row and the value types come from the cells. The rules
    // therefore carry only "which worksheet / how many leading rows to skip".
    _sheet = null;
    _skipRows = 0;
    if (_isWorkbookFormat(format)) {
      _fieldMode = 'excel';
      final suggested = (read.sheet ?? inspect['sheet']?.toString() ?? '')
          .trim();
      final sheets = _sheets();
      if (suggested.isNotEmpty) {
        _sheet = suggested;
      } else if (sheets.isNotEmpty) {
        _sheet = (sheets.first['name'] ?? '').toString();
      }
      final skip = read.skipRows;
      _skipRows = skip > _maxSkipRows ? _maxSkipRows : (skip < 0 ? 0 : skip);
    }
    _skipRowsCtrl.text = '$_skipRows';
  }

  ImportReadRule _readRule() => ImportReadRule(
    mode: _readMode,
    wrapperStart: decodeEscapes(_wrapperStartCtrl.text),
    wrapperEnd: decodeEscapes(_wrapperEndCtrl.text),
    recordSep: decodeEscapes(_recordSepCtrl.text),
    quote: decodeEscapes(_readQuoteCtrl.text),
    balance: _balance,
    skipBlank: _skipBlank,
    trim: _trimRecord,
    sheet: _isExcel ? _activeSheet : null,
    skipRows: _isExcel ? _skipRows : 0,
  );

  ImportFieldRule _fieldRule() => ImportFieldRule(
    mode: _isExcel ? 'excel' : _fieldMode,
    fieldSep: decodeEscapes(_fieldSepCtrl.text),
    quote: decodeEscapes(_fieldQuoteCtrl.text),
    escape: decodeEscapes(_escapeCtrl.text),
    trim: _trimFields,
    header: _hasHeader,
  );

  void _resetValidation() {
    _readValidated = false;
    _fieldValidated = false;
    _probeOk = false;
    _probe = null;
    _readValidation = null;
    _fieldValidation = null;
  }

  // ---------------------------------------------------------------- file IO

  Future<void> _pickFile() async {
    try {
      final path = await pickDataFile(title: '选择要导入的数据文件');
      if (path == null || path.trim().isEmpty) return;
      await _loadFile(path.trim());
    } catch (e) {
      if (mounted) setState(() => _error = describeDbError(e));
    }
  }

  Future<void> _loadFile(String path) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final inspect = await Api.instance.importInspect(path);
      if (!mounted) return;
      setState(() {
        _path = path;
        _inspect = inspect;
        _applyRulesToControllers();
        _rulesFromInspect(inspect);
        _mapping = ImportMappingRule();
        _mappingTouched = false;
        _preview = null;
        _resetValidation();
        _jobStatus = null;
        // A new file starts a new import: a previous run's result must not leak
        // into the execute step (which would offer "next: build relations"
        // before anything was imported again).
        _executeResult = null;
        _executing = false;
        _busy = false;
      });
      await _refreshPreview();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeDbError(e);
        });
      }
    }
  }

  Future<void> _refreshPreview() async {
    final path = _path;
    if (path == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final preview = await Api.instance.importPreview(path, <String, dynamic>{
        'read': _readRule().toJson(),
        'fields': _fieldRule().toJson(),
        'limit': 6,
      });
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _busy = false;
        _resetValidation();
        _updateSources(preview);
        if (!_mappingTouched) _autoMap();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeDbError(e);
        });
      }
    }
  }

  void _updateSources(Json preview) {
    final records = (preview['records'] as List? ?? const <dynamic>[])
        .map((e) => asJsonMap(e))
        .toList();
    final dataRecords = records.where((r) => r['header'] != true).toList();
    final header = preview['header'];
    if (header is List && header.isNotEmpty) {
      _mappingKeyed = true;
      _keySources = header.map((e) => e.toString()).toList();
      return;
    }
    final sample = dataRecords.isNotEmpty
        ? dataRecords.first
        : (records.isNotEmpty ? records.first : null);
    if (sample != null && sample['kind'] == 'object') {
      _mappingKeyed = true;
      _keySources = (sample['keys'] as List? ?? const <dynamic>[])
          .map((e) => e.toString())
          .toList();
    } else {
      _mappingKeyed = false;
      _positionalFields = (sample?['field_count'] as num?)?.toInt() ?? 0;
    }
  }

  void _autoMap() {
    if (_tableColumns.isEmpty) return;
    if (_mappingKeyed) {
      final mapped = autoMapKeyed(_keySources, _tableColumns);
      if (mapped.isNotEmpty) _mapping.columns = mapped;
    } else {
      _mapping.columns = autoMapPositional(
        _positionalFields,
        _tableColumns,
        autoIncrementColumns: _autoIncrementColumns,
      );
    }
  }

  // ----------------------------------------------------------------- jobs

  void _watchJob(String jobId, {required String kind}) {
    _poller?.dispose();
    setState(() {
      _jobKind = kind;
      _jobStatus = null;
    });
    final poller = ImportJobPoller(
      onUpdate: (status) {
        if (!mounted) return;
        setState(() {
          _jobStatus = status;
          if (status['done'] != true) return;
          if (status['state'] == 'failed') {
            _executing = false;
            _error = (status['error'] ?? '任务失败').toString();
            return;
          }
          final result = asJsonMap(status['result']);
          if (kind == 'read') {
            _readValidation = result;
            _readValidated = result['ok'] == true;
          } else if (kind == 'fields') {
            _fieldValidation = result;
            _fieldValidated = result['ok'] == true;
          } else if (kind == 'execute') {
            _executeResult = result;
            _executing = false;
            if (result['ok'] == true) {
              widget.notice.show(
                '导入完成：写入 ${formatCount((result['rows_inserted'] as num?))} 行',
              );
              widget.onImported?.call();
            }
          }
        });
      },
    );
    _poller = poller;
    poller.start(jobId);
  }

  void _startValidate({required bool withMapping}) {
    final path = _path;
    if (path == null) return;
    if (withMapping && _mapping.columns.isEmpty) {
      setState(() => _error = '请先设置至少一列映射');
      return;
    }
    setState(() => _error = null);
    final params = <String, dynamic>{
      'path': path,
      'read': _readRule().toJson(),
      'fields': _fieldRule().toJson(),
    };
    if (withMapping) {
      params['mapping'] = _mapping.toJson();
      params['database'] = widget.database;
      params['table'] = widget.table;
    }
    () async {
      try {
        final res = await Api.instance.importValidateStart(params);
        final jobId = (res['job_id'] ?? '').toString();
        if (!mounted) return;
        if (jobId.isEmpty) {
          setState(() => _error = '校验任务启动失败');
          return;
        }
        _watchJob(jobId, kind: withMapping ? 'fields' : 'read');
      } catch (e) {
        if (mounted) setState(() => _error = describeDbError(e));
      }
    }();
  }

  Future<void> _runProbe() async {
    final path = _path;
    if (path == null) return;
    if (_mapping.columns.isEmpty) {
      setState(() => _error = '请先设置至少一列映射');
      return;
    }
    setState(() {
      _busy = true;
      _probe = null;
      _probeOk = false;
      _error = null;
    });
    try {
      final probe = await Api.instance.importProbe(
        widget.database,
        widget.table,
        <String, dynamic>{
          'path': path,
          'read': _readRule().toJson(),
          'fields': _fieldRule().toJson(),
          'mapping': _mapping.toJson(),
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _probe = probe;
        _probeOk = probe['probe_error'] == null && probe['affected'] == 1;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeDbError(e);
        });
      }
    }
  }

  void _startExecute() {
    final path = _path;
    if (path == null || _mapping.columns.isEmpty) return;
    final nullTokens = _nullTokensCtrl.text
        .split(',')
        .map((e) => decodeEscapes(e.trim()))
        .where((e) => e.isNotEmpty)
        .toList();
    final mapping = _mapping.toJson();
    mapping['null_tokens'] = nullTokens.isEmpty ? <String>['\\N'] : nullTokens;
    setState(() {
      _executing = true;
      _executeResult = null;
      _error = null;
    });
    final params = <String, dynamic>{
      'path': path,
      'read': _readRule().toJson(),
      'fields': _fieldRule().toJson(),
      'mapping': mapping,
      'database': widget.database,
      'table': widget.table,
      'options': <String, dynamic>{
        'batch_size': _batchSize,
        'on_error': _onError,
        'max_issues': 100,
      },
    };
    () async {
      try {
        final res = await Api.instance.importExecuteStart(params);
        final jobId = (res['job_id'] ?? '').toString();
        if (!mounted) return;
        if (jobId.isEmpty) {
          setState(() {
            _executing = false;
            _error = '导入任务启动失败';
          });
          return;
        }
        _watchJob(jobId, kind: 'execute');
      } catch (e) {
        if (mounted) {
          setState(() {
            _executing = false;
            _error = describeDbError(e);
          });
        }
      }
    }();
  }

  bool get _jobRunning => _jobStatus != null && _jobStatus!['done'] != true;

  // ------------------------------------------------------------------ build

  @override
  Widget build(BuildContext context) {
    // The dialog must fit the actual window: a fixed 1060x780 box overflows a
    // small screen (and would fail layout in tests).
    final screen = MediaQuery.of(context).size;
    final width = screen.width < 1100 ? screen.width * 0.94 : 1060.0;
    final height = screen.height < 840 ? screen.height * 0.94 : 780.0;
    return Dialog(
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusModal),
        side: BorderSide(color: AppColors.border),
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            _header(),
            _stepIndicator(),
            Divider(height: 1, color: AppColors.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: _error != null
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          AlertBox(_error!, tone: AlertTone.error),
                          _stepContent(),
                        ],
                      )
                    : _stepContent(),
              ),
            ),
            Divider(height: 1, color: AppColors.border),
            _footer(),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
      child: Row(
        children: [
          Icon(Icons.upload_file, size: 18, color: AppColors.header),
          const SizedBox(width: 8),
          Text(
            '数据导入向导',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: AppColors.header,
            ),
          ),
          const SizedBox(width: 10),
          Pill('${widget.database} · ${widget.table}'),
          const Spacer(),
          if (_path != null)
            Flexible(
              child: EllipsisText(
                _inspect?['name']?.toString() ?? baseNameOf(_path!),
                tooltip: _path,
                tooltipMaxWidth: 520,
                style: kSmallMuted,
              ),
            ),
          const SizedBox(width: 8),
          IconBtn(
            Icons.close,
            tooltip: '关闭',
            onPressed: _executing || _jobRunning
                ? null
                : () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _stepIndicator() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          for (var i = 0; i < _stepTitles.length; i++) ...[
            if (i > 0)
              Expanded(
                child: Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  color: i <= _step ? AppColors.header : AppColors.border,
                ),
              ),
            _stepChip(i),
          ],
        ],
      ),
    );
  }

  Widget _stepChip(int index) {
    final active = index == _step;
    final done = index < _step;
    final color = active || done ? AppColors.header : AppColors.muted;
    final chip = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active || done ? AppColors.header : AppColors.chipBg,
            border: Border.all(color: AppColors.border),
          ),
          child: done
              ? const Icon(Icons.check, size: 12, color: Colors.white)
              : Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 11,
                    color: active ? Colors.white : AppColors.muted,
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Text(
          _stepTitles[index],
          style: TextStyle(
            fontSize: 12,
            color: color,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
    if (index >= _step || _executing || _jobRunning) return chip;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _step = index),
        child: chip,
      ),
    );
  }

  Widget _footer() {
    final busyJob = _jobRunning;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Expanded(child: Text(_stepHint(), style: kSmallMuted)),
          if (_busy || _executing) ...[
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
          ],
          // The old label was "取消", but it closes the whole dialog rather than
          // cancelling the current step, so it is now named after what it does.
          Btn('关闭', onPressed: _executing || busyJob ? null : () => _close()),
          const SizedBox(width: 8),
          if (_step > 0 && !_executing) ...[
            Btn('上一步', onPressed: busyJob ? null : () => _backStep()),
            const SizedBox(width: 8),
          ],
          _primaryButton(busyJob),
        ],
      ),
    );
  }

  /// The one primary action of the current step.
  ///
  /// The execute step used to show "开始导入" twice (once inside the card, once
  /// in the footer); the card no longer carries a button, so this is the only
  /// place that starts the import.
  Widget _primaryButton(bool busyJob) {
    switch (_step) {
      case 0:
        return Btn(
          '下一步',
          primary: true,
          onPressed: _path != null && !busyJob
              ? () => setState(() => _step += 1)
              : null,
        );
      case 1:
        return Btn(
          '下一步',
          primary: true,
          onPressed: _readValidated && !busyJob
              ? () => setState(() => _step += 1)
              : null,
        );
      case 2:
        return Btn(
          '下一步',
          primary: true,
          onPressed: _probeOk && _fieldValidated && !busyJob
              ? () => setState(() => _step += 1)
              : null,
        );
      case 3:
        if (_executeResult == null) {
          return Btn(
            '开始导入',
            primary: true,
            busy: _executing,
            onPressed: _executing || busyJob || _mapping.columns.isEmpty
                ? null
                : _startExecute,
          );
        }
        return Btn(
          '下一步：建立关联',
          primary: true,
          onPressed: () => setState(() => _step = 4),
        );
      default:
        return Btn('完成并返回', primary: true, onPressed: () => _close());
    }
  }

  /// Step back one screen; the relation step only has the execute step before
  /// it, so it does not simply decrement past it.
  void _backStep() {
    if (_step <= 0) return;
    setState(() => _step -= 1);
  }

  void _close() {
    _poller?.dispose();
    Navigator.of(context).pop();
  }

  String _stepHint() {
    switch (_step) {
      case 0:
        return _path == null
            ? '先选择一个数据文件；大文件会流式读取，不会一次载入内存。'
            : '确认格式无误后进入下一步设置读取规则。';
      case 1:
        if (_isExcel) {
          return _readValidated
              ? '工作表读取规则校验通过，可以继续。'
              : '选择工作表与表头、设置跳过开头的行数，然后校验整个工作表；校验通过才能继续。';
        }
        return _readValidated
            ? '读取规则校验通过，可以继续。'
            : '设置一条完整数据如何切分，预览后校验整个文件；校验通过才能继续。';
      case 2:
        return _probeOk && _fieldValidated
            ? '试插入与整文件校验都通过，可以开始导入。'
            : _isExcel
            ? '确认列映射，先“试插入”，再校验整个工作表；两项都通过才能继续。'
            : '设置字段识别与列映射，先“试插入”，再校验整个文件；两项都通过才能继续。';
      case 3:
        return _executeResult == null
            ? '导入按批次写入，可随时取消；出错时按选择的策略处理。'
            : '导入已结束：下一步可以建立表间关联，也可以直接关闭。';
      default:
        return '添加表并连接字段建立外键；关系修改会立即写入数据库。';
    }
  }

  Widget _stepContent() {
    return switch (_step) {
      0 => _stepFile(),
      1 => _stepRead(),
      2 => _stepFields(),
      3 => _stepExecute(),
      _ => _stepRelations(),
    };
  }

  // ------------------------------------------------------------ step 1 view

  Widget _stepFile() {
    final inspect = _inspect;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: '数据文件',
          actions: [
            Btn(
              '选择文件',
              icon: Icons.folder_open,
              onPressed: _busy ? null : _pickFile,
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_path == null)
                Text(
                  pickText(
                    '支持 CSV / TSV / 分隔文本 / JSON / JSON Lines / XML / HTML / Markdown，'
                        '以及 Excel 工作簿（.xlsx / .xls / .xlsb / .ods）。'
                        'Excel 文件按工作表导入，可多选工作表里的其中一张。',
                    'Supports CSV / TSV / delimited text / JSON / JSON Lines / XML / HTML / '
                        'Markdown and Excel workbooks (.xlsx / .xls / .xlsb / .ods). Excel files '
                        'are imported worksheet by worksheet, one at a time.',
                  ),
                  style: kSmallMuted,
                )
              else ...[
                _keyValue('文件', _path!),
                _keyValue(
                  '大小',
                  formatBytes((inspect?['size'] as num?)?.toInt() ?? 0),
                ),
                // A workbook is not a text stream: an "encoding" line would
                // only raise the question what it means for a .xlsx file.
                if (!_isExcel)
                  _keyValue('编码', (inspect?['encoding'] ?? 'utf-8').toString()),
                _keyValue('识别格式', _formatLabel(inspect?['format']?.toString())),
                if (_isExcel)
                  _keyValue(
                    '工作表',
                    pickText(
                      '${_sheets().length} 个工作表（在下一步选择）',
                      '${_sheets().length} worksheet(s) (chosen in the next step)',
                    ),
                  ),
                if ((inspect?['warnings'] as List? ?? const <dynamic>[])
                    .isNotEmpty)
                  for (final warning in (inspect!['warnings'] as List).map(
                    (e) => e.toString(),
                  ))
                    AlertBox(warning, tone: AlertTone.warn),
                const SizedBox(height: 8),
                // A workbook is a compressed/binary container: printing its
                // first bytes would only show replacement characters.
                if (_isExcel)
                  Text(
                    pickText(
                      '工作簿是二进制/压缩格式，不显示文件开头预览；下一步可选择要导入的工作表。',
                      'A workbook is a binary/compressed container, so there is no text '
                          'preview of its beginning; the next step lets you choose a worksheet.',
                    ),
                    style: kSmallMuted,
                  )
                else ...[
                  const SectionLabel('文件开头预览'),
                  const SizedBox(height: 6),
                  CodeBlock(
                    (inspect?['head'] ?? '').toString(),
                    maxHeight: 180,
                  ),
                ],
              ],
            ],
          ),
        ),
        CardBox(
          title: '导入方式',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final line in _importModeLines())
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('· ', style: kSmallMuted),
                      Expanded(child: Text(line, style: kSmallMuted)),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ step 2 view

  Widget _stepRead() {
    if (_isExcel) return _stepReadWorksheet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: '一条完整数据怎么切分',
          actions: [Btn('刷新预览', onPressed: _busy ? null : _refreshPreview)],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  _selectRule<String>(
                    '记录方式',
                    _readMode,
                    const <DropdownMenuItem<String>>[
                      DropdownMenuItem(
                        value: 'line',
                        child: Text('每行一条记录（CSV / JSON Lines）'),
                      ),
                      DropdownMenuItem(
                        value: 'wrapped',
                        child: Text('自定义包裹 / 记录分隔符（JSON 数组等）'),
                      ),
                    ],
                    (value) {
                      if (value == null) return;
                      setState(() => _readMode = value);
                    },
                  ),
                  if (_readMode == 'wrapped') ...[
                    _textRule('包裹开头', _wrapperStartCtrl, hint: '例如 [）'),
                    _textRule('包裹结尾', _wrapperEndCtrl, hint: '例如 ]'),
                  ],
                  _textRule(
                    '记录分隔符',
                    _recordSepCtrl,
                    hint: '例如 \\n 或 ,',
                    width: 150,
                  ),
                  _textRule(
                    '引号字符',
                    _readQuoteCtrl,
                    hint: 'CSV/JSON 引号',
                    width: 110,
                  ),
                  _checkRule(
                    '跳过空记录',
                    _skipBlank,
                    (value) => setState(() => _skipBlank = value),
                  ),
                  _checkRule(
                    '去除首尾空白',
                    _trimRecord,
                    (value) => setState(() => _trimRecord = value),
                  ),
                  if (_readMode == 'wrapped')
                    Tooltip(
                      message: '按括号层级识别记录：包裹在 [] / {} 内部的记录分隔符不会被切开（JSON 推荐）',
                      child: _checkRule(
                        '按括号层级识别',
                        _balance,
                        (value) => setState(() => _balance = value),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(_readRule().describe(), style: kSmallMuted),
            ],
          ),
        ),
        _previewEchoCard(),
        _validationCard(
          title: '校验整个文件',
          result: _readValidation,
          passed: _readValidated,
          running: _jobKind == 'read' && _jobRunning,
          onStart: _busy ? null : () => _startValidate(withMapping: false),
          successText: '整个文件都能按当前读取规则切分。',
        ),
      ],
    );
  }

  /// Step 2 for Excel / ODS workbooks.
  ///
  /// A workbook has no record delimiters to configure: the only read-rule
  /// choices are the worksheet, whether row 1 holds the column names and how
  /// many leading rows to skip. Everything the text formats need (record mode,
  /// wrappers, separators, quotes, blank-record handling) is hidden, because
  /// sending those values would not change how the workbook is read.
  Widget _stepReadWorksheet() {
    final sheets = _sheets();
    final options = <DropdownMenuItem<String>>[
      for (final sheet in sheets)
        DropdownMenuItem<String>(
          value: (sheet['name'] ?? '').toString(),
          child: Text(_sheetLabel(sheet), noTranslate: true),
        ),
    ];
    final active = _activeSheet;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: '工作表',
          actions: [Btn('刷新预览', onPressed: _busy ? null : _refreshPreview)],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 10,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  SizedBox(
                    width: 300,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('工作表', style: kSmallMuted),
                        const SizedBox(height: 4),
                        if (options.isEmpty)
                          // No worksheet metadata (an older importer build, or
                          // a single-sheet SpreadsheetML file): the engine reads
                          // the first worksheet, so show that fact instead of an
                          // empty dropdown.
                          Pill(active ?? '默认工作表')
                        else
                          SelectBox<String>(
                            value: active,
                            items: options,
                            onChanged: _selectSheet,
                          ),
                      ],
                    ),
                  ),
                  _checkRule('首行为列名', _hasHeader, _setHeader),
                  SizedBox(
                    width: 150,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('跳过开头行数', style: kSmallMuted),
                        const SizedBox(height: 4),
                        Field(
                          label: '',
                          controller: _skipRowsCtrl,
                          hint: '0',
                          numeric: true,
                          compact: true,
                          onChanged: _onSkipRowsChanged,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                '单元格类型按 Excel 原类型识别（数字 / 日期 / 布尔 / 文本）。',
                style: kSmallMuted,
              ),
              if (sheets.length > 1) ...[
                const SizedBox(height: 8),
                AlertBox(
                  pickText(
                    '文件含 ${sheets.length} 个工作表：本次只导入所选工作表；'
                        '要一次导入多个工作表，请使用数据库页的「从文件建表」。',
                    'The file contains ${sheets.length} worksheets: this import reads only '
                        'the selected one; to import several worksheets at once, use '
                        '"Create tables from file" on the database page.',
                  ),
                  tone: AlertTone.warn,
                ),
              ],
            ],
          ),
        ),
        _previewEchoCard(title: '前几行数据预览'),
        _validationCard(
          title: '校验整个工作表',
          result: _readValidation,
          passed: _readValidated,
          running: _jobKind == 'read' && _jobRunning,
          onStart: _busy ? null : () => _startValidate(withMapping: false),
          successText: '整个工作表都能按当前读取规则切分。',
        ),
      ],
    );
  }

  Widget _previewEchoCard({String title = '分割结果回显（给用户参考）'}) {
    final preview = _preview;
    final records = (preview?['records'] as List? ?? const <dynamic>[])
        .map((e) => asJsonMap(e))
        .toList();
    final dataRecords = records.where((r) => r['header'] != true).toList();
    final sample = dataRecords.isNotEmpty ? dataRecords.first : null;
    final header = preview?['header'];
    final issues = (preview?['issues'] as List? ?? const <dynamic>[])
        .map((e) => asJsonMap(e))
        .toList();
    return CardBox(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (header is List && header.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('表头：', style: kSmallMuted),
                  for (final name in header.map((e) => e.toString()))
                    Pill(name, tone: PillTone.info),
                ],
              ),
            ),
          if (sample == null)
            Text('还没有可显示的记录，请检查文件或调整读取规则。', style: kSmallMuted)
          else ...[
            Text(
              '${recordPositionLabel((sample['line'] as num?)?.toInt() ?? 1, (sample['offset'] as num?)?.toInt() ?? 0, (sample['index'] as num?)?.toInt())} · 切分出的完整一条数据',
              style: kSmallMuted,
            ),
            const SizedBox(height: 6),
            CodeBlock(
              (sample['text'] ?? '').toString(),
              dark: true,
              maxHeight: 140,
            ),
            const SizedBox(height: 8),
            _parsedRecordSummary(sample),
          ],
          if (dataRecords.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '（另有 ${dataRecords.length - 1} 条示例数据，此处只展示第一条）',
                style: kSmallMuted,
              ),
            ),
          if (issues.isNotEmpty) ...[
            const SizedBox(height: 10),
            _issuesPanel(issues),
          ],
        ],
      ),
    );
  }

  Widget _parsedRecordSummary(Json record) {
    if (record['error'] != null) {
      return AlertBox('这一条数据无法匹配：${record['error']}', tone: AlertTone.error);
    }
    final values = record['values'];
    if (record['kind'] == 'object' && values is Map) {
      final chips = <Widget>[];
      values.forEach((key, value) {
        chips.add(Pill('$key = ${displayCell(value)}'));
      });
      return Wrap(spacing: 6, runSpacing: 4, children: chips);
    }
    if (values is List) {
      final chips = <Widget>[];
      for (var i = 0; i < values.length; i++) {
        chips.add(Pill('第 ${i + 1} 列 = ${displayCell(values[i])}'));
      }
      return Wrap(spacing: 6, runSpacing: 4, children: chips);
    }
    return const SizedBox.shrink();
  }

  Json? _firstDataRecord() {
    final records = (_preview?['records'] as List? ?? const <dynamic>[])
        .map((e) => asJsonMap(e))
        .where((r) => r['header'] != true)
        .toList();
    return records.isEmpty ? null : records.first;
  }

  // ------------------------------------------------------------ step 3 view

  Widget _stepFields() {
    final sample = _firstDataRecord();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: '每条数据怎么识别字段',
          actions: [Btn('刷新预览', onPressed: _busy ? null : _refreshPreview)],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_isExcel) ...[
                // A workbook record is one row; the value types come from
                // the cells, so there is nothing to configure but the header.
                _checkRule('首行为列名', _hasHeader, _setHeader),
                const SizedBox(height: 8),
                Text(
                  '字段方式固定为 Excel 单元格：数字 / 日期 / 布尔 / 文本按原单元格类型识别；'
                  '分隔符、引号等文本拆分设置不适用于工作簿。',
                  style: kSmallMuted,
                ),
              ] else
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    _selectRule<String>(
                      '字段方式',
                      _fieldMode,
                      const <DropdownMenuItem<String>>[
                        DropdownMenuItem(
                          value: 'delimited',
                          child: Text('分隔文本（逗号/制表符等）'),
                        ),
                        DropdownMenuItem(
                          value: 'json',
                          child: Text('JSON（对象=列名，数组=按位置）'),
                        ),
                        // The structural formats the exporter writes. Choosing
                        // one is rarely necessary (inspect() detects it), but
                        // the option has to exist so a mis-detected file can
                        // be corrected by hand.
                        DropdownMenuItem(
                          value: 'xml',
                          child: Text('XML（<col name="列">值</col>）'),
                        ),
                        DropdownMenuItem(
                          value: 'html',
                          child: Text('HTML 表格（<td> 单元格）'),
                        ),
                        DropdownMenuItem(
                          value: 'spreadsheet',
                          child: Text('Excel（SpreadsheetML 单元格）'),
                        ),
                        DropdownMenuItem(
                          value: 'markdown',
                          child: Text('Markdown 表格（| a | b |）'),
                        ),
                      ],
                      (value) {
                        if (value == null) return;
                        setState(() {
                          _fieldMode = value;
                          _resetValidation();
                        });
                      },
                    ),
                    if (_fieldMode == 'delimited') ...[
                      _textRule(
                        '字段分隔符',
                        _fieldSepCtrl,
                        hint: '例如 , 或 \\t',
                        width: 140,
                      ),
                      _textRule('引号字符', _fieldQuoteCtrl, width: 110),
                      _textRule(
                        '转义字符',
                        _escapeCtrl,
                        hint: '可留空，例如 \\\\',
                        width: 110,
                      ),
                      _checkRule(
                        '首行是列名',
                        _hasHeader,
                        (value) => setState(() {
                          _hasHeader = value;
                          _resetValidation();
                        }),
                      ),
                      _checkRule(
                        '去除字段首尾空白',
                        _trimFields,
                        (value) => setState(() {
                          _trimFields = value;
                          _resetValidation();
                        }),
                      ),
                    ],
                  ],
                ),
              const SizedBox(height: 10),
              Text(
                _mappingKeyed
                    ? '当前识别为“有列名”的数据：每一列按列名映射到目标表列，列名来自表头或 JSON 键。'
                    : '当前识别为“无列名”的数据：按位置映射；要求每条记录字段数一致（当前示例有 $_positionalFields 个字段）。',
                style: kSmallMuted,
              ),
              if (sample != null) ...[
                const SizedBox(height: 8),
                _parsedRecordSummary(sample),
              ],
            ],
          ),
        ),
        _mappingCard(),
        CardBox(
          title: '试插入一条（写入后立即回滚）',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '读取第一条数据、按映射转换类型并实际插入目标表，然后回滚事务；'
                '用于确认列映射与目标表完全匹配，不会留下数据。',
                style: kSmallMuted,
              ),
              const SizedBox(height: 8),
              Btn(
                '试插入',
                primary: true,
                busy: _busy,
                onPressed: _busy || _mapping.columns.isEmpty ? null : _runProbe,
              ),
              if (_probe != null) ...[
                const SizedBox(height: 10),
                _probeResult(_probe!),
              ],
            ],
          ),
        ),
        _validationCard(
          title: _isExcel ? '校验整个工作表（含字段与类型转换）' : '校验整个文件（含字段与类型转换）',
          result: _fieldValidation,
          passed: _fieldValidated,
          running: _jobKind == 'fields' && _jobRunning,
          onStart: _busy || _mapping.columns.isEmpty
              ? null
              : () => _startValidate(withMapping: true),
          successText: _isExcel
              ? '整个工作表都能按当前字段规则与列映射解析并转换。'
              : '整个文件都能按当前字段规则与列映射解析并转换。',
        ),
      ],
    );
  }

  Widget _mappingCard() {
    final sourceOptions = <DropdownMenuItem<Object>>[
      if (_mappingKeyed)
        for (final key in _keySources)
          DropdownMenuItem<Object>(value: key, child: Text(key))
      else
        for (var i = 0; i < _positionalFields; i++)
          DropdownMenuItem<Object>(value: i, child: Text('第 ${i + 1} 个字段')),
    ];
    return CardBox(
      title: '列映射（目标表 ${widget.table}）',
      actions: [
        Btn(
          '自动映射',
          small: true,
          onPressed: () => setState(() {
            _mappingTouched = false;
            _resetValidation();
            _autoMap();
          }),
        ),
        const SizedBox(width: 8),
        Btn(
          '添加映射',
          small: true,
          onPressed: () => setState(() {
            _mappingTouched = true;
            final used = _mapping.columns.map((c) => c.column).toSet();
            final next = _tableColumns.firstWhere(
              (c) => !used.contains(c),
              orElse: () => '',
            );
            if (next.isEmpty) return;
            _mapping.columns.add(
              ImportColumnMap(
                column: next,
                source: _mappingKeyed
                    ? (_keySources.isNotEmpty ? _keySources.first : '')
                    : 0,
              ),
            );
            _resetValidation();
          }),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_mapping.columns.isEmpty)
            Text('尚未设置列映射。点击“自动映射”按列名或顺序生成，或手动添加。', style: kSmallMuted)
          else ...[
            Row(
              children: [
                SizedBox(width: 220, child: Text('目标列', style: kSmallMuted)),
                SizedBox(width: 12),
                Expanded(child: Text('来源', style: kSmallMuted)),
                SizedBox(width: 36),
              ],
            ),
            const SizedBox(height: 4),
            for (var i = 0; i < _mapping.columns.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 220,
                      child: SelectBox<String>(
                        value: _mapping.columns[i].column,
                        items: <DropdownMenuItem<String>>[
                          for (final column in _tableColumns)
                            DropdownMenuItem(
                              value: column,
                              child: Text(column),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _mappingTouched = true;
                            _mapping.columns[i].column = value;
                            _resetValidation();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: SelectBox<Object>(
                        value: _mapping.columns[i].source,
                        items: sourceOptions,
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _mappingTouched = true;
                            _mapping.columns[i].source = value;
                            _resetValidation();
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 6),
                    IconBtn(
                      Icons.delete_outline,
                      tooltip: '移除这条映射',
                      onPressed: () => setState(() {
                        _mappingTouched = true;
                        _mapping.columns.removeAt(i);
                        _resetValidation();
                      }),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 14,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _checkRule(
                  '空字符串视为 NULL',
                  _mapping.emptyAsNull,
                  (value) => setState(() {
                    _mapping.emptyAsNull = value;
                    _resetValidation();
                  }),
                ),
                _checkRule(
                  '忽略未映射的多余字段',
                  _mapping.ignoreUnknown,
                  (value) => setState(() {
                    _mapping.ignoreUnknown = value;
                    _resetValidation();
                  }),
                ),
                _textRule(
                  'NULL 标记（逗号分隔）',
                  _nullTokensCtrl,
                  hint: '例如 \\N',
                  width: 200,
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _probeResult(Json probe) {
    final error = probe['probe_error'];
    final insertSql = (probe['insert_sql'] ?? '').toString();
    final values = probe['values'];
    final row = probe['row'];
    final columns = (probe['columns'] as List? ?? const <dynamic>[])
        .map((e) => e.toString())
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (error != null)
          AlertBox('试插入失败：$error', tone: AlertTone.error)
        else
          const AlertBox('试插入成功：影响 1 行，事务已回滚，目标表没有写入任何数据。', tone: AlertTone.ok),
        const SizedBox(height: 8),
        const SectionLabel('将要执行的 SQL'),
        const SizedBox(height: 4),
        CodeBlock(insertSql, maxHeight: 130),
        if (values is List && columns.isNotEmpty) ...[
          const SizedBox(height: 8),
          const SectionLabel('转换后的列值'),
          const SizedBox(height: 4),
          for (var i = 0; i < columns.length && i < values.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 180,
                    child: Text(columns[i], style: kSmallMuted),
                  ),
                  Expanded(
                    child: Text(
                      displayCell(values[i]),
                      style: monoStyle(size: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (row is Map && row.isNotEmpty) ...[
          const SizedBox(height: 8),
          const SectionLabel('事务内读回的样例行'),
          const SizedBox(height: 4),
          for (final entry in row.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 180,
                    child: Text(entry.key.toString(), style: kSmallMuted),
                  ),
                  Expanded(
                    child: Text(
                      displayCell(entry.value),
                      style: monoStyle(size: 12),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _validationCard({
    required String title,
    required Json? result,
    required bool passed,
    required bool running,
    required VoidCallback? onStart,
    required String successText,
  }) {
    final issues = (result?['issues'] as List? ?? const <dynamic>[])
        .map((e) => asJsonMap(e))
        .toList();
    return CardBox(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Btn(
                running ? '校验中…' : '开始校验',
                primary: true,
                busy: running,
                onPressed: running ? null : onStart,
              ),
              const SizedBox(width: 10),
              if (running && _jobStatus != null)
                Flexible(
                  child: Text(_progressText(_jobStatus!), style: kSmallMuted),
                )
              else if (result != null && passed)
                Text('通过', style: TextStyle(color: AppColors.ok, fontSize: 12))
              else if (result != null)
                Text(
                  '有 ${formatCount((result['invalid'] as num?))} 条无法匹配',
                  style: TextStyle(color: AppColors.danger, fontSize: 12),
                ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 8),
            _progressBar(_jobStatus),
            const SizedBox(height: 6),
            Btn(
              '取消校验',
              small: true,
              danger: true,
              onPressed: () => _poller?.cancelJob(),
            ),
          ],
          if (result != null && passed) ...[
            const SizedBox(height: 8),
            AlertBox(successText, tone: AlertTone.ok),
          ],
          if (result != null && !passed) ...[
            const SizedBox(height: 8),
            AlertBox(
              '发现 ${formatCount((result['invalid'] as num?))} 条无法匹配的数据'
              '（共 ${formatCount((result['data_records'] as num?))} 条）。'
              '请根据下面的位置提示调整规则后重新校验。',
              tone: AlertTone.error,
            ),
            const SizedBox(height: 8),
            _issuesPanel(issues),
          ],
        ],
      ),
    );
  }

  Widget _issuesPanel(List<Json> issues) {
    if (issues.isEmpty) return const SizedBox.shrink();
    final shown = issues.take(_maxIssuesShown).toList();
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppColors.errBg,
        border: Border.all(color: AppColors.errBorder),
        borderRadius: BorderRadius.circular(AppMetrics.radiusControl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final issue in shown)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${recordPositionLabel((issue['line'] as num?)?.toInt() ?? 0, (issue['offset'] as num?)?.toInt() ?? 0, (issue['index'] as num?)?.toInt())}：${issue['message'] ?? ''}',
                    style: TextStyle(fontSize: 12, color: AppColors.errText),
                  ),
                  if ((issue['snippet'] ?? '') != '')
                    EllipsisText(
                      '内容：${issue['snippet']}',
                      translate: true,
                      style: monoStyle(size: 11, color: AppColors.errText),
                      maxLines: 2,
                      tooltipMaxWidth: 520,
                    ),
                ],
              ),
            ),
          if (issues.length > _maxIssuesShown)
            Text(
              '（仅显示前 $_maxIssuesShown 条问题，共 ${issues.length} 条）',
              style: kSmallMuted,
            ),
        ],
      ),
    );
  }

  Widget _progressBar(Json? status) {
    final progress = asJsonMap(status?['progress']);
    final percent = (progress['percent'] as num?)?.toDouble() ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          value: percent <= 0 ? null : (percent / 100).clamp(0.0, 1.0),
          minHeight: 6,
          backgroundColor: AppColors.chipBg,
          valueColor: AlwaysStoppedAnimation<Color>(AppColors.header),
        ),
        const SizedBox(height: 4),
        Text(_progressText(status), style: kSmallMuted),
      ],
    );
  }

  String _progressText(Json? status) {
    final progress = asJsonMap(status?['progress']);
    final percent = (progress['percent'] as num?)?.toDouble() ?? 0;
    final bytes = (progress['bytes'] as num?)?.toInt() ?? 0;
    final total = (progress['total_bytes'] as num?)?.toInt() ?? 0;
    final rows = (progress['rows'] as num?)?.toInt() ?? 0;
    final failed = (progress['failed'] as num?)?.toInt() ?? 0;
    final elapsed = (progress['elapsed_ms'] as num?)?.toInt() ?? 0;
    final seconds = (elapsed / 1000).toStringAsFixed(1);
    // Workbook progress has no byte offset: the Rust side reports rows read /
    // rows in the worksheet instead, already formatted for the UI.
    final message = (progress['message'] ?? '').toString();
    if (message.isNotEmpty) return '$message · ${seconds}s';
    final sizeText = total > 0
        ? '${formatBytes(bytes)} / ${formatBytes(total)}'
        : formatBytes(bytes);
    return '$sizeText（${percent.toStringAsFixed(1)}%） · 已处理 ${formatCount(rows)} 行'
        '${failed > 0 ? ' · 失败 ${formatCount(failed)}' : ''} · ${seconds}s';
  }

  // ------------------------------------------------------------ step 4 view

  Widget _stepExecute() {
    final result = _executeResult;
    final issues = (result?['issues'] as List? ?? const <dynamic>[])
        .map((e) => asJsonMap(e))
        .toList();
    final fileSize = (_inspect?['size'] as num?)?.toInt() ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CardBox(
          title: '导入确认',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _keyValue('文件', _path ?? ''),
              _keyValue('大小', formatBytes(fileSize)),
              _keyValue('读取规则', _readRule().describe()),
              _keyValue('字段规则', _fieldRule().describe()),
              _keyValue(
                '列映射',
                _mapping.columns.map((c) => c.column).join(', '),
              ),
              _keyValue('目标表', '${widget.database} · ${widget.table}'),
              if (fileSize > 100 * 1024 * 1024) ...[
                const SizedBox(height: 8),
                AlertBox(
                  _isExcel
                      ? '工作簿较大：按行流式读取并分批插入，内存占用与行数无关（共享字符串表仍需一次加载）；界面保持响应，可随时取消。'
                      : '文件较大：导入会逐块读取并分批插入，界面保持响应，可随时取消。',
                  tone: AlertTone.warn,
                ),
              ],
            ],
          ),
        ),
        CardBox(
          title: '导入选项',
          child: Wrap(
            spacing: 16,
            runSpacing: 10,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _selectRule<int>(
                '每批插入行数',
                _batchSize,
                const <DropdownMenuItem<int>>[
                  DropdownMenuItem(value: 100, child: Text('100')),
                  DropdownMenuItem(value: 500, child: Text('500（默认）')),
                  DropdownMenuItem(value: 1000, child: Text('1000')),
                  DropdownMenuItem(value: 2000, child: Text('2000')),
                ],
                (value) => setState(() => _batchSize = value ?? 500),
              ),
              _selectRule<String>(
                '出错处理',
                _onError,
                const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'stop', child: Text('停止导入并报告位置')),
                  DropdownMenuItem(value: 'skip', child: Text('跳过出错行继续导入')),
                ],
                (value) => setState(() => _onError = value ?? 'stop'),
              ),
            ],
          ),
        ),
        CardBox(
          title: result == null ? '执行导入' : '导入结果',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (result == null) ...[
                Text('导入会按批次写入目标表。过程中可以取消，已写入的批次不会回滚。', style: kSmallMuted),
                if (_jobStatus != null && _jobRunning) ...[
                  const SizedBox(height: 8),
                  _progressBar(_jobStatus),
                  const SizedBox(height: 8),
                  Btn(
                    '取消导入',
                    danger: true,
                    onPressed: () => _poller?.cancelJob(),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    pickText(
                      '点击底部「开始导入」开始执行；导入过程中会在这里显示进度。',
                      'Press "Start import" at the bottom to begin; progress appears here '
                          'while the import runs.',
                    ),
                    style: kSmallMuted,
                  ),
                ],
              ] else ...[
                if (result['ok'] == true)
                  AlertBox(
                    '导入完成：写入 ${formatCount((result['rows_inserted'] as num?))} 行，'
                    '用时 ${((result['elapsed_ms'] as num?)?.toInt() ?? 0) / 1000} 秒。',
                    tone: AlertTone.ok,
                  )
                else
                  AlertBox(
                    result['cancelled'] == true
                        ? '导入已取消：已写入 ${formatCount((result['rows_inserted'] as num?))} 行。'
                        : '导入结束但有问题：已写入 ${formatCount((result['rows_inserted'] as num?))} 行，'
                              '失败 ${formatCount((result['rows_failed'] as num?))} 行。',
                    tone: result['cancelled'] == true
                        ? AlertTone.warn
                        : AlertTone.error,
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 16,
                  runSpacing: 6,
                  children: [
                    Text(
                      '数据记录 ${formatCount((result['data_records'] as num?))}',
                      style: kSmallMuted,
                    ),
                    Text(
                      '写入 ${formatCount((result['rows_inserted'] as num?))}',
                      style: TextStyle(fontSize: 12, color: AppColors.ok),
                    ),
                    Text(
                      '失败 ${formatCount((result['rows_failed'] as num?))}',
                      style: TextStyle(fontSize: 12, color: AppColors.danger),
                    ),
                    Text(
                      '批次 ${formatCount((result['batches'] as num?))}',
                      style: kSmallMuted,
                    ),
                  ],
                ),
                if ((result['message'] ?? '') != '') ...[
                  const SizedBox(height: 8),
                  AlertBox(result['message'].toString(), tone: AlertTone.error),
                ],
                if (issues.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  _issuesPanel(issues),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ step 5 view

  /// Final step: build foreign-key relations for the just-imported table.
  ///
  /// The designer writes changes to the database immediately, so the wizard
  /// only hosts it; the table page is refreshed through
  /// [DataImportWizardDialog.onImported] right after the import finishes.
  Widget _stepRelations() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          pickText(
            '已导入 ${widget.table}。下面可以给当前库的表建立外键关系：'
                '已存在的外键会自动画出，把字段连接点拖到另一张表的字段即可新建。',
            'Imported ${widget.table}. Build foreign keys between tables of the '
                'current database here: existing keys are drawn automatically, and '
                'dragging a column connector onto another table creates a new one.',
          ),
          style: kSmallMuted,
        ),
        const SizedBox(height: 10),
        RelationDesigner(
          database: widget.database,
          initialTables: <String>[widget.table],
          // Relation changes are written immediately; refreshing the table page
          // keeps its foreign-key markers in sync while the dialog is open.
          onChanged: widget.onImported,
          height: 440,
          compact: true,
        ),
        const SizedBox(height: 8),
        Text('关系修改会立即写入数据库；也可以稍后从数据库页的关系图入口再配置。', style: kSmallMuted),
      ],
    );
  }

  // ---------------------------------------------------------------- helpers

  Widget _keyValue(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 80, child: Text(label, style: kSmallMuted)),
          Expanded(child: Text(value, style: kSmall)),
        ],
      ),
    );
  }

  Widget _textRule(
    String label,
    TextEditingController controller, {
    String? hint,
    double width = 170,
  }) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: kSmallMuted),
          const SizedBox(height: 4),
          Field(
            label: '',
            controller: controller,
            hint: hint,
            compact: true,
            onChanged: (_) => setState(_resetValidation),
          ),
        ],
      ),
    );
  }

  Widget _checkRule(String label, bool value, ValueChanged<bool> onChanged) {
    return CheckBox(label: label, value: value, onChanged: onChanged);
  }

  Widget _selectRule<T>(
    String label,
    T value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> onChanged, {
    double width = 210,
  }) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: kSmallMuted),
          const SizedBox(height: 4),
          SelectBox<T>(value: value, items: items, onChanged: onChanged),
        ],
      ),
    );
  }

  /// Step-1 explanation of how the file is read; workbooks stream differently
  /// from text files, so the card switches copy instead of always listing the
  /// text-only properties (the old three-line block was noise on first open).
  List<String> _importModeLines() {
    if (_isExcel) {
      return const <String>[
        '工作表按行流式读取、按批 INSERT 写入（共享字符串表仍需一次加载）；',
        '数字 / 日期 / 布尔 / 文本按原单元格类型识别；校验通过前不会写入任何数据。',
      ];
    }
    return const <String>[
      '大文件按 64 KiB 分块流式读取，内存占用与文件大小无关；',
      '数据按批次生成多行 INSERT 写入；读取规则和字段规则在校验通过前不会写入任何数据。',
    ];
  }

  String _formatLabel(String? format) {
    // Mirrors the exporter's format list: every format the app can write must
    // also be readable here, otherwise an exported file cannot be re-imported.
    return switch (format) {
      'delimited' => '分隔文本（CSV / TSV / 自定义分隔符）',
      'json_array' => 'JSON 数组',
      'json_lines' => 'JSON Lines（每行一个 JSON）',
      'xml' => 'XML（<rows> / <row> / <col>）',
      'html' => 'HTML 表格（<table>）',
      'excel' => 'Excel（SpreadsheetML .xls）',
      'markdown' => 'Markdown 表格（| a | b |）',
      // Workbook containers: the real Excel / ODS files (round 50).
      'xlsx' => 'xlsx / Excel 工作簿',
      'xls' => 'xls / Excel 97-2003 工作簿',
      'xlsb' => 'xlsb / Excel 二进制工作簿',
      'ods' => 'ods / OpenDocument 表格',
      _ => format ?? '未知',
    };
  }
}
