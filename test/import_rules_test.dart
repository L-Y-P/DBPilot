// Pure unit tests for the guided-import rule model and job polling helpers.

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/i18n_literals.dart';
import 'package:rust_myadmin_desktop/src/import_rules.dart';
import 'package:rust_myadmin_desktop/src/sqlite_sources.dart';

void main() {
  group('escape helpers', () {
    test('decodeEscapes turns typed escape sequences into characters', () {
      expect(decodeEscapes(r'\n'), '\n');
      expect(decodeEscapes(r'\t'), '\t');
      expect(decodeEscapes(r'\r'), '\r');
      expect(decodeEscapes(r'\\'), r'\');
      expect(decodeEscapes(r'\N'), r'\N');
      expect(decodeEscapes('plain'), 'plain');
      expect(decodeEscapes(r'\n\n'), '\n\n');
    });

    test('encodeEscapes round-trips control characters', () {
      for (final value in <String>['\n', '\t', '\r', '\u0000', ',', '|']) {
        expect(decodeEscapes(encodeEscapes(value)), value);
      }
      expect(encodeEscapes('\n'), r'\n');
    });
  });

  group('rule serialization', () {
    test('read rule survives the JSON round-trip', () {
      final rule = ImportReadRule(
        mode: 'wrapped',
        wrapperStart: '[',
        wrapperEnd: ']',
        recordSep: ',',
        quote: '"',
        balance: false,
        skipBlank: false,
        trim: false,
      );
      final restored = ImportReadRule.fromJson(
        Map<String, dynamic>.from(rule.toJson()),
      );
      expect(restored.mode, 'wrapped');
      expect(restored.wrapperStart, '[');
      expect(restored.wrapperEnd, ']');
      expect(restored.recordSep, ',');
      expect(restored.balance, isFalse);
      expect(restored.skipBlank, isFalse);
      expect(restored.trim, isFalse);
    });

    test('field and mapping rules serialize to the Rust contract keys', () {
      final field = ImportFieldRule(
        mode: 'json',
        fieldSep: '|',
        quote: "'",
        header: true,
      );
      final json = field.toJson();
      expect(json['mode'], 'json');
      expect(json['field_sep'], '|');
      expect(json['quote'], "'");
      expect(json['header'], isTrue);

      final mapping = ImportMappingRule(
        columns: [
          ImportColumnMap(column: 'id', source: 'id'),
          ImportColumnMap(column: 'age', source: 2),
        ],
      );
      final mapJson = mapping.toJson();
      expect((mapJson['columns'] as List).length, 2);
      expect((mapJson['columns'] as List).first['source'], 'id');
      expect((mapJson['columns'] as List).last['source'], 2);
      expect(mapJson['null_tokens'], <String>[r'\N']);
    });
  });

  group('auto mapping', () {
    test('keyed mapping matches names case-insensitively in table order', () {
      final mapped = autoMapKeyed(
        <String>['ID', 'Name', 'extra'],
        <String>['name', 'id', 'note'],
      );
      expect(mapped.map((m) => m.column).toList(), <String>['name', 'id']);
      expect(mapped[0].source, 'Name');
      expect(mapped[1].source, 'ID');
      expect(mapped.map((m) => m.source).every((s) => s is String), isTrue);
    });

    test('positional mapping skips auto-increment columns when possible', () {
      final mapped = autoMapPositional(
        2,
        <String>['id', 'name', 'age'],
        autoIncrementColumns: <String>{'id'},
      );
      expect(mapped.map((m) => m.column).toList(), <String>['name', 'age']);
      expect(mapped.map((m) => m.source).toList(), <int>[0, 1]);
    });

    test('positional mapping falls back when there are not enough columns', () {
      final mapped = autoMapPositional(
        3,
        <String>['id', 'name'],
        autoIncrementColumns: <String>{'id'},
      );
      expect(mapped.map((m) => m.column).toList(), <String>['id', 'name']);
    });
  });

  group('position labels', () {
    test('recordPositionLabel formats line, record and byte offset', () {
      expect(recordPositionLabel(12, 1024, 8), '第 12 行（第 9 条，字节 1024）');
      expect(recordPositionLabel(3, 40), '第 3 行（字节 40）');
    });

    test('issuePositionLabel appends the problem message', () {
      expect(
        issuePositionLabel(<String, dynamic>{
          'line': 5,
          'offset': 120,
          'index': 2,
          'message': '字段数不符',
        }),
        '第 5 行（第 3 条，字节 120）：字段数不符',
      );
    });
  });

  group('worksheet rules (Excel / ODS)', () {
    test('sheet and skipRows survive the JSON round-trip', () {
      final rule = ImportReadRule(sheet: 'Sheet2', skipRows: 3);
      expect(rule.isWorksheet, isTrue);
      final json = rule.toJson();
      expect(json['sheet'], 'Sheet2');
      expect(json['skip_rows'], 3);

      final restored = ImportReadRule.fromJson(Map<String, dynamic>.from(json));
      expect(restored.sheet, 'Sheet2');
      expect(restored.skipRows, 3);
      expect(restored.isWorksheet, isTrue);
    });

    test('text-file payloads carry no worksheet keys', () {
      final json = ImportReadRule().toJson();
      expect(json.containsKey('sheet'), isFalse);
      expect(json.containsKey('skip_rows'), isFalse);
    });

    test(
      'fromJson defaults the workbook fields when the backend omits them',
      () {
        final rule = ImportReadRule.fromJson(<String, dynamic>{
          'mode': 'line',
          'record_sep': '\n',
        });
        expect(rule.sheet, isNull);
        expect(rule.skipRows, 0);
        expect(rule.isWorksheet, isFalse);
      },
    );

    test('skip_rows is sent even without a sheet when it is set', () {
      // A workbook may be described by index in a future backend; the skip
      // count is meaningful on its own.
      final json = ImportReadRule(skipRows: 2).toJson();
      expect(json['skip_rows'], 2);
      expect(json.containsKey('sheet'), isFalse);
    });

    test('copyWith keeps, replaces and clears the worksheet', () {
      final rule = ImportReadRule(sheet: 'A', skipRows: 1);
      expect(rule.copyWith(skipRows: 4).sheet, 'A');
      expect(rule.copyWith(sheet: 'B').sheet, 'B');
      expect(rule.copyWith(clearSheet: true).sheet, isNull);
    });

    test('describe names the worksheet and skipped rows', () {
      expect(ImportReadRule(sheet: 'Sheet1').describe(), 'Excel 工作表 "Sheet1"');
      expect(
        ImportReadRule(sheet: 'Sheet1', skipRows: 2).describe(),
        'Excel 工作表 "Sheet1" · 跳过开头 2 行',
      );
    });

    test('the Excel field rule has no delimiter description', () {
      final rule = ImportFieldRule(mode: 'excel', header: true);
      expect(rule.isExcel, isTrue);
      expect(rule.describe(), 'Excel 单元格 · 首行为列名');
      expect(ImportFieldRule(mode: 'excel').describe(), 'Excel 单元格 · 无列名（按位置）');
    });
  });

  group('English copy (round 50)', () {
    tearDown(() => I18n.setLang(AppLang.zh));

    test('new worksheet copy renders in English', () {
      I18n.setLang(AppLang.en);
      const copy = <String>[
        '工作表与表头',
        '建立关联',
        '下一步：建立关联',
        '完成并返回',
        '工作表',
        '默认工作表',
        '首行为列名',
        '跳过开头行数',
        '刷新预览',
        '前几行数据预览',
        '校验整个文件',
        '校验整个工作表',
        '校验整个工作表（含字段与类型转换）',
        '整个工作表都能按当前读取规则切分。',
        '整个工作表都能按当前字段规则与列映射解析并转换。',
        '单元格类型按 Excel 原类型识别（数字 / 日期 / 布尔 / 文本）。',
        '工作表读取规则校验通过，可以继续。',
        '选择工作表与表头、设置跳过开头的行数，然后校验整个工作表；校验通过才能继续。',
        '确认列映射，先“试插入”，再校验整个工作表；两项都通过才能继续。',
        '导入已结束：下一步可以建立表间关联，也可以直接关闭。',
        '字段方式固定为 Excel 单元格：数字 / 日期 / 布尔 / 文本按原单元格类型识别；'
            '分隔符、引号等文本拆分设置不适用于工作簿。',
        '添加表并连接字段建立外键；关系修改会立即写入数据库。',
        '工作簿是二进制/压缩格式，不显示文件开头预览；下一步可选择要导入的工作表。',
        '关系修改会立即写入数据库；也可以稍后从数据库页的关系图入口再配置。',
        '工作表会整表载入内存后按批 INSERT 写入（超大工作簿请关注内存占用）；',
        '数字 / 日期 / 布尔 / 文本按原单元格类型识别；校验通过前不会写入任何数据。',
        '数据按批次生成多行 INSERT 写入；读取规则和字段规则在校验通过前不会写入任何数据。',
        '工作簿较大：读取时会整表载入内存后分批插入；界面保持响应，可随时取消。',
        'xlsx / Excel 工作簿',
        'xls / Excel 97-2003 工作簿',
        'xlsb / Excel 二进制工作簿',
        'ods / OpenDocument 表格',
        'Excel 单元格 · 首行为列名',
        'Excel 单元格 · 无列名（按位置）',
      ];
      for (final zh in copy) {
        expect(
          trLiteral(zh),
          isNot(zh),
          reason: 'missing English translation for "$zh"',
        );
      }
    });

    test('worksheet rule summaries translate', () {
      I18n.setLang(AppLang.en);
      expect(
        trLiteral(ImportReadRule(sheet: 'Sheet1').describe()),
        'Excel worksheet "Sheet1"',
      );
      expect(
        trLiteral(ImportReadRule(sheet: 'Sheet1', skipRows: 2).describe()),
        'Excel worksheet "Sheet1" · skip first 2 row(s)',
      );
      expect(
        trLiteral(ImportFieldRule(mode: 'excel', header: true).describe()),
        'Excel cells · first row holds column names',
      );
      expect(
        trLiteral('工作表 Sheet1 · 第 120/500 行'),
        'Worksheet Sheet1 · row 120/500',
      );
    });
  });
  group('data file picker', () {
    test('offers every workbook extension the importer reads', () {
      for (final extension in <String>[
        'xls',
        'xlsx',
        'xlsm',
        'xlsb',
        'ods',
        'xml',
        'html',
        'htm',
        'md',
        'markdown',
      ]) {
        expect(
          dataFileExtensions,
          contains(extension),
          reason: 'the native picker must offer .$extension files',
        );
      }
    });

    test('keeps the delimited and JSON extensions', () {
      for (final extension in <String>[
        'csv',
        'tsv',
        'txt',
        'tab',
        'json',
        'jsonl',
        'ndjson',
        'log',
        'dat',
        'data',
      ]) {
        expect(dataFileExtensions, contains(extension));
      }
    });
  });

  test('formatCount groups thousands', () {
    expect(formatCount(0), '0');
    expect(formatCount(999), '999');
    expect(formatCount(50000), '50,000');
    expect(formatCount(1234567), '1,234,567');
  });
}
