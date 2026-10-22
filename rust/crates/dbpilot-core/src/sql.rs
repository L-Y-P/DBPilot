//! 与方言无关的 SQL 文本工具：引用规则、字面量、DDL 片段与安全校验。
//!
//! 33 轮拆 crate 时从 drivers/mod.rs 搬进契约层：DatabaseDialect /
//! drivers::ops 与 filter 都要用它们，而 core 不能反向依赖 drivers。
//! 具体方言的目录 SQL 仍只在 drivers/<id>/dialect.rs。

use base64::Engine as _;
use serde_json::Value;

use crate::config::DriverKind;
use crate::db::{quote_ident, quote_str, ResultSet};
use crate::error::{AppError, AppResult};

// ---------------------------------------------------------------- identifiers

pub fn qi(driver: DriverKind, name: &str) -> String {
    match driver {
        DriverKind::Mysql => quote_ident(name),
        _ => {
            let mut out = String::with_capacity(name.len() + 2);
            out.push('"');
            for c in name.chars() {
                if c == '"' {
                    out.push('"');
                }
                out.push(c);
            }
            out.push('"');
            out
        }
    }
}

pub fn qualify(driver: DriverKind, ns: &str, table: &str) -> String {
    format!("{}.{}", qi(driver, ns), qi(driver, table))
}

pub fn quote_str_for(driver: DriverKind, value: &str) -> String {
    if driver.is_mysql() {
        quote_str(&value.replace('\\', "\\\\"))
    } else {
        quote_str(value)
    }
}

/// Render a JSON value as a SQL literal for the given dialect.
pub fn literal(driver: DriverKind, value: &Value) -> String {
    match value {
        Value::Null => "NULL".to_string(),
        Value::Bool(b) => match driver {
            DriverKind::Postgres => (if *b { "TRUE" } else { "FALSE" }).to_string(),
            _ => (if *b { "1" } else { "0" }).to_string(),
        },
        Value::Number(n) => n.to_string(),
        Value::String(s) => quote_str_for(driver, s),
        Value::Object(o) => match o.get("__binary__").and_then(|v| v.as_str()) {
            Some(b64) => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(b64)
                    .unwrap_or_default();
                let hex = hex::encode(bytes);
                match driver {
                    DriverKind::Postgres => format!("decode('{}', 'hex')", hex),
                    _ => format!("X'{}'", hex),
                }
            }
            None => quote_str_for(driver, &Value::Object(o.clone()).to_string()),
        },
        other => quote_str_for(driver, &other.to_string()),
    }
}

/// Convert a result set into objects keyed by column name.
///
/// 唯一实现在 `core::connection::rows_to_named`，这里保留旧函数名兼容
/// 既有调用点（P2 再逐步删除别名）。
pub fn named_from(rs: &ResultSet) -> Vec<Value> {
    crate::connection::rows_to_named(rs)
}


/// Build a CREATE DATABASE statement. Kept as a free function so security tests
/// can exercise the PostgreSQL option clauses without opening a pool.
pub fn create_database_sql(
    driver: DriverKind,
    name: &str,
    charset: Option<&str>,
    collation: Option<&str>,
    template: Option<&str>,
    encoding: Option<&str>,
    owner: Option<&str>,
    tablespace: Option<&str>,
) -> AppResult<String> {
    match driver {
        DriverKind::Mysql => {
            let mut s = format!("CREATE DATABASE IF NOT EXISTS {}", qi(driver, name));
            if let Some(cs) = charset.map(str::trim).filter(|s| !s.is_empty()) {
                s.push_str(&format!(" DEFAULT CHARACTER SET {}", safe_ident(cs)?));
            }
            if let Some(co) = collation.map(str::trim).filter(|s| !s.is_empty()) {
                s.push_str(&format!(" COLLATE {}", safe_ident(co)?));
            }
            Ok(s)
        }
        DriverKind::Postgres => {
            let mut sql = format!("CREATE DATABASE {}", qi(driver, name));
            let mut options: Vec<String> = Vec::new();
            if let Some(t) = template.map(str::trim).filter(|s| !s.is_empty()) {
                // Identifier-valued options are quoted, not restricted to ASCII.
                // `qi` escapes embedded quotes, so any role/database/tablespace
                // name remains a single identifier and cannot become SQL.
                options.push(format!("TEMPLATE {}", qi(driver, t)));
            }
            if let Some(value) = encoding.map(str::trim).filter(|s| !s.is_empty()) {
                options.push(format!("ENCODING {}", quote_str_for(driver, value)));
            }
            if let Some(value) = collation.map(str::trim).filter(|s| !s.is_empty()) {
                options.push(format!("LC_COLLATE {}", quote_str_for(driver, value)));
            }
            if let Some(value) = owner.map(str::trim).filter(|s| !s.is_empty()) {
                options.push(format!("OWNER {}", qi(driver, value)));
            }
            if let Some(value) = tablespace.map(str::trim).filter(|s| !s.is_empty()) {
                options.push(format!("TABLESPACE {}", qi(driver, value)));
            }
            if !options.is_empty() {
                sql.push_str(" WITH ");
                sql.push_str(&options.join(" "));
            }
            Ok(sql)
        }
        DriverKind::Sqlite => Err(AppError::bad(
            "SQLite has no CREATE DATABASE; create the file instead",
        )),
    }
}

pub fn safe_ident(value: &str) -> AppResult<String> {
    let value = value.trim();
    if !value.is_empty() && value.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        Ok(value.to_string())
    } else {
        Err(AppError::bad("invalid identifier"))
    }
}

/// Validate a column DEFAULT expression before it is interpolated into DDL.
///
/// The web build pasted the value in verbatim, so a designer request with a
/// default of `0); DROP TABLE x; --` injected arbitrary SQL. A character
/// blacklist (the first fix) still accepted `0, evil INT` and `0), KEY k (c`:
/// both are balanced and comment-free, yet they close the column definition and
/// append another clause.
///
/// The validator therefore parses one DEFAULT expression instead of looking for
/// bad characters: a quoted literal, a number, a known keyword, a function call,
/// or a parenthesised expression, optionally followed by a PostgreSQL `::type`
/// cast. Anything left over — a second bare word (`0 NOT NULL`, `'x' COLLATE
/// evil`), a top-level comma or an unmatched parenthesis — is rejected.
pub fn safe_default(value: &str) -> AppResult<String> {
    let value = value.trim();
    if value.is_empty() {
        return Err(AppError::bad("默认值不能为空"));
    }
    if value.contains('\u{0}') {
        return Err(AppError::bad("默认值包含非法字符"));
    }
    // Statement terminators and comment openers can never appear in a default.
    for forbidden in [";", "--", "/*", "*/", "#"] {
        if value.contains(forbidden) {
            return Err(AppError::bad(format!(
                "默认值包含非法字符 '{}'",
                forbidden
            )));
        }
    }
    let consumed = parse_default_expression(value, 0)
        .ok_or_else(|| AppError::bad(format!("默认值不是合法表达式：{value}")))?;
    if !value[consumed..].trim().is_empty() {
        return Err(AppError::bad(format!(
            "默认值包含多余内容：{}",
            value[consumed..].trim()
        )));
    }
    Ok(value.to_string())
}

/// Byte length of one DEFAULT expression starting at `start`, or None.
fn parse_default_expression(value: &str, start: usize) -> Option<usize> {
    let rest = &value[start..];
    let trimmed = rest.trim_start();
    let mut pos = start + (rest.len() - trimmed.len());
    pos += parse_default_primary(value, pos)?;
    loop {
        let after = &value[pos..];
        let next = after.trim_start();
        let skipped = after.len() - next.len();
        if next.is_empty() {
            return Some(pos);
        }
        if next.starts_with("::") {
            let type_start = pos + skipped + 2;
            let type_end = parse_default_type(value, type_start)?;
            pos = type_end;
            continue;
        }
        return Some(pos);
    }
}

fn is_default_ident_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_' || c == '$'
}

fn parse_default_primary(value: &str, start: usize) -> Option<usize> {
    let rest = &value[start..];
    let first = rest.chars().next()?;
    if first == '(' {
        return parse_balanced_group(value, start);
    }
    if first == '\'' || first == '"' {
        return parse_quoted(value, start, first);
    }
    if first.is_ascii_digit() || first == '-' || first == '+' {
        let mut pos = start;
        let mut seen_digit = false;
        let mut seen_exponent = false;
        for (offset, c) in rest.char_indices() {
            if c.is_ascii_digit() {
                seen_digit = true;
                pos = start + offset + c.len_utf8();
            } else if matches!(c, '.' | 'e' | 'E' | '+' | '-') {
                // A sign is part of the literal at the start or right after a
                // scientific-notation e/E; anywhere else it ends the number.
                let at_start = offset == 0;
                let after_exponent = matches!(c, '+' | '-') && seen_exponent;
                if (c == '+' || c == '-') && !(at_start || after_exponent) {
                    break;
                }
                if matches!(c, 'e' | 'E') {
                    if seen_exponent {
                        break;
                    }
                    seen_exponent = true;
                }
                pos = start + offset + c.len_utf8();
            } else {
                break;
            }
        }
        if let Some(c) = value[pos..].chars().next() {
            if is_default_ident_char(c) {
                return None;
            }
        }
        return if seen_digit { Some(pos) } else { None };
    }
    if first.is_ascii_alphabetic() || first == '_' {
        let mut end = start;
        for (offset, c) in rest.char_indices() {
            if is_default_ident_char(c) {
                end = start + offset + c.len_utf8();
            } else {
                break;
            }
        }
        let word = &value[start..end];
        let upper = word.to_ascii_uppercase();
        let keywords = [
            "NULL",
            "TRUE",
            "FALSE",
            "CURRENT_TIMESTAMP",
            "CURRENT_DATE",
            "CURRENT_TIME",
            "LOCALTIME",
            "LOCALTIMESTAMP",
        ];
        let after_word = value[end..].trim_start();
        let is_call = after_word.starts_with('(');
        if !keywords.contains(&upper.as_str()) && !is_call {
            return None;
        }
        if is_call {
            // Function call: consume the balanced argument list.
            let open = value.len() - after_word.len();
            return parse_balanced_group(value, open);
        }
        return Some(end);
    }
    None
}

/// Parse a balanced `(...)` group starting at `start` (which must be '(').
fn parse_balanced_group(value: &str, start: usize) -> Option<usize> {
    if value.as_bytes().get(start) != Some(&b'(') {
        return None;
    }
    let mut depth = 0usize;
    let mut pos = start;
    while pos < value.len() {
        let c = value[pos..].chars().next()?;
        match c {
            '\'' | '"' => {
                pos = parse_quoted(value, pos, c)?;
            }
            '(' => {
                depth += 1;
                pos += 1;
            }
            ')' => {
                depth -= 1;
                pos += 1;
                if depth == 0 {
                    return Some(pos);
                }
            }
            ';' | '\u{0}' => return None,
            _ => pos += c.len_utf8(),
        }
    }
    None
}

/// Parse one quoted literal (single or double quotes, doubling escapes).
fn parse_quoted(value: &str, start: usize, quote: char) -> Option<usize> {
    let mut pos = start + quote.len_utf8();
    while pos < value.len() {
        let c = value[pos..].chars().next()?;
        if c == '\\' {
            pos += c.len_utf8();
            if pos < value.len() {
                pos += value[pos..].chars().next()?.len_utf8();
            }
            continue;
        }
        if c == quote {
            let next_start = pos + quote.len_utf8();
            if value[next_start..].starts_with(quote) {
                pos = next_start + quote.len_utf8();
                continue;
            }
            return Some(next_start);
        }
        pos += c.len_utf8();
    }
    None
}

/// Parse the type name after `::` (word chars, dots, arrays, quoted names and
/// a parenthesised length such as `varchar(10)`).
fn parse_default_type(value: &str, start: usize) -> Option<usize> {
    let mut pos = start;
    let mut saw_word = false;
    loop {
        let rest = &value[pos..];
        let next = rest.trim_start();
        if next.is_empty() {
            return if saw_word { Some(pos) } else { None };
        }
        let skipped = rest.len() - next.len();
        let c = next.chars().next()?;
        if c.is_ascii_alphanumeric() || c == '_' {
            let base = pos + skipped;
            let mut end = base;
            for (offset, ch) in value[base..].char_indices() {
                if ch.is_ascii_alphanumeric() || ch == '_' || ch == '$' {
                    end = base + offset + ch.len_utf8();
                } else {
                    break;
                }
            }
            pos = end;
            saw_word = true;
        } else if c == '(' {
            pos = parse_balanced_group(value, pos + skipped)?;
        } else if c == '"' {
            pos = parse_quoted(value, pos + skipped, '"')?;
            saw_word = true;
        } else if c == '.' || c == '[' || c == ']' {
            pos += skipped + c.len_utf8();
        } else {
            return if saw_word { Some(pos) } else { None };
        }
    }
}

/// Validate a column type before it is interpolated into DDL.
///
/// The first version only allowed `[A-Za-z0-9 (),_]`, which rejected perfectly
/// valid types the app itself offers: `ENUM('a','b')`, `int[]`, and the quoted
/// PostgreSQL type names. Sync then failed on any table that used one. The
/// validator now allows quotes / brackets / dots and still rejects everything
/// that can end a statement or open a comment, plus unbalanced quotes or
/// parentheses (so a type cannot smuggle a closing parenthesis).
pub fn safe_type(value: &str) -> bool {
    let value = value.trim();
    if value.is_empty() || value.contains('\u{0}') {
        return false;
    }
    for forbidden in [";", "--", "/*", "*/", "#"] {
        if value.contains(forbidden) {
            return false;
        }
    }
    let mut in_single = false;
    let mut in_double = false;
    let mut depth: i32 = 0;
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        if in_single {
            if c == '\'' {
                if chars.peek() == Some(&'\'') {
                    chars.next();
                } else {
                    in_single = false;
                }
            }
            continue;
        }
        if in_double {
            if c == '"' {
                if chars.peek() == Some(&'"') {
                    chars.next();
                } else {
                    in_double = false;
                }
            }
            continue;
        }
        match c {
            '\'' => in_single = true,
            '"' => in_double = true,
            '(' | '[' => depth += 1,
            ')' | ']' => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            c if c.is_ascii_alphanumeric() => {}
            ' ' | ',' | '_' | '.' | '+' | '-' => {}
            _ => return false,
        }
    }
    !in_single && !in_double && depth == 0
}
