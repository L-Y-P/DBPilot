# Excel 导入测试 fixtures

本目录的两个工作簿由 [gen_fixtures.py](gen_fixtures.py) 生成，**产物直接提交到 git**，
Rust 单测（`desktop/rust/src/importer.rs` 的 `excel_tests`）直接读取它们：

| 文件 | 格式 | 内容 |
| --- | --- | --- |
| `excel_multi.xlsx` | OOXML（ZIP） | 3 个可见工作表（员工 / 订单 / 配置）+ 1 个隐藏工作表 |
| `excel_multi.xls` | BIFF8（OLE2） | 同内容的 3 个可见工作表 |

「员工」表覆盖导出/导入最难的单元格类型：

- `id` 数字、`姓名` 中文文本、`入职日期` 日期（date）、`活跃` 布尔、
  `评分` 小数、`备注` 带 NULL 的文本、`登录时间` 日期时间（datetime）、
  `打卡时间` 纯时间（time）。
- 「订单」「配置」用不同的表头和值，用来断言 `read.sheet` 选表确实换了数据。

## 重新生成

使用 DSH 自带的 Python（openpyxl / xlsxwriter 已内置，xlwt 需要单独装到临时目录）：

```sh
PY=/Users/lyp/.dsh/dsh-runtimes/dsh-next-primary-runtime/dependencies/python/bin/python3
$PY -m pip install --quiet --target /tmp/xlwt_pkg xlwt
PYTHONPATH=/tmp/xlwt_pkg $PY gen_fixtures.py
```

生成脚本会打印每个文件的字节数；两个文件都小于 8 KB，避免把大二进制带进仓库。
