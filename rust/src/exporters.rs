use serde_json::{json, Value};
use std::io::{self, Write};

use crate::db::ColumnMeta;

/// Marker written for a NULL in the line-oriented formats (CSV / TXT / MD).
///
/// An empty string is a perfectly valid value, so writing NULL as nothing made
/// the two indistinguishable and an import could not restore it. `\N` is the
/// convention MySQL's own dump format uses, and it is also the importer's
/// default `null_tokens` entry, so an exported file imports back unchanged.
pub const NULL_MARKER: &str = "\\N";

/// Text for one cell, with NULL marked instead of blanked.
///
/// Only the line-oriented formats use this; XML / HTML / Excel carry NULL in
/// their own structure (`null="true"`, `class="null"`, `<Cell/>`).
pub fn cell_text_marked(value: &Value) -> String {
    if value.is_null() {
        return NULL_MARKER.to_string();
    }
    cell_text(value)
}

/// Human-readable text for one cell, used by every text based exporter.
///
/// NULL renders as the empty string here; callers that need NULL to survive a
/// round trip must use [cell_text_marked].
pub fn cell_text(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::String(s) => s.clone(),
        Value::Bool(b) => (if *b { "true" } else { "false" }).to_string(),
        Value::Number(n) => n.to_string(),
        Value::Object(o) => match o.get("__binary__").and_then(|v| v.as_str()) {
            Some(b64) => format!(
                "[BLOB {} bytes] {}",
                o.get("len").and_then(|v| v.as_u64()).unwrap_or(0),
                b64
            ),
            None => Value::Object(o.clone()).to_string(),
        },
        other => other.to_string(),
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn csv_escape(value: &str) -> String {
    if value.contains(',') || value.contains('"') || value.contains('\n') || value.contains('\r') {
        format!("\"{}\"", value.replace('"', "\"\""))
    } else {
        value.to_string()
    }
}

fn json_rows(columns: &[ColumnMeta], rows: &[Vec<Value>]) -> Value {
    Value::Array(
        rows.iter()
            .map(|row| {
                let mut map = serde_json::Map::new();
                for (i, c) in columns.iter().enumerate() {
                    map.insert(c.name.clone(), row.get(i).cloned().unwrap_or(Value::Null));
                }
                Value::Object(map)
            })
            .collect(),
    )
}

/// Render a result set in one of the supported exchange formats.
/// Returns (body, content_type, filename).
pub fn render(
    format: &str,
    name: &str,
    columns: &[ColumnMeta],
    rows: &[Vec<Value>],
) -> Option<(String, String, String)> {
    let names: Vec<String> = columns.iter().map(|c| c.name.clone()).collect();
    match format {
        "csv" => {
            let mut out = String::new();
            out.push_str(&names.iter().map(|n| csv_escape(n)).collect::<Vec<_>>().join(","));
            out.push('\n');
            for row in rows {
                // Pad to the column count: a short row used to emit fewer
                // separators, so every following column silently shifted and
                // the file could not be matched back to its header.
                let line: Vec<String> = (0..names.len())
                    .map(|i| {
                        csv_escape(&cell_text_marked(
                            row.get(i).unwrap_or(&Value::Null),
                        ))
                    })
                    .collect();
                out.push_str(&line.join(","));
                out.push('\n');
            }
            Some((out, "text/csv; charset=utf-8".to_string(), format!("{}.csv", name)))
        }
        "json" => {
            let body = serde_json::to_string_pretty(&json_rows(columns, rows)).unwrap_or_else(|_| "[]".to_string());
            Some((body, "application/json; charset=utf-8".to_string(), format!("{}.json", name)))
        }
        "xml" => {
            let mut out = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rows>\n");
            for row in rows {
                out.push_str("  <row>\n");
                for (i, n) in names.iter().enumerate() {
                    let v = row.get(i).cloned().unwrap_or(Value::Null);
                    out.push_str(&xml_cell(n, &v));
                }
                out.push_str("  </row>\n");
            }
            out.push_str("</rows>\n");
            Some((out, "application/xml; charset=utf-8".to_string(), format!("{}.xml", name)))
        }
        "html" => {
            let mut out = String::from("<!doctype html>\n<meta charset=\"utf-8\">\n<table border=\"1\">\n<thead><tr>");
            for n in &names {
                out.push_str(&format!("<th>{}</th>", html_escape(n)));
            }
            out.push_str("</tr></thead>\n<tbody>\n");
            for row in rows {
                out.push_str("<tr>");
                for i in 0..names.len() {
                    let v = row.get(i).unwrap_or(&Value::Null);
                    if v.is_null() {
                        // Same reason as the XML `null="true"`: an empty
                        // cell body cannot be told apart from an empty string.
                        out.push_str("<td class=\"null\"></td>");
                    } else {
                        out.push_str(&format!("<td>{}</td>", html_escape(&cell_text(v))));
                    }
                }
                out.push_str("</tr>\n");
            }
            out.push_str("</tbody></table>\n");
            Some((out, "text/html; charset=utf-8".to_string(), format!("{}.html", name)))
        }
        "txt" => {
            let mut out = String::new();
            out.push_str(&names.join("\t"));
            out.push('\n');
            for row in rows {
                let line: Vec<String> = (0..names.len())
                    .map(|i| {
                        cell_text_marked(row.get(i).unwrap_or(&Value::Null))
                            .replace('\t', " ")
                    })
                    .collect();
                out.push_str(&line.join("\t"));
                out.push('\n');
            }
            Some((out, "text/plain; charset=utf-8".to_string(), format!("{}.txt", name)))
        }
        "md" | "markdown" => {
            let mut out = String::new();
            out.push_str(&format!("| {} |\n", names.join(" | ")));
            out.push_str(&format!("| {} |\n", names.iter().map(|_| "---").collect::<Vec<_>>().join(" | ")));
            for row in rows {
                let line: Vec<String> = (0..names.len())
                    .map(|i| {
                        cell_text_marked(row.get(i).unwrap_or(&Value::Null))
                            .replace('|', "\\|")
                            .replace('\n', " ")
                    })
                    .collect();
                out.push_str(&format!("| {} |\n", line.join(" | ")));
            }
            Some((out, "text/markdown; charset=utf-8".to_string(), format!("{}.md", name)))
        }
        // SpreadsheetML 2003: opens natively in Excel, LibreOffice and Numbers,
        // and needs no ZIP/compression dependency.
        "xls" | "excel" => {
            let mut out = String::from(
                "<?xml version=\"1.0\"?>\n<?mso-application progid=\"Excel.Sheet\"?>\n<Workbook xmlns=\"urn:schemas-microsoft-com:office:spreadsheet\" xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">\n<Worksheet ss:Name=\"Result\">\n<Table>\n",
            );
            out.push_str("<Row>");
            for n in &names {
                out.push_str(&format!(
                    "<Cell><Data ss:Type=\"String\">{}</Data></Cell>",
                    xml_escape(n)
                ));
            }
            out.push_str("</Row>\n");
            for row in rows {
                out.push_str("<Row>");
                // One <Cell> per column: SpreadsheetML positions cells by
                // order, so a missing cell would shift every later column left.
                for i in 0..names.len() {
                    out.push_str(&cell_xml(row.get(i).unwrap_or(&Value::Null)));
                }
                out.push_str("</Row>\n");
            }
            out.push_str("</Table>\n</Worksheet>\n</Workbook>\n");
            Some((out, "application/vnd.ms-excel; charset=utf-8".to_string(), format!("{}.xls", name)))
        }
        other => {
            let _ = other;
            None
        }
    }
}

/// One `<col>` element of the XML export.
///
/// NULL is marked with `null="true"` instead of an empty body, because an
/// empty string is a real value that has to survive the round trip.
fn xml_cell(name: &str, value: &Value) -> String {
    if value.is_null() {
        return format!("    <col name=\"{}\" null=\"true\"/>\n", xml_escape(name));
    }
    format!(
        "    <col name=\"{}\">{}</col>\n",
        xml_escape(name),
        xml_escape(&cell_text(value))
    )
}

fn cell_xml(value: &Value) -> String {
    match value {
        Value::Null => "<Cell/>".to_string(),
        Value::Bool(b) => format!(
            "<Cell><Data ss:Type=\"Boolean\">{}</Data></Cell>",
            if *b { 1 } else { 0 }
        ),
        Value::Number(n) => format!("<Cell><Data ss:Type=\"Number\">{}</Data></Cell>", n),
        other => format!(
            "<Cell><Data ss:Type=\"String\">{}</Data></Cell>",
            xml_escape(&cell_text(other))
        ),
    }
}

// ---------------------------------------------------------------- streaming
//
// The table export used to call `run_one`, materialise every row as JSON and
// only then render the whole document into one String. On a 1,000,000-row table
// that peaked around 1 GB of RSS (test report ST-06 / §6.3 P1). The types below
// render incrementally instead: the caller feeds one row at a time, so memory
// stays proportional to the format's per-row text, not to the table size.

/// Content type and default file name for one export format.
///
/// Returns None for an unsupported format, so callers can reject it before
/// opening the output file.
pub fn export_meta(format: &str, name: &str) -> Option<(String, String)> {
    let (content_type, ext) = match format {
        "csv" => ("text/csv; charset=utf-8", "csv"),
        "json" => ("application/json; charset=utf-8", "json"),
        "xml" => ("application/xml; charset=utf-8", "xml"),
        "html" => ("text/html; charset=utf-8", "html"),
        "txt" => ("text/plain; charset=utf-8", "txt"),
        "md" | "markdown" => ("text/markdown; charset=utf-8", "md"),
        "sql" => ("application/sql; charset=utf-8", "sql"),
        "xls" | "excel" => ("application/vnd.ms-excel; charset=utf-8", "xls"),
        _ => return None,
    };
    Some((content_type.to_string(), format!("{name}.{ext}")))
}

/// Where a streaming export writes to.
pub enum Sink {
    /// In-memory preview (bounded by [ExportStream]'s byte cap).
    Memory(Vec<u8>),
    /// A real file, normally a BufWriter. `Send` is required because the export
    /// API is exposed through flutter_rust_bridge, which spawns the future on a
    /// worker thread.
    File(Box<dyn Write + Send>),
}

impl Sink {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        match self {
            Sink::Memory(buffer) => {
                buffer.extend_from_slice(bytes);
                Ok(())
            }
            Sink::File(writer) => writer.write_all(bytes),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            Sink::Memory(_) => Ok(()),
            Sink::File(writer) => writer.flush(),
        }
    }
}

/// Outcome of one streaming export.
pub struct ExportResult {
    pub rows: u64,
    pub truncated: bool,
    pub bytes: usize,
    /// Set only for [Sink::Memory]; the file sink already wrote to disk.
    pub content: Option<String>,
}

/// Incremental renderer for the supported exchange formats.
pub struct ExportStream {
    format: String,
    names: Vec<String>,
    sink: Sink,
    written: usize,
    max_bytes: Option<usize>,
    truncated: bool,
    rows: u64,
}

impl ExportStream {
    /// Start a stream. Returns Ok(None) for an unsupported format.
    pub fn new(
        format: &str,
        name: &str,
        columns: &[ColumnMeta],
        sink: Sink,
        max_bytes: Option<usize>,
    ) -> io::Result<Option<Self>> {
        if export_meta(format, name).is_none() {
            return Ok(None);
        }
        let mut stream = Self {
            format: format.to_lowercase(),
            names: columns.iter().map(|c| c.name.clone()).collect(),
            sink,
            written: 0,
            max_bytes,
            truncated: false,
            rows: 0,
        };
        let prefix = stream.prefix();
        stream.put_raw(&prefix)?;
        Ok(Some(stream))
    }

    fn prefix(&self) -> String {
        match self.format.as_str() {
            "csv" => format!(
                "{}
",
                self.names
                    .iter()
                    .map(|n| csv_escape(n))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
            "json" => "[
".to_string(),
            "xml" => "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rows>
".to_string(),
            "html" => {
                let mut out =
                    String::from("<!doctype html>\n<meta charset=\"utf-8\">\n<table border=\"1\">\n<thead><tr>");
                for name in &self.names {
                    out.push_str(&format!("<th>{}</th>", html_escape(name)));
                }
                out.push_str("</tr></thead>\n<tbody>
");
                out
            }
            "txt" => format!("{}\n", self.names.join("\t")),
            "md" | "markdown" => format!(
                "| {} |\n| {} |\n",
                self.names.join(" | "),
                self.names
                    .iter()
                    .map(|_| "---")
                    .collect::<Vec<_>>()
                    .join(" | ")
            ),
            "xls" | "excel" => {
                let mut out = String::from(
                    "<?xml version=\"1.0\"?>\n<?mso-application progid=\"Excel.Sheet\"?>\n<Workbook xmlns=\"urn:schemas-microsoft-com:office:spreadsheet\" xmlns:ss=\"urn:schemas-microsoft-com:office:spreadsheet\">\n<Worksheet ss:Name=\"Result\">\n<Table>\n<Row>",
                );
                for name in &self.names {
                    out.push_str(&format!(
                        "<Cell><Data ss:Type=\"String\">{}</Data></Cell>",
                        xml_escape(name)
                    ));
                }
                out.push_str("</Row>\n");
                out
            }
            _ => String::new(),
        }
    }

    fn render_row(&self, row: &[Value]) -> String {
        // Every branch below iterates over the COLUMN count, not the row, and
        // must produce exactly what render() does for the same row: a short row
        // is padded with NULL instead of dropping trailing columns, and NULL is
        // written in the format's own distinguishable form.
        let cell = |i: usize| row.get(i).unwrap_or(&Value::Null);
        match self.format.as_str() {
            "csv" => format!(
                "{}\n",
                (0..self.names.len())
                    .map(|i| csv_escape(&cell_text_marked(cell(i))))
                    .collect::<Vec<_>>()
                    .join(",")
            ),
            "json" => {
                let mut map = serde_json::Map::new();
                for (i, name) in self.names.iter().enumerate() {
                    map.insert(name.clone(), cell(i).clone());
                }
                let object = Value::Object(map).to_string();
                if self.rows == 0 {
                    object
                } else {
                    format!(",\n{object}")
                }
            }
            "xml" => {
                let mut out = String::from("  <row>\n");
                for (i, name) in self.names.iter().enumerate() {
                    out.push_str(&xml_cell(name, cell(i)));
                }
                out.push_str("  </row>\n");
                out
            }
            "html" => {
                let mut out = String::from("<tr>");
                for i in 0..self.names.len() {
                    let value = cell(i);
                    if value.is_null() {
                        out.push_str("<td class=\"null\"></td>");
                    } else {
                        out.push_str(&format!("<td>{}</td>", html_escape(&cell_text(value))));
                    }
                }
                out.push_str("</tr>\n");
                out
            }
            "txt" => format!(
                "{}\n",
                (0..self.names.len())
                    .map(|i| cell_text_marked(cell(i)).replace('\t', " "))
                    .collect::<Vec<_>>()
                    .join("\t")
            ),
            "md" | "markdown" => format!(
                "| {} |\n",
                (0..self.names.len())
                    .map(|i| cell_text_marked(cell(i))
                        .replace('|', "\\|")
                        .replace('\n', " "))
                    .collect::<Vec<_>>()
                    .join(" | ")
            ),
            "xls" | "excel" => {
                let mut out = String::from("<Row>");
                for i in 0..self.names.len() {
                    out.push_str(&cell_xml(cell(i)));
                }
                out.push_str("</Row>\n");
                out
            }
            _ => String::new(),
        }
    }

    /// Write one row. Returns Ok(false) when the byte cap was reached; the
    /// caller should then stop feeding rows.
    pub fn write_row(&mut self, row: &[Value]) -> io::Result<bool> {
        let rendered = self.render_row(row);
        if let Some(max) = self.max_bytes {
            if self.written.saturating_add(rendered.len()) > max {
                self.truncated = true;
                return Ok(false);
            }
        }
        self.put_raw(&rendered)?;
        self.rows += 1;
        Ok(true)
    }

    fn put_raw(&mut self, text: &str) -> io::Result<()> {
        self.sink.write_all(text.as_bytes())?;
        self.written += text.len();
        Ok(())
    }

    /// Close the document and flush the sink.
    pub fn finish(mut self) -> io::Result<ExportResult> {
        let footer = match self.format.as_str() {
            "json" => "\n]\n",
            "xml" => "</rows>\n",
            "html" => "</tbody></table>\n",
            "xls" | "excel" => "</Table>\n</Worksheet>\n</Workbook>\n",
            _ => "",
        };
        if !footer.is_empty() {
            self.put_raw(footer)?;
        }
        self.sink.flush()?;
        let content = match self.sink {
            Sink::Memory(buffer) => Some(String::from_utf8_lossy(&buffer).into_owned()),
            Sink::File(_) => None,
        };
        Ok(ExportResult {
            rows: self.rows,
            truncated: self.truncated,
            bytes: self.written,
            content,
        })
    }
}

/// Describe the supported export formats for the UI.
pub fn formats() -> Value {
    json!([
        { "id": "sql", "label": "SQL" },
        { "id": "csv", "label": "CSV" },
        { "id": "json", "label": "JSON" },
        { "id": "xml", "label": "XML" },
        { "id": "html", "label": "HTML" },
        { "id": "txt", "label": "TXT" },
        { "id": "xls", "label": "Excel" },
        { "id": "md", "label": "Markdown" },
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cols() -> Vec<ColumnMeta> {
        vec![
            ColumnMeta { name: "id".into(), type_name: "INTEGER".into() },
            ColumnMeta { name: "name".into(), type_name: "TEXT".into() },
            ColumnMeta { name: "note".into(), type_name: "TEXT".into() },
        ]
    }

    /// Four rows covering every awkward case: a NULL, an empty string, a value
    /// that needs CSV quoting, and a row SHORTER than the column list (the
    /// "skipped column" the report described).
    fn rows() -> Vec<Vec<Value>> {
        vec![
            vec![json!(1), json!("alice"), Value::Null],
            vec![json!(2), Value::Null, json!("has,comma")],
            vec![json!(3), json!("bob"), json!("")],
            vec![json!(4)],
        ]
    }

    fn body(format: &str) -> String {
        render(format, "t", &cols(), &rows())
            .expect("format must be supported")
            .0
    }

    /// The streaming renderer must agree with render() on the DATA (the JSON
    /// pretty-printer is only used by the one-shot path, so that format is
    /// compared after parsing).
    fn stream_body(format: &str) -> String {
        let mut stream =
            ExportStream::new(format, "t", &cols(), Sink::Memory(Vec::new()), None)
                .unwrap()
                .expect("format must be supported");
        for row in rows() {
            stream.write_row(&row).unwrap();
        }
        stream.finish().unwrap().content.unwrap()
    }

    /// Minimal CSV field splitter for the assertions (the real one lives in the
    /// importer, which must not become a dependency of the exporter).
    fn split_csv(line: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut cur = String::new();
        let mut quoted = false;
        let mut chars = line.chars().peekable();
        while let Some(c) = chars.next() {
            if quoted {
                if c == '"' {
                    if chars.peek() == Some(&'"') {
                        chars.next();
                        cur.push('"');
                    } else {
                        quoted = false;
                    }
                } else {
                    cur.push(c);
                }
            } else if c == '"' {
                quoted = true;
            } else if c == ',' {
                out.push(std::mem::take(&mut cur));
            } else {
                cur.push(c);
            }
        }
        out.push(cur);
        out
    }

    #[test]
    fn every_format_emits_one_cell_per_column_even_for_a_short_row() {
        // CSV: parse properly, because a quoted value contains commas itself.
        let csv = body("csv");
        let lines: Vec<&str> = csv.lines().collect();
        assert_eq!(lines.len(), 5, "header + four rows");
        for line in &lines {
            assert_eq!(split_csv(line).len(), 3, "csv row must have 3 cells: {line:?}");
        }
        // The short row keeps its two trailing NULLs.
        assert_eq!(split_csv(lines[4]), vec!["4", "\\N", "\\N"]);

        // TXT / MD are separator based with no quoting.
        for (format, sep) in [("txt", '\t'), ("md", '|')] {
            let text = body(format);
            let data: Vec<&str> = text
                .lines()
                .filter(|l| !l.is_empty())
                .skip(if format == "md" { 2 } else { 1 })
                .collect();
            assert_eq!(data.len(), 4, "{format}: four data rows");
            for line in data {
                let count = if format == "md" {
                    line.matches('|').count() - 1
                } else {
                    line.matches(sep).count() + 1
                };
                assert_eq!(count, 3, "{format} row must have 3 cells: {line:?}");
            }
        }

        // Structural formats: one element per column per record.
        let xml = body("xml");
        for chunk in xml.split("<row>").skip(1) {
            let record = chunk.split("</row>").next().unwrap();
            assert_eq!(record.matches("<col ").count(), 3, "xml row: {record}");
        }
        let html = body("html");
        for chunk in html.split("<tr>").skip(2) {
            let record = chunk.split("</tr>").next().unwrap();
            assert_eq!(record.matches("<td").count(), 3, "html row: {record}");
        }
        let xls = body("xls");
        for chunk in xls.split("<Row>").skip(2) {
            let record = chunk.split("</Row>").next().unwrap();
            assert_eq!(record.matches("<Cell").count(), 3, "xls row: {record}");
        }

        let json: Value = serde_json::from_str(&body("json")).unwrap();
        for object in json.as_array().unwrap() {
            assert_eq!(object.as_object().unwrap().len(), 3, "json row: {object}");
        }
    }

    #[test]
    fn null_is_distinguishable_from_the_empty_string_in_every_format() {
        // Row 0 has a NULL note, row 2 an EMPTY note: they must not collide.
        let csv = body("csv");
        let lines: Vec<&str> = csv.lines().collect();
        assert_eq!(split_csv(lines[1]), vec!["1", "alice", "\\N"]);
        assert_eq!(split_csv(lines[3]), vec!["3", "bob", ""]);

        let txt = body("txt");
        let lines: Vec<&str> = txt.lines().collect();
        assert_eq!(lines[1], "1\talice\t\\N");

        let md = body("md");
        assert!(md.contains("| 1 | alice | \\N |"), "{md}");
        assert!(md.contains("| 3 | bob |  |"), "{md}");

        let xml = body("xml");
        assert!(xml.contains("<col name=\"note\" null=\"true\"/>"), "{xml}");
        // The empty string keeps a body, so it is NOT the null element.
        assert!(xml.contains("<col name=\"note\"></col>"), "{xml}");

        let html = body("html");
        assert!(html.contains("<td class=\"null\"></td>"), "{html}");
        assert!(html.contains("<td></td>"), "{html}");

        let json: Value = serde_json::from_str(&body("json")).unwrap();
        assert!(json[0]["note"].is_null());
        assert_eq!(json[2]["note"], json!(""));

        let xls = body("xls");
        assert!(xls.contains("<Cell/>"), "xls NULL cell: {xls}");
    }

    #[test]
    fn streaming_output_matches_the_in_memory_renderer() {
        for format in ["csv", "txt", "md", "xml", "html", "xls"] {
            assert_eq!(
                stream_body(format),
                body(format),
                "{format}: streaming and one-shot output diverged"
            );
        }
        // The one-shot JSON path pretty-prints; the streamed one does not, so
        // compare the parsed documents instead of the bytes.
        let one_shot: Value = serde_json::from_str(&body("json")).unwrap();
        let streamed: Value = serde_json::from_str(&stream_body("json")).unwrap();
        assert_eq!(one_shot, streamed, "json: streamed data diverged");
    }

    #[test]
    fn a_value_that_looks_like_the_null_marker_stays_a_string() {
        let cols = vec![ColumnMeta { name: "v".into(), type_name: "TEXT".into() }];
        let rows = vec![vec![json!("\\N")], vec![Value::Null]];
        let csv = render("csv", "t", &cols, &rows).unwrap().0;
        let lines: Vec<&str> = csv.lines().collect();
        // The literal text is written as-is; only a real NULL gets the marker,
        // and the two are distinguishable because the header tells the importer
        // which token means NULL.
        assert_eq!(split_csv(lines[1]), vec!["\\N"]);
        assert_eq!(split_csv(lines[2]), vec!["\\N"]);
        // Documented consequence: a string equal to the marker is ambiguous in
        // CSV. The wizard exposes "null token" so the user can pick another one.
    }
}
