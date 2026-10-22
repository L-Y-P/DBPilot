//! Strict parser for the table-browser `where` filter.
//!
//! The browser builds a filter string such as
//! `` `salary` > 10000 AND `dept` = 'IT' `` and used to hand it straight to the
//! driver, which concatenated it into the query. That turned a read-only
//! browsing API into an arbitrary-SQL entry point.
//!
//! This module re-parses the filter against the table's real column list and
//! only accepts a tiny grammar:
//!
//! ```text
//! filter   := condition (AND condition)*
//! condition := column op value | column IS [NOT] NULL
//! op        := = | != | <> | > | >= | < | <= | LIKE | NOT LIKE | IN
//! value     := number | 'string' | NULL | ( value (, value)* )
//! ```
//!
//! Everything else — sub-queries, comments, semicolons, function calls, OR,
//! column names that do not exist — is rejected. The output is rebuilt from the
//! parsed tokens with proper quoting, so nothing from the request is copied into
//! the SQL verbatim except literal values, which are re-quoted.

use crate::config::DriverKind;
use crate::error::{AppError, AppResult};
use crate::sql::{qi, quote_str_for};

fn err(msg: impl Into<String>) -> AppError {
    AppError::bad(msg.into())
}

const MAX_FILTER_LEN: usize = 4096;

pub fn parse_filter(raw: &str, columns: &[String], driver: DriverKind) -> AppResult<String> {
    if raw.len() > MAX_FILTER_LEN {
        return Err(err("筛选条件过长"));
    }
    let mut parser = Parser {
        chars: raw.chars().collect(),
        pos: 0,
        driver,
        columns,
    };
    let out = parser.parse()?;
    if !parser.at_end() {
        return Err(err("筛选条件解析未结束，请检查语法"));
    }
    Ok(out)
}

struct Parser<'a> {
    chars: Vec<char>,
    pos: usize,
    driver: DriverKind,
    columns: &'a [String],
}

impl<'a> Parser<'a> {
    fn skip_ws(&mut self) {
        while self.pos < self.chars.len() && self.chars[self.pos].is_whitespace() {
            self.pos += 1;
        }
    }

    fn at_end(&mut self) -> bool {
        self.skip_ws();
        self.pos >= self.chars.len()
    }

    fn peek(&self) -> Option<char> {
        self.chars.get(self.pos).copied()
    }

    fn peek_at(&self, offset: usize) -> Option<char> {
        self.chars.get(self.pos + offset).copied()
    }

    fn parse(&mut self) -> AppResult<String> {
        let mut parts = Vec::new();
        loop {
            parts.push(self.parse_condition()?);
            if self.at_end() {
                break;
            }
            if !self.match_word("AND") {
                return Err(err("条件之间只能使用 AND 连接"));
            }
            if self.at_end() {
                return Err(err("AND 之后缺少条件"));
            }
        }
        Ok(parts.join(" AND "))
    }

    fn parse_condition(&mut self) -> AppResult<String> {
        let raw_name = self.read_ident()?;
        let column = self.resolve_column(&raw_name)?;
        let quoted = qi(self.driver, column);

        self.skip_ws();
        if let Some(op) = self.try_symbol_operator() {
            let value = self.read_literal()?;
            return Ok(format!("{} {} {}", quoted, op, value));
        }

        let word = self.read_word()?;
        match word.to_ascii_uppercase().as_str() {
            "IS" => {
                let negated = self.match_word("NOT");
                if !self.match_word("NULL") {
                    return Err(err("IS 之后只支持 NULL 或 NOT NULL"));
                }
                Ok(format!(
                    "{} IS {}{}",
                    quoted,
                    if negated { "NOT " } else { "" },
                    "NULL"
                ))
            }
            "LIKE" => {
                let value = self.read_literal()?;
                Ok(format!("{} LIKE {}", quoted, value))
            }
            "NOT" => {
                if !self.match_word("LIKE") {
                    return Err(err("NOT 之后只支持 LIKE"));
                }
                let value = self.read_literal()?;
                Ok(format!("{} NOT LIKE {}", quoted, value))
            }
            "IN" => {
                let list = self.read_in_list()?;
                Ok(format!("{} IN ({})", quoted, list))
            }
            other => Err(err(format!("不支持的比较运算符 '{}'", other))),
        }
    }

    /// Column names are matched case-insensitively against the table metadata
    /// and the canonical name from the metadata is used in the output.
    fn resolve_column(&self, name: &str) -> AppResult<&'a str> {
        self.columns
            .iter()
            .find(|c| c.eq_ignore_ascii_case(name))
            .map(|c| c.as_str())
            .ok_or_else(|| err(format!("未知列 '{}'", name)))
    }

    fn read_ident(&mut self) -> AppResult<String> {
        self.skip_ws();
        let Some(first) = self.peek() else {
            return Err(err("筛选条件为空"));
        };
        if first == '`' || first == '"' {
            let quote = first;
            self.pos += 1;
            let mut name = String::new();
            loop {
                let Some(ch) = self.peek() else {
                    return Err(err("列名引号未闭合"));
                };
                self.pos += 1;
                if ch == quote {
                    if self.peek() == Some(quote) {
                        name.push(quote);
                        self.pos += 1;
                        continue;
                    }
                    break;
                }
                name.push(ch);
            }
            if name.is_empty() {
                return Err(err("列名不能为空"));
            }
            return Ok(name);
        }
        if first.is_alphabetic() || first == '_' {
            let mut name = String::new();
            while let Some(ch) = self.peek() {
                if ch.is_alphanumeric() || ch == '_' || ch == '$' {
                    name.push(ch);
                    self.pos += 1;
                } else {
                    break;
                }
            }
            return Ok(name);
        }
        Err(err("条件必须以列名开头"))
    }

    fn read_word(&mut self) -> AppResult<String> {
        self.skip_ws();
        let mut word = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_ascii_alphabetic() {
                word.push(ch);
                self.pos += 1;
            } else {
                break;
            }
        }
        if word.is_empty() {
            return Err(err("缺少比较运算符"));
        }
        Ok(word)
    }

    fn match_word(&mut self, word: &str) -> bool {
        self.skip_ws();
        let len = word.chars().count();
        if self.pos + len > self.chars.len() {
            return false;
        }
        let candidate: String = self.chars[self.pos..self.pos + len].iter().collect();
        if !candidate.eq_ignore_ascii_case(word) {
            return false;
        }
        // Reject a partial identifier match such as "ANDROID" for "AND".
        if let Some(next) = self.peek_at(len) {
            if next.is_alphanumeric() || next == '_' {
                return false;
            }
        }
        self.pos += len;
        true
    }

    fn try_symbol_operator(&mut self) -> Option<String> {
        self.skip_ws();
        for op in ["!=", "<>", ">=", "<=", "=", ">", "<"] {
            let len = op.len();
            if self.pos + len <= self.chars.len() {
                let candidate: String = self.chars[self.pos..self.pos + len].iter().collect();
                if candidate == op {
                    self.pos += len;
                    return Some(op.to_string());
                }
            }
        }
        None
    }

    fn read_literal(&mut self) -> AppResult<String> {
        self.skip_ws();
        match self.peek() {
            Some('\'') => self.read_string_literal(),
            Some(ch) if ch.is_ascii_digit() || ch == '-' || ch == '+' || ch == '.' => {
                self.read_number()
            }
            Some(_) => {
                if self.match_word("NULL") {
                    Ok("NULL".to_string())
                } else {
                    Err(err("值只能是数字、字符串或 NULL"))
                }
            }
            None => Err(err("比较运算符之后缺少值")),
        }
    }

    fn read_number(&mut self) -> AppResult<String> {
        let mut text = String::new();
        while let Some(ch) = self.peek() {
            if ch.is_ascii_digit() || matches!(ch, '.' | '+' | '-' | 'e' | 'E') {
                text.push(ch);
                self.pos += 1;
            } else {
                break;
            }
        }
        if !text.chars().any(|c| c.is_ascii_digit()) || text.parse::<f64>().is_err() {
            return Err(err(format!("无效的数字 '{}'", text)));
        }
        Ok(text)
    }

    fn read_string_literal(&mut self) -> AppResult<String> {
        self.pos += 1; // opening quote
        let mut value = String::new();
        loop {
            let Some(ch) = self.peek() else {
                return Err(err("字符串未闭合"));
            };
            self.pos += 1;
            if ch == '\'' {
                if self.peek() == Some('\'') {
                    value.push('\'');
                    self.pos += 1;
                    continue;
                }
                break;
            }
            if ch == '\\' && self.driver.is_mysql() {
                // Decode once, then re-quote for the dialect. Preserving the
                // escape prefix would turn \' into an escaped closing quote.
                let Some(next) = self.peek() else {
                    return Err(err("字符串未闭合"));
                };
                self.pos += 1;
                match next {
                    '0' => value.push('\0'),
                    'b' => value.push('\u{0008}'),
                    'n' => value.push('\n'),
                    'r' => value.push('\r'),
                    't' => value.push('\t'),
                    'Z' => value.push('\u{001a}'),
                    '%' | '_' => { value.push('\\'); value.push(next); }
                    _ => value.push(next),
                }
                continue;
            }
            value.push(ch);
        }
        // MySQL also needs backslashes escaped at the output boundary.
        Ok(quote_str_for(self.driver, &value))
    }

    fn read_in_list(&mut self) -> AppResult<String> {
        self.skip_ws();
        if self.peek() != Some('(') {
            return Err(err("IN 之后需要括号列表"));
        }
        self.pos += 1;
        let mut items = Vec::new();
        loop {
            items.push(self.read_literal()?);
            self.skip_ws();
            match self.peek() {
                Some(',') => {
                    self.pos += 1;
                }
                Some(')') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(err("IN 列表格式错误")),
            }
        }
        if items.is_empty() {
            return Err(err("IN 列表不能为空"));
        }
        Ok(items.join(", "))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cols() -> Vec<String> {
        vec!["id".to_string(), "name".to_string(), "salary".to_string()]
    }

    fn parse(raw: &str) -> AppResult<String> {
        parse_filter(raw, &cols(), DriverKind::Mysql)
    }

    #[test]
    fn accepts_simple_conditions() {
        assert_eq!(parse("`salary` > 10000").unwrap(), "`salary` > 10000");
        assert_eq!(parse("name = 'IT'").unwrap(), "`name` = 'IT'");
        assert_eq!(parse("`id` IS NULL").unwrap(), "`id` IS NULL");
        assert_eq!(parse("`id` IS NOT NULL").unwrap(), "`id` IS NOT NULL");
        assert_eq!(parse("`id` IN (1, 2, 3)").unwrap(), "`id` IN (1, 2, 3)");
        assert_eq!(
            parse("`salary` > 1 AND name LIKE '%a%'").unwrap(),
            "`salary` > 1 AND `name` LIKE '%a%'"
        );
    }

    #[test]
    fn rejects_injection_attempts() {
        assert!(parse("1=1 OR 1=1").is_err());
        assert!(parse("`id` = 1; DROP TABLE users").is_err());
        assert!(parse("`id` = 1 -- comment").is_err());
        assert!(parse("`id` = (SELECT 1)").is_err());
        assert!(parse("`unknown_col` = 1").is_err());
        assert!(parse("`id` = 1 UNION SELECT password FROM users").is_err());
        assert!(parse("`id` /* x */ = 1").is_err());
        assert!(parse("SLEEP(5)").is_err());
    }

    #[test]
    fn mysql_backslash_escape_is_decoded_before_requoting() {
        assert_eq!(parse(r"name = 'x\' OR 1=1 -- '").unwrap(),
            "`name` = 'x'' OR 1=1 -- '");
    }

    #[test]
    fn escapes_string_values() {
        assert_eq!(parse("name = 'O''Brien'").unwrap(), "`name` = 'O''Brien'");
    }
}
