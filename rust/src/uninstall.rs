//! 用户数据目录的盘点与清空（与卸载/重置流程共用）。
//!
//! 背景：安装包卸载时只会删掉程序本身，用户目录（connections.json 里的
//! 数据库密码、查询历史、备份）原样留在磁盘上，用户既看不见也删不掉。
//! 这里提供两块纯逻辑：
//!
//! * [`data_dir_overview`] —— 盘点：每个顶层子项的大小/文件数，以及哪些
//!   敏感文件还在，供「数据与卸载」面板展示占用；
//! * [`wipe_data_dir`] —— 清空：**必须先过确认短语**才动手，删完保留目录
//!   本身（重新 prepared），这样 Idempotency（重复点清空）与「删完目录不存在
//!   导致下次启动报错」都不会发生。
//!
//! 这个模块刻意不碰 `api::state()`：卸载流程要在全局状态还没初始化（或已经
//! 归档）时就能算体积，否则用户在最需要这个面板的时候反而打不开。也正因为
//! 它拿到的是裸 `&Path`，所有破坏性操作前面都挂了护栏（见 [`guard_target`]）。

use std::path::{Path, PathBuf};

/// 顶层子项的类别。`Copy` + 小写字符串由 [`DataKind::as_str`] 给出，JSON 里
/// 只出现 `"file"` / `"dir"`，Dart 不需要映射枚举。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DataKind {
    File,
    Dir,
}

impl DataKind {
    pub fn as_str(self) -> &'static str {
        match self {
            DataKind::File => "file",
            DataKind::Dir => "dir",
        }
    }
}

/// 数据目录下的一个顶层子项。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DataEntry {
    /// 文件名（不含路径），面板上直接显示。
    pub name: String,
    /// 绝对（或调用方给的原始）路径。
    pub path: String,
    pub kind: DataKind,
    /// 文件本身或其子树的总字节数。读失败按 0 计（见 [`measure`]）。
    pub bytes: u64,
    /// 文件数：普通文件 1，目录为其下所有普通文件数。
    pub count: u64,
}

/// 数据目录的总览。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Overview {
    pub path: String,
    pub exists: bool,
    pub total_bytes: u64,
    pub file_count: u64,
    pub entries: Vec<DataEntry>,
    /// 仍存在的敏感文件（绝对路径），按 [`SENSITIVE_FILES`] 的顺序。
    ///
    /// 之所以在总览里单独列出来而不是让 Dart 自己拼路径：卸载确认框要能说
    /// 出「将删除 N 个包含密码/历史的文件」，这句话的数据来源必须只有一处。
    pub secret_files: Vec<String>,
}

/// 会被卸载流程当作「敏感」提示的文件（相对数据目录）。
///
/// 只用于**提示**，不参与删除范围：清空是整目录级别的，列表在这里是为了
/// 让确认框能具体说清楚删的到底是什么，而不是让用户想象。
pub const SENSITIVE_FILES: [&str; 4] = [
    "connections.json",
    "settings.json",
    "query_history.json",
    "query_metrics.jsonl",
];

/// 清空用户数据时要输入的确认短语（大小写不敏感）。
///
/// 不用 `true`/`false` 这样的布尔参数：FRB 那侧一个误传的默认值就能把整个
/// 用户目录删掉，而字符串短语不可能被"顺手"传对。
pub const DELETE_TOKEN: &str = "DELETE-ALL";

/// 目录被视为"用户数据目录"所需的最小深度。
///
/// 深度按 [`path_depth`] 计：`/Users/me/Library/...` 深 5，
/// `/tmp/x` 深 2，`/tmp` 与 `/` 都 < 2。留 2 是给测试与临时安装目录
/// (`/tmp/<id>`) 用的下限，再浅就必然是用户自己挑错路径了。
const MIN_DEPTH: usize = 2;

/// 拒绝不安全的目标：空路径、盘符/根目录、深度不足。
///
/// 返回 `Ok(())` 表示可以动手。错误文案直接给用户看（清空失败的一次性
/// 提示），所以写成中文整句而不是枚举。
pub fn guard_target(dir: &Path) -> Result<(), String> {
    let raw = dir.to_string_lossy();
    let text = raw.trim();
    if text.is_empty() {
        return Err("数据目录为空，无法执行清空".to_string());
    }
    // 根目录：Unix `/`、Windows 盘符根 `C:` / `C:/`、UNC `//server/share`
    // 都不是用户数据目录，删它们等于删系统。
    if text == "/" || text == "//" {
        return Err(format!("拒绝清空根目录：{text}"));
    }
    if is_drive_root(text) {
        return Err(format!("拒绝清空盘符根目录：{text}"));
    }
    let depth = path_depth(dir);
    if depth < MIN_DEPTH {
        return Err(format!(
            "拒绝清空过浅的目录（深度 {depth} < {MIN_DEPTH}）：{text}"
        ));
    }
    // 目录本身如果是个符号链接，`remove_dir_all` 语义在各平台不一致（有的删
    // 链接、有的追进目标），而追进目标可能删到链接指向的真实家目录。
    if let Ok(meta) = std::fs::symlink_metadata(dir) {
        if meta.file_type().is_symlink() {
            return Err(format!("数据目录是符号链接，拒绝清空：{text}"));
        }
        if !meta.is_dir() {
            return Err(format!("数据目录不是目录：{text}"));
        }
    }
    Ok(())
}

/// `C:` / `C:/` 这类只有盘符的根。
fn is_drive_root(text: &str) -> bool {
    let bytes = text.as_bytes();
    if bytes.len() < 2 || !bytes[0].is_ascii_alphabetic() || bytes[1] != b':' {
        return false;
    }
    matches!(&text[2..], "" | "\\" | "/")
}

/// 路径深度：只数真正的组件（`/`、`.` 不算）。中文注释里不写反斜杠字面量，
/// 避免文档注释里的 `\` 被误读成转义。
fn path_depth(dir: &Path) -> usize {
    dir.components()
        .filter(|part| matches!(part, std::path::Component::Normal(_)))
        .count()
}

/// 确认短语校验：忽略首尾空白与大小写，必须与期望值**完整相等**。
///
/// 不做 `contains`：`"DELETE-ALL-FOR-REAL"` 这种"看起来更狠"的输入如果被
/// 接受，就会让「误触删除」重新变得可能——用户手滑打进的是它周围的字。
fn confirm_ok(confirm: &str, expected: &str) -> bool {
    if expected.trim().is_empty() {
        // 调用方没给期望值（配置丢失/旧版本）：宁可删不掉也不能无条件放行。
        return false;
    }
    confirm.trim().eq_ignore_ascii_case(expected.trim())
}

/// 递归求和/计数。符号链接一律跳过。
///
/// 为什么跳过而不是解析：数据目录里出现符号链接只有两种可能——用户手动做的
/// 整理，或者一个指向别处的恶意构造。前者按链接目标算体积会让总占用看起来
/// 莫名其妙，后者会让"清空"顺着链接删到目录外（`remove_dir_all` 遇到链接
/// 也是删链接本身，两侧行为保持一致才不会出现「报表 1GB、实际删 0」）。
fn measure(path: &Path) -> (u64, u64) {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(_) => return (0, 0), // 读失败容忍：权限/文件被占用都只影响数字
    };
    let file_type = meta.file_type();
    if file_type.is_symlink() {
        return (0, 0);
    }
    if file_type.is_file() {
        return (meta.len(), 1);
    }
    if !file_type.is_dir() {
        return (0, 0);
    }
    let read = match std::fs::read_dir(path) {
        Ok(read) => read,
        Err(_) => return (0, 0),
    };
    let mut bytes = 0u64;
    let mut count = 0u64;
    for child in read {
        // 单项失败（权限、竞态删除）不影响其它项。
        let Ok(child) = child else { continue };
        let (part_bytes, part_count) = measure(&child.path());
        bytes = bytes.saturating_add(part_bytes);
        count = count.saturating_add(part_count);
    }
    (bytes, count)
}

/// 盘点数据目录的顶层子项。目录不存在返回空列表（调用方看 `exists` 分支）。
pub fn scan_data_dir(dir: &Path) -> Vec<DataEntry> {
    let read = match std::fs::read_dir(dir) {
        Ok(read) => read,
        Err(_) => return Vec::new(),
    };
    let mut entries = Vec::new();
    for child in read {
        let Ok(child) = child else { continue };
        let path = child.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        let file_type = meta.file_type();
        // 符号链接既不算文件也不算目录：它不占空间、也不会被清空动作删掉目标，
        // 列出来只会让用户以为"还有东西没删干净"。
        if file_type.is_symlink() {
            continue;
        }
        let kind = if file_type.is_dir() {
            DataKind::Dir
        } else if file_type.is_file() {
            DataKind::File
        } else {
            continue;
        };
        let (bytes, count) = measure(&path);
        entries.push(DataEntry {
            name: child.file_name().to_string_lossy().to_string(),
            path: path.to_string_lossy().to_string(),
            kind,
            bytes,
            count,
        });
    }
    // 按体积降序：面板第一屏应当是真正占地方的那几项。
    entries.sort_by(|a, b| b.bytes.cmp(&a.bytes).then_with(|| a.name.cmp(&b.name)));
    entries
}

/// 数据目录总览。`exists=false` 且不含任何数字时也返回 `Ok`——"还没存过东西"
/// 与"存过东西"在管理面板里应当是同一套结构，只差文案。
pub fn data_dir_overview(dir: &Path) -> Overview {
    let exists = dir.is_dir();
    let entries = if exists { scan_data_dir(dir) } else { Vec::new() };
    // 总数从子项求和而不是再遍历一次：两次遍历之间文件可能变，导致
    // "总大小 != 各子项之和"这种自相矛盾的展示。
    let total_bytes = entries.iter().map(|e| e.bytes).sum();
    let file_count = entries.iter().map(|e| e.count).sum();
    let secret_files = if exists {
        SENSITIVE_FILES
            .iter()
            .map(|name| dir.join(name))
            .filter(|path| path.is_file())
            .map(|path| path.to_string_lossy().to_string())
            .collect()
    } else {
        Vec::new()
    };
    Overview {
        path: dir.to_string_lossy().to_string(),
        exists,
        total_bytes,
        file_count,
        entries,
        secret_files,
    }
}

/// 清空前算出会释放多少字节，用于成功后回报 `removed_bytes`。
///
/// 单独成函数是因为删除之后的目录只剩空壳，届时已无法再统计。
pub fn data_dir_bytes(dir: &Path) -> u64 {
    if !dir.is_dir() {
        return 0;
    }
    data_dir_overview(dir).total_bytes
}

/// 清空数据目录的全部内容，保留（并重建）目录本身。
///
/// 语义：
/// * `confirm` 要与 `expected_token` 完整相等（大小写不敏感）；
/// * 目标不存在 → `Ok`（幂等：第二次点"清空"不是错误）；
/// * 删除顺序是逐个子项，单子项失败只记录、继续删其它项，最后汇总成一条错误，
///   这样"部分成功"能如实告诉用户还剩什么，而不是停在第一个失败项上；
/// * 目录本身不删，重新 `create_dir_all` 一次，保证下次启动 `prepare()` 不报错。
///
/// 失败返回 `Err(String)` 而不是 anyhow：本模块不依赖 api 层，调用方负责
/// 把字符串包成 `AppError`。
pub fn wipe_data_dir(dir: &Path, confirm: &str, expected_token: &str) -> Result<(), String> {
    guard_target(dir)?;
    if !confirm_ok(confirm, expected_token) {
        return Err(format!(
            "确认短语不匹配，已取消清空（需要输入 `{expected_token}`）"
        ));
    }
    // `guard_target` 已经确认不是链接/不是普通文件，这里再取一次元数据：
    // 目标是可能在上一步之后才被创建的（例如首次启动刚 prepare 出来）。
    if !dir.exists() {
        return Ok(());
    }
    let mut failures: Vec<String> = Vec::new();
    match std::fs::read_dir(dir) {
        Ok(read) => {
            for child in read {
                let child = match child {
                    Ok(child) => child,
                    Err(e) => {
                        failures.push(format!("读取目录项失败: {e}"));
                        continue;
                    }
                };
                let path = child.path();
                let result = match std::fs::symlink_metadata(&path) {
                    Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() => {
                        std::fs::remove_dir_all(&path)
                    }
                    Ok(_) => {
                        // 文件，或指向目录的链接：只删链接本身，绝不追进去。
                        std::fs::remove_file(&path)
                    }
                    // 已经不存在：并发删除/竞态，视为成功。
                    Err(_) if !path.exists() => Ok(()),
                    Err(e) => Err(e),
                };
                if let Err(e) = result {
                    if path.exists() {
                        failures.push(format!("{}: {e}", path.to_string_lossy()));
                    }
                }
            }
        }
        Err(e) => failures.push(format!("无法读取数据目录: {e}")),
    }
    // 保留目录本身；即使部分子项没删掉也重建（目录本来就大概率还在）。
    std::fs::create_dir_all(dir).map_err(|e| format!("无法重建数据目录: {e}"))?;
    if failures.is_empty() {
        Ok(())
    } else {
        // 只报前几项：确认框后面是一行提示，不是日志窗口。
        let shown = failures.iter().take(3).cloned().collect::<Vec<_>>().join("；");
        let more = if failures.len() > 3 {
            format!("（共 {} 项未删除）", failures.len())
        } else {
            String::new()
        };
        Err(format!("部分数据未能删除：{shown}{more}"))
    }
}

/// 总览转成 Dart 侧直接可用的 JSON（字段名即「数据与卸载」面板的契约）。
///
/// 序列化放在这里而不是 api 层，是因为安装包卸载脚本与面板读的是同一份字段；
/// 两处各写一遍 json! 迟早会漂移。
/// * `files[].kind` 为 `"file"` / `"dir"`；
/// * `contains_secrets` 等于"仍有敏感文件存在"；
/// * `secret_files` 给出具体是哪些（确认框文案要用）。
pub fn overview_json(dir: &Path) -> serde_json::Value {
    let overview = data_dir_overview(dir);
    serde_json::json!({
        "path": overview.path,
        "exists": overview.exists,
        "total_bytes": overview.total_bytes,
        "file_count": overview.file_count,
        "contains_secrets": !overview.secret_files.is_empty(),
        "secret_files": overview.secret_files,
        "files": overview
            .entries
            .iter()
            .map(|entry| serde_json::json!({
                "name": entry.name,
                "path": entry.path,
                "bytes": entry.bytes,
                "count": entry.count,
                "kind": entry.kind.as_str(),
            }))
            .collect::<Vec<_>>(),
    })
}

/// 数据目录路径（统一成 `PathBuf`，方便 api 层从 `config.data_dir` 直接传）。
pub fn data_dir_path(dir: &Path) -> PathBuf {
    dir.to_path_buf()
}
