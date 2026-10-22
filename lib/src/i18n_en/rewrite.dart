/// One pattern-based rewrite for a prompt that interpolates a value.
///
/// Exact translations live in the per-area maps in this directory; anything
/// whose rendered form contains a value — a table name, a row count, a path —
/// has to be recognised by pattern instead.
class Rewrite {
  const Rewrite(this.pattern, this.build);

  /// Matched against the fully rendered Chinese string.
  final RegExp pattern;

  /// Builds the English string from the match.
  final String Function(Match) build;
}
