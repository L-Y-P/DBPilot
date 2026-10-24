use base64::Engine as _;
use serde::Serialize;
use serde_json::Value;

pub const BT: char = '\u{60}';
pub const SQ: char = '\u{27}';
pub const DQ: char = '\u{22}';
pub const BS: char = '\u{5c}';
pub const NL: char = '\u{a}';

#[derive(Debug, Serialize, Clone)]
pub struct ColumnMeta {
    pub name: String,
    pub type_name: String,
}

#[derive(Serialize)]
pub struct ResultSet {
    pub columns: Vec<ColumnMeta>,
    pub rows: Vec<Vec<Value>>,
    pub row_count: u64,
    pub last_insert_id: u64,
    pub statement: String,
    pub kind: String,
    pub error: Option<String>,
    /// True when the statement returned more rows than the caller's limit and
    /// the result was cut off there. Only the SQL console sets a limit; every
    /// other caller (table browsing is paged, import/backup are not row
    /// queries) leaves this false.
    pub truncated: bool,
}

/// One chunk of a streaming result set (optimisation layer 3).
///
/// `SessionHandle::run_batched` hands rows to the caller in batches so a large
/// SQL-console result never has to be materialised in full. `columns` is
/// repeated on every batch; observers forward it only with the first event.
/// `truncated` marks the batch after which the row cap stopped the scan.
#[derive(Debug, Clone, Default)]
pub struct ResultBatch {
    pub columns: Vec<ColumnMeta>,
    pub rows: Vec<Vec<Value>>,
    pub truncated: bool,
}

/// One cell decoded straight from a driver row, before the typed DTO conversion.
///
/// The SQL-console typed/streaming path uses this to skip the intermediate
/// `serde_json::Value` representation that the legacy `run_query` JSON contract
/// was built around: that tree is built per cell only to be decoded again into
/// the typed cell DTO by the engine, so for a large result set it is pure
/// overhead. The legacy JSON response is still produced from the typed cells.

///
/// The variants mirror the typed cell kinds plus [RawCell::UInt], which MySQL's
/// `BIGINT UNSIGNED` needs above `i64::MAX`. [RawCell::into_legacy_json] keeps
/// such a value a JSON number (exactly like the pre-typed `value_to_json`
/// output); the DTO conversion in the main crate turns it into text, exactly
/// like `CellValue::from_json` always did for u64 values above i64::MAX.
#[derive(Debug, Clone, PartialEq)]
pub enum RawCell {
    Null,
    Bool(bool),
    Int(i64),
    UInt(u64),
    Float(f64),
    Text(String),
    Bytes(Vec<u8>),
}

impl RawCell {
    /// Inverse of the drivers' `value_to_json`: turn a legacy JSON cell back
    /// into a [RawCell].
    ///
    /// This is the fallback for drivers that have no raw decoder yet
    /// (PostgreSQL / SQLite): the engine still receives [RawCell]s, but they go
    /// through the legacy representation first. The rules must stay the exact
    /// mirror of the MySQL decoder *and* of `CellValue::from_json` in the main
    /// crate:
    ///
    /// * `null` -> [RawCell::Null];
    /// * booleans -> [RawCell::Bool];
    /// * integers -> [RawCell::Int], positive integers above `i64::MAX` ->
    ///   [RawCell::UInt], other numbers -> [RawCell::Float];
    /// * strings -> [RawCell::Text];
    /// * `{"__binary__": <base64>, "len": <n>}` -> [RawCell::Bytes];
    /// * a malformed binary marker or any other object/array -> [RawCell::Text]
    ///   holding its JSON text (the same lossless-ish fallback as
    ///   `CellValue::from_json`; drivers never produce those shapes).
    pub fn from_legacy_json(value: Value) -> Self {
        match value {
            Value::Null => RawCell::Null,
            Value::Bool(value) => RawCell::Bool(value),
            Value::Number(number) => {
                if let Some(value) = number.as_i64() {
                    RawCell::Int(value)
                } else if let Some(value) = number.as_u64() {
                    // Only reachable above i64::MAX (as_i64 covers the rest).
                    RawCell::UInt(value)
                } else if let Some(value) = number.as_f64() {
                    RawCell::Float(value)
                } else {
                    RawCell::Text(number.to_string())
                }
            }
            Value::String(value) => RawCell::Text(value),
            Value::Object(map) => match map.get("__binary__").and_then(Value::as_str) {
                Some(encoded) => match base64::engine::general_purpose::STANDARD.decode(encoded) {
                    Ok(bytes) => RawCell::Bytes(bytes),
                    // Same rule as CellValue::from_json: a malformed marker is
                    // preserved as text, never silently turned into NULL.
                    Err(_) => RawCell::Text(Value::Object(map).to_string()),
                },
                None => RawCell::Text(Value::Object(map).to_string()),
            },
            Value::Array(items) => RawCell::Text(Value::Array(items).to_string()),
        }
    }

    /// Back to the legacy JSON cell shape (`value_to_json` output).
    ///
    /// Consumes the cell so text and bytes payloads move instead of being
    /// cloned. `UInt` stays a JSON number here: that is what the pre-typed
    /// driver path produced, and it is what keeps the documented legacy
    /// contract recoverable byte for byte.
    pub fn into_legacy_json(self) -> Value {
        match self {
            RawCell::Null => Value::Null,
            RawCell::Bool(value) => Value::Bool(value),
            RawCell::Int(value) => Value::Number(value.into()),
            RawCell::UInt(value) => Value::Number(value.into()),
            // Non-finite floats are not representable in JSON; the legacy
            // `json!(f64)` also produced null for them.
            RawCell::Float(value) => serde_json::Number::from_f64(value)
                .map(Value::Number)
                .unwrap_or(Value::Null),
            RawCell::Text(value) => Value::String(value),
            RawCell::Bytes(bytes) => serde_json::json!({
                "__binary__": base64::engine::general_purpose::STANDARD.encode(&bytes),
                "len": bytes.len(),
            }),
        }
    }
}

/// One chunk of a raw streaming result set (optimisation layer 3, raw variant).
///
/// Same contract as [ResultBatch], but rows are [RawCell]s: the SQL-console
/// typed/streaming path never builds `serde_json::Value` for them, while the
/// legacy `run_query` JSON response is still produced from the typed cells.
#[derive(Debug, Clone, Default)]
pub struct RawResultBatch {
    pub columns: Vec<ColumnMeta>,
    pub rows: Vec<Vec<RawCell>>,
    pub truncated: bool,
}

impl RawResultBatch {
    /// Default (JSON fallback) batch conversion used by drivers without a raw
    /// decoder: mirrors [ResultBatch] into [RawResultBatch] cell by cell.
    pub fn from_result_batch(batch: ResultBatch) -> Self {
        Self {
            columns: batch.columns,
            rows: batch
                .rows
                .into_iter()
                .map(|row| row.into_iter().map(RawCell::from_legacy_json).collect())
                .collect(),
            truncated: batch.truncated,
        }
    }
}

/// Outcome of a streaming row scan used by the export path.
#[derive(Default)]
pub struct ScanStats {
    pub rows: u64,
    /// Column metadata, available once the first row was decoded.
    pub columns: Vec<ColumnMeta>,
    /// True when the callback asked to stop before the result set ended; the
    /// connection was then closed instead of being returned to the pool.
    pub stopped_early: bool,
}

/// Quote a MySQL identifier with backticks, doubling embedded backticks.
pub fn quote_ident(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 2);
    out.push(BT);
    for c in name.chars() {
        if c == BT {
            out.push(BT);
        }
        out.push(c);
    }
    out.push(BT);
    out
}

pub fn qualified(db: &str, table: &str) -> String {
    format!("{}.{}", quote_ident(db), quote_ident(table))
}

/// Quote a string literal using SQL-standard doubled single quotes.
pub fn quote_str(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push(SQ);
    for c in s.chars() {
        if c == SQ {
            out.push(SQ);
        }
        out.push(c);
    }
    out.push(SQ);
    out
}

// P4 已完成 db.rs 中性化：MySQL 专属的行解码与语句执行在
// drivers/mysql/{row,exec}.rs；这里只剩 ResultSet/ColumnMeta/ScanStats、
// 引用 helper、语句切分与 returns_rows。
//
// 关于 returns_rows 的关键字表：它是**跨方言并集**（SELECT/SHOW/DESCRIBE/
// EXPLAIN/WITH/TABLE/VALUES/CALL/ANALYZE/CHECK/OPTIMIZE/REPAIR/HELP/PRAGMA），
// 刻意不做成按方言切换：某个关键字在别的方言里不会出现，并集只会更稳，
// 拆成三份反而多一处漂移点。因此这里不再留 TODO。
pub fn split_statements(sql: &str) -> Vec<String> {
    split_statements_inner(sql, true)
}

/// 按方言切分语句（P4 接线）。
///
/// `DELIMITER` 是 MySQL 客户端指令：只有声明的方言能力支持它时才当指令处理，
/// 其它方言按普通 SQL 切分（SQLite 下 `DELIMITER //` 会交给服务端报错，
/// 而不是被客户端静默吞掉）。`$$` 美元引用体与引号/注释状态对所有方言一致保留
/// —— 它只在字符串外出现 `$tag$` 时才触发，对 MySQL/SQLite 的正则 SQL 无影响。
pub fn split_statements_for(
    dialect: &dyn crate::dialect::DatabaseDialect,
    sql: &str,
) -> Vec<String> {
    split_statements_inner(sql, dialect.supports_delimiter_directive())
}

fn split_statements_inner(sql: &str, allow_delimiter: bool) -> Vec<String> {
    let chars: Vec<char> = sql.chars().collect();
    let n = chars.len();
    let mut i = 0usize;
    // 0 normal, 1 ', 2 ", 3 backtick, 4 line comment, 5 block comment,
    // 6 PostgreSQL dollar-quoted body.
    let mut state = 0u8;
    let mut dollar_tag: Vec<char> = Vec::new();
    let mut cur = String::new();
    let mut has_code = false;
    let mut delimiter: Vec<char> = vec![';'];
    let mut statements = Vec::new();

    while i < n {
        let c = chars[i];

        // A state-6 body ends when its exact closing tag appears.
        if state == 6 {
            let tag_len = dollar_tag.len();
            if tag_len > 0 && i + tag_len <= n && chars[i..i + tag_len] == dollar_tag[..] {
                cur.extend(dollar_tag.iter());
                i += tag_len;
                state = 0;
                continue;
            }
            cur.push(c);
            i += 1;
            continue;
        }

        if state == 0 && !has_code {
            let word: String = chars[i..(i + 9).min(n)].iter().collect();
            // The keyword must be followed by whitespace; `delimiter_count` is a
            // column name, not a DELIMITER directive.
            let followed_by_space = i + 9 >= n || chars[i + 9].is_whitespace();
            if allow_delimiter && followed_by_space && word.eq_ignore_ascii_case("delimiter") {
                let mut j = i;
                while j < n && chars[j] != NL {
                    j += 1;
                }
                let token: String = chars[i + 9..j].iter().collect();
                let token = token.trim();
                if !token.is_empty() {
                    delimiter = token.chars().collect();
                }
                i = j + 1;
                continue;
            }
        }

        if state == 0 {
            let dl = delimiter.len();
            if dl > 0 && i + dl <= n && chars[i..i + dl] == delimiter[..] {
                if has_code {
                    statements.push(cur.trim().to_string());
                }
                cur.clear();
                has_code = false;
                i += dl;
                continue;
            }
        }

        match state {
            0 => match c {
                SQ => {
                    state = 1;
                    cur.push(c);
                    has_code = true;
                }
                DQ => {
                    state = 2;
                    cur.push(c);
                    has_code = true;
                }
                BT => {
                    state = 3;
                    cur.push(c);
                    has_code = true;
                }
                '-' if i + 1 < n && chars[i + 1] == '-' => {
                    state = 4;
                    cur.push(c);
                    cur.push('-');
                    i += 1;
                }
                '#' => {
                    state = 4;
                    cur.push(c);
                }
                '/' if i + 1 < n && chars[i + 1] == '*' => {
                    // `/*!...*/` is a MySQL executable comment: the server runs
                    // its content. Keep it as code instead of dropping the whole
                    // statement. `/*+ ... */` optimizer hints also stay attached
                    // to the following statement, so both are pushed verbatim.
                    if i + 2 < n && chars[i + 2] == '!' {
                        cur.push(c);
                        cur.push('*');
                        has_code = true;
                        i += 2;
                        continue;
                    }
                    state = 5;
                    cur.push(c);
                    cur.push('*');
                    i += 1;
                }
                '$' => {
                    // PostgreSQL dollar-quoted string: `$$` or `$tag$`.
                    if let Some((tag, len)) = dollar_quote_at(&chars, i) {
                        cur.extend(tag.iter());
                        dollar_tag = tag;
                        has_code = true;
                        state = 6;
                        i += len;
                        continue;
                    }
                    has_code = true;
                    cur.push(c);
                }
                _ => {
                    if !c.is_whitespace() {
                        has_code = true;
                    }
                    cur.push(c);
                }
            },
            1 => {
                if c == BS {
                    cur.push(c);
                    if i + 1 < n {
                        cur.push(chars[i + 1]);
                        i += 1;
                    }
                } else {
                    if c == SQ {
                        state = 0;
                    }
                    cur.push(c);
                }
            }
            2 => {
                if c == BS {
                    cur.push(c);
                    if i + 1 < n {
                        cur.push(chars[i + 1]);
                        i += 1;
                    }
                } else {
                    if c == DQ {
                        state = 0;
                    }
                    cur.push(c);
                }
            }
            3 => {
                if c == BT {
                    state = 0;
                }
                cur.push(c);
            }
            4 => {
                cur.push(c);
                if c == NL {
                    state = 0;
                }
            }
            5 => {
                cur.push(c);
                if c == '*' && i + 1 < n && chars[i + 1] == '/' {
                    cur.push('/');
                    i += 1;
                    state = 0;
                }
            }
            _ => {}
        }
        i += 1;
    }

    if has_code {
        statements.push(cur.trim().to_string());
    }
    statements.retain(|s| !s.is_empty());
    statements
}

/// Recognise a PostgreSQL dollar-quote opener at `chars[start] == '$'`.
///
/// Returns the complete tag (`$$` or `$name$`) and its length. `$1` is a
/// positional parameter, not a quote, so a tag may not start with a digit.
fn dollar_quote_at(chars: &[char], start: usize) -> Option<(Vec<char>, usize)> {
    let n = chars.len();
    let mut j = start + 1;
    if j < n && chars[j] == '$' {
        return Some((vec!['$', '$'], 2));
    }
    let mut name = String::new();
    while j < n {
        let c = chars[j];
        if c == '$' {
            if name.is_empty() {
                return None;
            }
            let mut tag: Vec<char> = Vec::with_capacity(name.len() + 2);
            tag.push('$');
            tag.extend(name.chars());
            tag.push('$');
            return Some((tag, j - start + 1));
        }
        let valid = c.is_ascii_alphanumeric() || c == '_';
        if !valid || (name.is_empty() && c.is_ascii_digit()) {
            return None;
        }
        name.push(c);
        j += 1;
    }
    None
}

pub fn strip_leading_comments(input: &str) -> &str {
    let mut s = input.trim_start();
    loop {
        if s.starts_with("--") || s.starts_with("#") {
            match s.find(NL) {
                Some(i) => s = s[i + 1..].trim_start(),
                None => return "",
            }
        } else if s.starts_with("/*") {
            match s.find("*/") {
                Some(i) => s = s[i + 2..].trim_start(),
                None => return "",
            }
        } else {
            return s;
        }
    }
}

pub fn returns_rows(stmt: &str) -> bool {
    let s = strip_leading_comments(stmt);
    let first = s.split_whitespace().next().unwrap_or("").to_ascii_uppercase();
    matches!(
        first.as_str(),
        "SELECT" | "SHOW" | "DESCRIBE" | "DESC" | "EXPLAIN" | "WITH" | "TABLE" | "VALUES"
            | "CALL" | "ANALYZE" | "CHECK" | "OPTIMIZE" | "REPAIR" | "HELP" | "PRAGMA"
    )
}


#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn binary_cell(bytes: &[u8]) -> Value {
        json!({
            "__binary__": base64::engine::general_purpose::STANDARD.encode(bytes),
            "len": bytes.len(),
        })
    }

    #[test]
    fn raw_cell_round_trips_the_legacy_json_cell_shapes() {
        for value in [
            Value::Null,
            json!(true),
            json!(false),
            json!(-7),
            json!(42),
            json!(i64::MAX),
            // MySQL BIGINT UNSIGNED above i64::MAX: the legacy shape is a
            // JSON number, so the raw cell must keep the number here.
            json!(u64::MAX),
            json!(9_223_372_036_854_775_808u64),
            json!(1.25),
            json!("text"),
            json!(""),
            binary_cell(&[0, 1, 254, 255]),
            binary_cell(&[]),
        ] {
            let raw = RawCell::from_legacy_json(value.clone());
            assert_eq!(
                raw.clone().into_legacy_json(),
                value,
                "raw round trip changed the legacy cell for {value}"
            );
        }
    }

    #[test]
    fn raw_cell_uses_uint_only_above_i64_max() {
        assert_eq!(RawCell::from_legacy_json(json!(0)), RawCell::Int(0));
        assert_eq!(
            RawCell::from_legacy_json(json!(i64::MAX)),
            RawCell::Int(i64::MAX)
        );
        assert_eq!(
            RawCell::from_legacy_json(json!(u64::MAX)),
            RawCell::UInt(u64::MAX)
        );
        // The legacy JSON number is preserved, not rounded through f64.
        assert_eq!(
            RawCell::UInt(u64::MAX).into_legacy_json(),
            json!(u64::MAX)
        );
    }

    #[test]
    fn raw_cell_keeps_the_binary_marker_contract() {
        assert_eq!(
            RawCell::from_legacy_json(binary_cell(&[0, 255])),
            RawCell::Bytes(vec![0, 255])
        );
        assert_eq!(
            RawCell::Bytes(vec![0, 255]).into_legacy_json(),
            binary_cell(&[0, 255])
        );
        // Empty payloads stay bytes, not NULL.
        assert_eq!(
            RawCell::from_legacy_json(binary_cell(&[])),
            RawCell::Bytes(Vec::new())
        );
        // A malformed marker degrades to text instead of becoming NULL.
        let malformed = json!({ "__binary__": "not base64!!", "len": 3 });
        assert_eq!(
            RawCell::from_legacy_json(malformed.clone()),
            RawCell::Text(malformed.to_string())
        );
        // A plain object/array has no raw variant: text, like CellValue::from_json.
        assert_eq!(
            RawCell::from_legacy_json(json!({ "a": 1 })),
            RawCell::Text("{\"a\":1}".to_string())
        );
        assert_eq!(
            RawCell::from_legacy_json(json!([1, 2])),
            RawCell::Text("[1,2]".to_string())
        );
    }

    #[test]
    fn non_finite_floats_degrade_to_null_like_json_macro() {
        assert_eq!(RawCell::Float(f64::NAN).into_legacy_json(), Value::Null);
        assert_eq!(RawCell::Float(f64::INFINITY).into_legacy_json(), Value::Null);
        assert_eq!(
            RawCell::Float(1.5).into_legacy_json(),
            json!(1.5),
            "finite floats must stay numbers"
        );
    }

    #[test]
    fn from_result_batch_converts_every_cell_and_preserves_meta() {
        let batch = ResultBatch {
            columns: vec![ColumnMeta {
                name: "id".to_string(),
                type_name: "BIGINT".to_string(),
            }],
            rows: vec![
                vec![json!(1), binary_cell(&[7])],
                vec![Value::Null, json!(u64::MAX)],
            ],
            truncated: true,
        };
        let raw = RawResultBatch::from_result_batch(batch);
        assert_eq!(raw.columns.len(), 1);
        assert!(raw.truncated);
        assert_eq!(
            raw.rows,
            vec![
                vec![RawCell::Int(1), RawCell::Bytes(vec![7])],
                vec![RawCell::Null, RawCell::UInt(u64::MAX)],
            ]
        );
    }
}

