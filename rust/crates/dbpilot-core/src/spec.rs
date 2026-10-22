//! DDL 请求 DTO：建表 / 改表 / 外键。
//!
//! 33 轮拆 crate 时从 drivers/mod.rs 搬进契约层：DatabaseDialect 的
//! create_table_sql / alter_table_statements 需要这些类型，而 core 不能
//! 反向依赖 drivers。drivers 模块仍 re-export 旧路径
//! （`crate::drivers::CreateTableSpec` 等），既有调用点不需要改。

use serde::Deserialize;

use crate::config::DriverKind;
use crate::error::{AppError, AppResult};
use crate::sql::qi;

#[derive(Clone, Debug, Deserialize)]
pub struct ColumnDef {
    pub name: String,
    #[serde(rename = "type")]
    pub col_type: String,
    #[serde(default = "default_true")]
    pub nullable: bool,
    #[serde(default)]
    pub default: Option<String>,
    #[serde(default)]
    pub auto_increment: bool,
    #[serde(default)]
    pub primary: bool,
    #[serde(default)]
    pub comment: Option<String>,
    /// Column level character set (MySQL) — empty means "inherit from table".
    #[serde(default)]
    pub charset: Option<String>,
    #[serde(default)]
    pub collation: Option<String>,
}

fn default_true() -> bool {
    true
}

#[derive(Clone, Debug, Deserialize)]
pub struct CreateTableSpec {
    pub name: String,
    pub columns: Vec<ColumnDef>,
    #[serde(default)]
    pub engine: Option<String>,
    #[serde(default)]
    pub charset: Option<String>,
    #[serde(default)]
    pub collation: Option<String>,
    #[serde(default)]
    pub row_format: Option<String>,
    #[serde(default)]
    pub auto_increment: Option<u64>,
    #[serde(default)]
    pub comment: Option<String>,
    /// PostgreSQL: create the table as UNLOGGED.
    #[serde(default)]
    pub unlogged: Option<bool>,
    /// PostgreSQL: TABLESPACE name.
    #[serde(default)]
    pub tablespace: Option<String>,
    /// SQLite: WITHOUT ROWID table.
    #[serde(default)]
    pub without_rowid: Option<bool>,
    /// SQLite: STRICT table.
    #[serde(default)]
    pub strict: Option<bool>,
    /// Foreign keys created together with the table.
    #[serde(default)]
    pub foreign_keys: Vec<ForeignKeyDef>,
}

/// One column change in the visual table designer.
#[derive(Clone, Debug, Deserialize)]
pub struct AlterColumn {
    pub name: String,
    #[serde(rename = "type", default)]
    pub col_type: String,
    #[serde(default = "default_true")]
    pub nullable: bool,
    #[serde(default)]
    pub default: Option<String>,
    #[serde(default)]
    pub auto_increment: bool,
    #[serde(default)]
    pub comment: Option<String>,
    #[serde(default)]
    pub charset: Option<String>,
    #[serde(default)]
    pub collation: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct AlterIndex {
    pub name: String,
    #[serde(default)]
    pub unique: bool,
    #[serde(default)]
    pub columns: Vec<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RenameColumn {
    pub from: String,
    pub to: String,
}

/// A foreign key set up through the graphical designer.
#[derive(Clone, Debug, Deserialize)]
pub struct ForeignKeyDef {
    /// Constraint name; generated from the table/columns when left empty.
    #[serde(default)]
    pub name: Option<String>,
    /// Local column(s) — the GUI uses one, but composite keys are accepted.
    pub columns: Vec<String>,
    /// Referenced table (same namespace).
    pub ref_table: String,
    /// Referenced column(s), aligned with ; empty means the referenced primary key.
    #[serde(default)]
    pub ref_columns: Vec<String>,
    /// ON DELETE / ON UPDATE actions: CASCADE, SET NULL, RESTRICT, NO ACTION, SET DEFAULT.
    #[serde(default)]
    pub on_delete: Option<String>,
    #[serde(default)]
    pub on_update: Option<String>,
}

/// Whitelist for referential actions; they are interpolated straight into DDL.
fn fk_action(value: Option<&str>) -> AppResult<Option<&'static str>> {
    let raw = match value.map(str::trim).filter(|s| !s.is_empty()) {
        Some(v) => v,
        None => return Ok(None),
    };
    match raw.to_ascii_uppercase().as_str() {
        "CASCADE" => Ok(Some("CASCADE")),
        "SET NULL" => Ok(Some("SET NULL")),
        "SET DEFAULT" => Ok(Some("SET DEFAULT")),
        "RESTRICT" => Ok(Some("RESTRICT")),
        "NO ACTION" => Ok(Some("NO ACTION")),
        other => Err(AppError::bad(format!("不支持的引用动作 '{other}'"))),
    }
}

/// Validated pieces of a foreign key, shared by the per-driver DDL builders.
pub struct FkParts {
    pub name: String,
    pub columns: Vec<String>,
    pub ref_table: String,
    pub ref_columns: Vec<String>,
    /// Pre-rendered " ON DELETE x ON UPDATE y".
    pub actions: String,
}

pub fn fk_parts(fk: &ForeignKeyDef) -> AppResult<FkParts> {
    if fk.columns.is_empty() {
        return Err(AppError::bad("外键需要至少一个本表字段"));
    }
    if fk.ref_table.trim().is_empty() {
        return Err(AppError::bad("外键需要指定引用表"));
    }
    let columns: Vec<String> = fk.columns.iter().map(|c| c.trim().to_string()).collect();
    for c in &columns {
        if c.is_empty() {
            return Err(AppError::bad("外键字段不能为空"));
        }
    }
    let ref_columns: Vec<String> = fk.ref_columns.iter().map(|c| c.trim().to_string()).collect();
    if !ref_columns.is_empty() && ref_columns.len() != columns.len() {
        return Err(AppError::bad("外键字段与引用字段数量必须一致"));
    }
    let mut actions = String::new();
    if let Some(a) = fk_action(fk.on_delete.as_deref())? {
        actions.push_str(&format!(" ON DELETE {a}"));
    }
    if let Some(a) = fk_action(fk.on_update.as_deref())? {
        actions.push_str(&format!(" ON UPDATE {a}"));
    }
    Ok(FkParts {
        name: fk.name.as_deref().map(str::trim).unwrap_or("").to_string(),
        columns,
        ref_table: fk.ref_table.trim().to_string(),
        ref_columns,
        actions,
    })
}

/// "CONSTRAINT x FOREIGN KEY (a) REFERENCES t (b) ON DELETE ..." for one definition list entry.
/// The table name is only used to derive a constraint name when the user leaves it blank.
pub fn fk_constraint_sql(driver: DriverKind, table: &str, fk: &ForeignKeyDef) -> AppResult<String> {
    let p = fk_parts(fk)?;
    let name = if p.name.is_empty() { default_fk_name(table, &p.columns) } else { p.name };
    if !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(AppError::bad(format!("非法外键名 '{name}'")));
    }
    let cols: Vec<String> = p.columns.iter().map(|c| qi(driver, c)).collect();
    let ref_list = if p.ref_columns.is_empty() {
        String::new()
    } else {
        let quoted: Vec<String> = p.ref_columns.iter().map(|c| qi(driver, c)).collect();
        format!("{}", quoted.join(", "))
    };
    Ok(format!(
        "CONSTRAINT {} FOREIGN KEY ({}) REFERENCES {} ({}){}",
        qi(driver, &name),
        cols.join(", "),
        qi(driver, &p.ref_table),
        ref_list,
        p.actions
    ))
}

/// Default constraint name, used when the designer leaves the name blank.
pub fn default_fk_name(table: &str, columns: &[String]) -> String {
    let mut name = String::from("fk_");
    name.push_str(table.trim());
    for c in columns {
        name.push('_');
        name.push_str(c.trim());
    }
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '_' { c } else { '_' })
        .collect()
}


/// A batch of structure changes produced by the table designer.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct AlterTableSpec {
    #[serde(default)]
    pub rename_to: Option<String>,
    #[serde(default)]
    pub engine: Option<String>,
    #[serde(default)]
    pub charset: Option<String>,
    #[serde(default)]
    pub collation: Option<String>,
    #[serde(default)]
    pub comment: Option<String>,
    #[serde(default)]
    pub row_format: Option<String>,
    #[serde(default)]
    pub auto_increment: Option<u64>,
    #[serde(default)]
    pub unlogged: Option<bool>,
    #[serde(default)]
    pub tablespace: Option<String>,
    #[serde(default)]
    pub without_rowid: Option<bool>,
    #[serde(default)]
    pub strict: Option<bool>,
    #[serde(default)]
    pub add_columns: Vec<AlterColumn>,
    #[serde(default)]
    pub modify_columns: Vec<AlterColumn>,
    #[serde(default)]
    pub drop_columns: Vec<String>,
    #[serde(default)]
    pub rename_columns: Vec<RenameColumn>,
    #[serde(default)]
    pub add_indexes: Vec<AlterIndex>,
    #[serde(default)]
    pub drop_indexes: Vec<String>,
    #[serde(default)]
    pub set_primary_key: Option<Vec<String>>,
    /// Foreign keys to add.
    #[serde(default)]
    pub add_foreign_keys: Vec<ForeignKeyDef>,
    /// Names of foreign keys to drop.
    #[serde(default)]
    pub drop_foreign_keys: Vec<String>,
}

impl AlterTableSpec {
    pub fn is_empty(&self) -> bool {
        self.rename_to.as_deref().unwrap_or("").is_empty()
            && self.engine.as_deref().unwrap_or("").is_empty()
            && self.charset.as_deref().unwrap_or("").is_empty()
            && self.collation.as_deref().unwrap_or("").is_empty()
            && self.comment.is_none()
            && self.row_format.as_deref().unwrap_or("").is_empty()
            && self.auto_increment.is_none()
            && self.unlogged.is_none()
            && self.tablespace.as_deref().unwrap_or("").is_empty()
            && self.without_rowid.is_none()
            && self.strict.is_none()
            && self.add_columns.is_empty()
            && self.modify_columns.is_empty()
            && self.drop_columns.is_empty()
            && self.rename_columns.is_empty()
            && self.add_indexes.is_empty()
            && self.drop_indexes.is_empty()
            && self.set_primary_key.is_none()
            && self.add_foreign_keys.is_empty()
            && self.drop_foreign_keys.is_empty()
    }
}
