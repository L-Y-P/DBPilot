/// Page math shared by the query-history and backup tables.
///
/// Both pages used to build one row (and one set of action buttons) per stored
/// record on every rebuild; with hundreds of backups or thousands of history
/// entries that was what made them stutter. They now show one page at a time
/// through the same table/pager widgets as the data browser.
int pageCountFor(int total, int pageSize) {
  if (pageSize <= 0) return 1;
  final pages = (total + pageSize - 1) ~/ pageSize;
  return pages < 1 ? 1 : pages;
}

/// Clamp a 1-based page number into [1, pageCountFor(total, pageSize)].
int clampPage(int page, int total, int pageSize) {
  final pages = pageCountFor(total, pageSize);
  if (page < 1) return 1;
  if (page > pages) return pages;
  return page;
}

/// Slice one page out of [items]. The returned list is never longer than
/// [pageSize] and is empty only when [items] is empty.
List<T> pageSlice<T>(List<T> items, int page, int pageSize) {
  final current = clampPage(page, items.length, pageSize);
  final start = (current - 1) * pageSize;
  if (start >= items.length) return <T>[];
  final end = start + pageSize > items.length ? items.length : start + pageSize;
  return items.sublist(start, end);
}
