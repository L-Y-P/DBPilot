//! 表数据分页的纯 SQL 生成：keyset（索引范围扫描）+ 延迟关联（deferred join）。
//!
//! 这里只拼 SQL 文本，不执行、不读库：
//! * 标识符一律走 [`DatabaseDialect::quote_ident`]，字面量走
//!   [`DatabaseDialect::literal`]；调用方传入的过滤片段已经过
//!   `crate::filter::parse_filter` 重建，永不原样拼接；
//! * 因此分页形态（游标 / 延迟关联 / COUNT 开关）可以纯单测，
//!   `ops::data` 只负责取元数据、执行与组装响应。
//!
//! 两种优化：
//! * **keyset**：单列主键 + 无显式排序（或排序恰好是主键升序）时，游标可用；
//!   提供了 `after` 的页用 `WHERE <pk> > <literal> ORDER BY <pk> LIMIT n`
//!   替代 OFFSET，深翻页不再扫描并丢弃前 m 行。第一页没有游标，但仍然按主键
//!   升序返回——否则「最后一行的主键」不是本页最大值，下一页会漏行。
//! * **延迟关联**：有主键时先在子查询里只取主键（LIMIT/OFFSET 下推到索引），
//!   再 JOIN 回原表取整行，避免宽表 / 大字段随 OFFSET 一起被搬运。
//!
//! 回退规则：复合主键、无主键、排序与主键不一致时回退到普通
//! `SELECT * ... LIMIT n OFFSET m`（语义与优化前完全一致）。

use serde_json::Value;

use crate::dialect::DatabaseDialect;

/// 一页表数据的请求（`ops::data` 与驱动默认方法的入参）。
///
/// 用结构体而不是一长串位置参数：新增的 `after` / `count` / `deferred` 都是
/// 可选项，位置参数会让调用点变成一串看不懂的 `None, true, true`。
#[derive(Clone, Debug)]
pub struct DataPage<'a> {
    /// 1 起的页码；keyset 生效时被忽略（游标已定位起点）。
    pub page: u64,
    pub per_page: u64,
    /// 显式排序，形如 `[("name", "desc")]`。
    pub sorts: &'a [(String, String)],
    /// 已由 `filter::parse_filter` 重建的过滤条件（不含 `WHERE`）。
    pub filter: Option<&'a str>,
    /// 上一页最后一行的主键值；给了就走 keyset。
    pub after: Option<&'a Value>,
    /// 是否统计总行数（`false` 时 total / pages 返回 null）。
    pub count: bool,
    /// 是否用延迟关联（先取主键再回表）。
    pub deferred: bool,
}

impl Default for DataPage<'_> {
    fn default() -> Self {
        DataPage {
            page: 1,
            per_page: 25,
            sorts: &[],
            filter: None,
            after: None,
            count: true,
            deferred: true,
        }
    }
}

impl<'a> DataPage<'a> {
    pub fn new(page: u64, per_page: u64) -> DataPage<'a> {
        DataPage {
            page,
            per_page,
            ..DataPage::default()
        }
    }

    /// 页码与每页行数的规范化（与优化前的 clamp 完全一致）。
    pub fn normalized(&self) -> (u64, u64) {
        (self.page.max(1), self.per_page.clamp(1, 1000))
    }

    /// 从 0 起的偏移量（keyset 生效时实际使用 0）。
    pub fn offset(&self) -> u64 {
        let (page, per_page) = self.normalized();
        (page - 1) * per_page
    }
}

/// 一页数据的完整 SQL 计划。
#[derive(Clone, Debug, PartialEq)]
pub struct PagePlan {
    /// 主查询。
    pub sql: String,
    /// `SELECT COUNT(*)`；`count=false` 时为 None（跳过整表计数）。
    pub count_sql: Option<String>,
    /// 本页是否走了 keyset 游标。
    pub used_keyset: bool,
    /// 本页是否走了延迟关联。
    pub used_deferred: bool,
    /// 用于生成 `next_cursor` 的主键列；只有 keyset 生效时才有。
    pub cursor_column: Option<String>,
}

/// 单列主键（复合主键 / 无主键返回 None）。
pub fn single_primary_key(primary_key: &[String]) -> Option<&str> {
    match primary_key {
        [only] => {
            let name = only.trim();
            if name.is_empty() {
                None
            } else {
                Some(name)
            }
        }
        _ => None,
    }
}

/// keyset 是否可用：单列主键，且没有排序或排序恰好是「主键升序」。
pub fn keyset_eligible(primary_key: &[String], sorts: &[(String, String)]) -> bool {
    let Some(pk) = single_primary_key(primary_key) else {
        return false;
    };
    match sorts {
        [] => true,
        [(column, direction)] => column.trim() == pk && !direction.trim().eq_ignore_ascii_case("desc"),
        _ => false,
    }
}

/// keyset 条件：`<pk> > <literal>`（游标必须是标量，调用方负责校验）。
pub fn keyset_clause(dialect: &dyn DatabaseDialect, pk: &str, after: &Value) -> String {
    format!("{} > {}", dialect.quote_ident(pk), dialect.literal(after))
}

/// `ORDER BY` 子句。
///
/// `qualifier` 非空时给每列加表别名前缀：延迟关联的外层必须写 `t.pk`，
/// 否则 MySQL 会因为 t 与子查询 d 都有同名列而报 `Column 'pk' ... is ambiguous`。
pub fn order_clause(
    dialect: &dyn DatabaseDialect,
    sorts: &[(String, String)],
    qualifier: &str,
) -> String {
    let parts: Vec<String> = sorts
        .iter()
        .map(|(column, direction)| {
            let dir = if direction.trim().eq_ignore_ascii_case("desc") {
                "DESC"
            } else {
                "ASC"
            };
            format!(
                "{}{} {}",
                qualifier,
                dialect.quote_ident(column.trim()),
                dir
            )
        })
        .collect();
    if parts.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", parts.join(", "))
    }
}

/// 普通分页：`SELECT * FROM <target> [WHERE ..] [ORDER BY ..] LIMIT n OFFSET m`。
pub fn page_sql(
    target: &str,
    where_clause: &str,
    order: &str,
    limit: u64,
    offset: u64,
) -> String {
    format!(
        "SELECT * FROM {}{}{} LIMIT {} OFFSET {}",
        target, where_clause, order, limit, offset
    )
}

/// 延迟关联：
/// `SELECT t.* FROM <target> t JOIN (SELECT <pk..> FROM <target> [WHERE ..]
/// [ORDER BY ..] LIMIT n OFFSET m) d ON t.<pk> = d.<pk> [AND ..] [ORDER BY t.<col> ..]`。
///
/// MySQL / PostgreSQL / SQLite 都支持这种写法：子查询只读主键索引，回表只发生
/// 在本页命中的 n 行上。复合主键用 AND 连接全部主键列。
#[allow(clippy::too_many_arguments)]
pub fn deferred_sql(
    dialect: &dyn DatabaseDialect,
    target: &str,
    primary_key: &[String],
    where_clause: &str,
    sorts: &[(String, String)],
    limit: u64,
    offset: u64,
) -> String {
    let key_columns: Vec<String> = primary_key
        .iter()
        .map(|column| dialect.quote_ident(column.trim()))
        .collect();
    let join = key_columns
        .iter()
        .map(|column| format!("t.{column} = d.{column}"))
        .collect::<Vec<_>>()
        .join(" AND ");
    let inner_order = order_clause(dialect, sorts, "");
    let outer_order = order_clause(dialect, sorts, "t.");
    format!(
        "SELECT t.* FROM {target} t JOIN (SELECT {} FROM {target}{where_clause}{inner_order} LIMIT {limit} OFFSET {offset}) d ON {join}{outer_order}",
        key_columns.join(", ")
    )
}

/// 组装一页数据的 SQL 计划。
///
/// * `filter` 是已重建的过滤条件（不含 `WHERE`）；COUNT 只用它，不含游标；
/// * `after` 是上一页最后一行的主键值，只有 keyset 生效时才进 WHERE；
/// * `count=false` 时不生成 COUNT(*)，调用方据此返回 total/pages = null。
#[allow(clippy::too_many_arguments)]
pub fn page_plan(
    dialect: &dyn DatabaseDialect,
    target: &str,
    primary_key: &[String],
    sorts: &[(String, String)],
    filter: Option<&str>,
    per_page: u64,
    offset: u64,
    after: Option<&Value>,
    count: bool,
    deferred: bool,
) -> PagePlan {
    let pk = single_primary_key(primary_key).map(str::to_string);
    // 「能当游标用」与「这一页真的用了游标」是两件事：第一页没有游标，
    // 但仍然按主键升序返回，客户端才能把最后一行的主键当作下一页的 after。
    let cursor_eligible = keyset_eligible(primary_key, sorts);
    let used_keyset = after.is_some() && cursor_eligible;

    let filter_where = match filter.map(str::trim).filter(|s| !s.is_empty()) {
        Some(condition) => format!(" WHERE {}", condition),
        None => String::new(),
    };

    // keyset：游标替换 OFFSET；没有显式排序时按主键升序（索引范围扫描）。
    let mut conditions: Vec<String> = Vec::new();
    if let Some(condition) = filter.map(str::trim).filter(|s| !s.is_empty()) {
        conditions.push(condition.to_string());
    }
    if used_keyset {
        let pk = pk.as_deref().expect("keyset requires a single-column primary key");
        let after = after.expect("keyset requires a cursor");
        conditions.push(keyset_clause(dialect, pk, after));
    }
    let where_clause = if conditions.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", conditions.join(" AND "))
    };

    // 单列主键 + 无显式排序时**始终**按主键升序：游标是「最后一行的主键」，
    // 只有本页按主键升序，下一页的 > after 才是正确边界。第一页没有游标也
    // 必须排序，否则 next_cursor 取到的不是本页最大值，翻页会漏行/重行。
    let effective_sorts: Vec<(String, String)> = if cursor_eligible && sorts.is_empty() {
        vec![(
            pk.clone().expect("cursor eligibility requires a pk"),
            "asc".to_string(),
        )]
    } else {
        sorts.to_vec()
    };

    // 游标已经定位到起点，OFFSET 必须归零，否则会跳过整整一页。
    let (limit, offset) = if used_keyset {
        (per_page, 0)
    } else {
        (per_page, offset)
    };

    // 延迟关联只需要「有主键」（复合主键用 AND 连接），与 keyset 的单列要求不同。
    let has_primary_key = !primary_key.is_empty()
        && primary_key.iter().all(|column| !column.trim().is_empty());
    let used_deferred = deferred && has_primary_key;
    let sql = if used_deferred {
        deferred_sql(
            dialect,
            target,
            primary_key,
            &where_clause,
            &effective_sorts,
            limit,
            offset,
        )
    } else {
        page_sql(
            target,
            &where_clause,
            &order_clause(dialect, &effective_sorts, ""),
            limit,
            offset,
        )
    };

    PagePlan {
        sql,
        count_sql: if count {
            Some(format!("SELECT COUNT(*) FROM {}{}", target, filter_where))
        } else {
            None
        },
        used_keyset,
        used_deferred,
        // 只要这一页的形态允许游标，就给出 cursor_column：第一页没有 after，
        // 但客户端要拿最后一行的主键去请求第二页。
        cursor_column: if cursor_eligible { pk } else { None },
    }
}

/// 从结果集里取出游标值（最后一行的主键列）。
///
/// 列名匹配大小写不敏感（MySQL 会按列定义原样返回，PostgreSQL 会把未加引号
/// 的标识符折叠成小写）。找不到列或没有行时返回 None —— 调用方据此把
/// `next_cursor` 置为 null，而不是编一个空游标。
pub fn next_cursor(
    columns: &[crate::db::ColumnMeta],
    rows: &[Vec<Value>],
    cursor_column: &str,
) -> Option<Value> {
    let index = columns
        .iter()
        .position(|column| column.name.eq_ignore_ascii_case(cursor_column))?;
    rows.last()
        .and_then(|row| row.get(index))
        .filter(|value| !value.is_null())
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dialect::{DialectCapability, SqlQuery};

    /// 测试用方言：反引号引用 + 标准字符串字面量（与 MySQL 的引用形态一致，
    /// 但不需要真的连库）。
    #[derive(Debug)]
    struct TestDialect;

    impl DatabaseDialect for TestDialect {
        fn driver_id(&self) -> &'static str {
            "test"
        }

        fn quote_ident(&self, name: &str) -> String {
            format!("`{}`", name.replace('`', "``"))
        }

        fn quote_string(&self, value: &str) -> String {
            format!("'{}'", value.replace('\'', "''"))
        }

        fn list_databases_sql(&self) -> SqlQuery {
            SqlQuery::new("SELECT 1")
        }

        fn list_schemas_sql(&self) -> SqlQuery {
            SqlQuery::new("SELECT 1")
        }

        fn list_tables_sql(&self, _namespace: &str) -> SqlQuery {
            SqlQuery::new("SELECT 1")
        }

        fn list_columns_sql(&self, _namespace: &str, _table: &str) -> SqlQuery {
            SqlQuery::new("SELECT 1")
        }

        fn table_kind_sql(&self, _namespace: &str, _table: &str) -> SqlQuery {
            SqlQuery::new("SELECT 1")
        }

        fn supports(&self, _capability: DialectCapability) -> bool {
            false
        }
    }

    const TARGET: &str = "`db`.`people`";

    fn pk(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| name.to_string()).collect()
    }

    fn sorts(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(column, direction)| (column.to_string(), direction.to_string()))
            .collect()
    }

    #[test]
    fn keyset_sql_uses_a_range_scan_instead_of_offset() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["id"]),
            &[],
            Some("`salary` > 100"),
            25,
            500,
            Some(&Value::from(42)),
            true,
            false,
        );
        assert!(plan.used_keyset, "单列主键 + 无排序 + 游标必须走 keyset");
        assert!(!plan.used_deferred);
        assert_eq!(
            plan.sql,
            "SELECT * FROM `db`.`people` WHERE `salary` > 100 AND `id` > 42 ORDER BY `id` ASC LIMIT 25 OFFSET 0",
            "keyset 必须用 WHERE 范围扫描并把 OFFSET 归零"
        );
        assert_eq!(plan.cursor_column.as_deref(), Some("id"));
        // COUNT 只看过滤条件，不能把游标算进去，否则 total 会随翻页变小。
        assert_eq!(
            plan.count_sql.as_deref(),
            Some("SELECT COUNT(*) FROM `db`.`people` WHERE `salary` > 100")
        );
    }

    #[test]
    fn keyset_accepts_a_sort_that_is_already_the_primary_key_ascending() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["id"]),
            &sorts(&[("id", "asc")]),
            None,
            10,
            0,
            Some(&Value::from(7)),
            false,
            false,
        );
        assert!(plan.used_keyset);
        assert_eq!(
            plan.sql,
            "SELECT * FROM `db`.`people` WHERE `id` > 7 ORDER BY `id` ASC LIMIT 10 OFFSET 0"
        );
        assert_eq!(plan.count_sql, None, "count=false 必须跳过 COUNT(*)");
    }

    #[test]
    fn keyset_is_ignored_when_the_sort_is_not_the_primary_key() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["id"]),
            &sorts(&[("name", "desc")]),
            None,
            10,
            20,
            Some(&Value::from(7)),
            true,
            false,
        );
        assert!(!plan.used_keyset, "按其它列排序时游标无法定位，必须回退");
        assert_eq!(
            plan.sql,
            "SELECT * FROM `db`.`people` ORDER BY `name` DESC LIMIT 10 OFFSET 20"
        );
        assert_eq!(plan.cursor_column, None);
    }

    #[test]
    fn composite_primary_key_falls_back_to_offset_paging() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["tenant", "id"]),
            &[],
            None,
            10,
            30,
            Some(&Value::from(9)),
            true,
            true,
        );
        assert!(!plan.used_keyset, "复合主键无法用单列游标");
        // 延迟关联仍然可用：JOIN 条件用 AND 连接全部主键列。
        assert!(plan.used_deferred, "复合主键也应能用延迟关联");
        assert_eq!(
            plan.sql,
            "SELECT t.* FROM `db`.`people` t JOIN (SELECT `tenant`, `id` FROM `db`.`people` LIMIT 10 OFFSET 30) d ON t.`tenant` = d.`tenant` AND t.`id` = d.`id`"
        );
        assert_eq!(plan.cursor_column, None);

        // deferred=false 时复合主键表仍然回退到普通 SELECT。
        let plain = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["tenant", "id"]),
            &[],
            None,
            10,
            30,
            Some(&Value::from(9)),
            true,
            false,
        );
        assert!(!plain.used_deferred);
        assert_eq!(plain.sql, "SELECT * FROM `db`.`people` LIMIT 10 OFFSET 30");
    }

    #[test]
    fn table_without_a_primary_key_keeps_plain_paging() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &[],
            &sorts(&[("name", "asc")]),
            Some("`id` IS NOT NULL"),
            10,
            0,
            Some(&Value::from(1)),
            true,
            true,
        );
        assert!(!plan.used_keyset);
        assert!(!plan.used_deferred, "无主键必须回退普通 SELECT");
        assert_eq!(
            plan.sql,
            "SELECT * FROM `db`.`people` WHERE `id` IS NOT NULL ORDER BY `name` ASC LIMIT 10 OFFSET 0"
        );
        assert!(plan.count_sql.is_some());
    }

    #[test]
    fn deferred_join_selects_keys_first_then_joins_back() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["id"]),
            &sorts(&[("name", "desc")]),
            Some("`age` >= 18"),
            50,
            100,
            None,
            true,
            true,
        );
        assert!(plan.used_deferred);
        assert!(!plan.used_keyset, "没有游标就不走 keyset");
        assert_eq!(
            plan.sql,
            "SELECT t.* FROM `db`.`people` t JOIN (SELECT `id` FROM `db`.`people` WHERE `age` >= 18 ORDER BY `name` DESC LIMIT 50 OFFSET 100) d ON t.`id` = d.`id` ORDER BY t.`name` DESC",
            "外层 ORDER BY 必须带 t. 前缀，否则 MySQL 报 ambiguous"
        );
    }

    #[test]
    fn deferred_join_with_a_cursor_has_no_offset_and_is_pk_ordered() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["id"]),
            &[],
            None,
            20,
            400,
            Some(&Value::from(1000)),
            true,
            true,
        );
        assert!(plan.used_keyset && plan.used_deferred);
        assert_eq!(
            plan.sql,
            "SELECT t.* FROM `db`.`people` t JOIN (SELECT `id` FROM `db`.`people` WHERE `id` > 1000 ORDER BY `id` ASC LIMIT 20 OFFSET 0) d ON t.`id` = d.`id` ORDER BY t.`id` ASC"
        );
    }

    #[test]
    fn deferred_can_be_switched_off_for_a_table_with_a_primary_key() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["id"]),
            &sorts(&[("id", "asc")]),
            None,
            25,
            50,
            None,
            true,
            false,
        );
        assert!(!plan.used_deferred, "deferred=false 必须回退普通 SELECT");
        assert_eq!(
            plan.sql,
            "SELECT * FROM `db`.`people` ORDER BY `id` ASC LIMIT 25 OFFSET 50"
        );
    }

    #[test]
    fn first_page_still_reports_the_cursor_column_so_the_client_can_continue() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["id"]),
            &[],
            None,
            10,
            0,
            None,
            true,
            false,
        );
        assert!(!plan.used_keyset, "第一页没有游标，不能声称用了 keyset");
        assert_eq!(
            plan.cursor_column.as_deref(),
            Some("id"),
            "第一页也必须给出游标列，客户端才能请求第二页"
        );
        // 第一页没有游标，但单列主键的表必须按主键升序：否则「最后一行的主键」
        // 不是本页最大值，下一页的 > after 会漏行。
        assert_eq!(
            plan.sql,
            "SELECT * FROM `db`.`people` ORDER BY `id` ASC LIMIT 10 OFFSET 0"
        );
    }

    #[test]
    fn next_cursor_reads_the_last_rows_key() {
        use crate::db::ColumnMeta;
        let columns = vec![
            ColumnMeta {
                name: "name".to_string(),
                type_name: "TEXT".to_string(),
            },
            ColumnMeta {
                name: "ID".to_string(),
                type_name: "INT".to_string(),
            },
        ];
        let rows = vec![
            vec![Value::from("Ada"), Value::from(1)],
            vec![Value::from("Bob"), Value::from(2)],
        ];
        // 列名大小写不敏感：MySQL/PG 返回的列名大小写不一定与元数据一致。
        assert_eq!(
            next_cursor(&columns, &rows, "id"),
            Some(Value::from(2)),
            "游标必须取最后一行的主键值"
        );
        assert_eq!(next_cursor(&columns, &rows, "missing"), None);
        assert_eq!(next_cursor(&columns, &[], "id"), None);
        let null_rows = vec![vec![Value::from("Cy"), Value::Null]];
        assert_eq!(
            next_cursor(&columns, &null_rows, "id"),
            None,
            "NULL 主键不能当游标"
        );
    }

    #[test]
    fn string_cursors_are_quoted_as_literals() {
        let plan = page_plan(
            &TestDialect,
            TARGET,
            &pk(&["code"]),
            &[],
            None,
            10,
            0,
            Some(&Value::from("O'Brien")),
            true,
            false,
        );
        assert!(plan.used_keyset);
        assert!(
            plan.sql.contains("WHERE `code` > 'O''Brien'"),
            "字符串游标必须按方言重新引用：{}",
            plan.sql
        );
    }
}
