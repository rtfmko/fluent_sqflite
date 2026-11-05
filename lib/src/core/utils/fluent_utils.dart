// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'dart:async';

/// Name helpers of the library (default table names, relation column names).
mixin FluentUtils {
  /// Zone key: inside [withLegacyNames], [toSnakeCase] follows the 1.x rule.
  static final Object _legacyKey = Object();

  /// Runs [body] with [toSnakeCase] following the 1.x rule ([legacySnakeCase]): the relation graph is built once
  /// this way at start to find the names a 1.x database used.
  static R withLegacyNames<R>(R Function() body) => runZoned(body, zoneValues: {_legacyKey: true});

  static final RegExp _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);
  static final RegExp _digit = RegExp(r'\p{N}', unicode: true);

  /// Converts a camelCase or PascalCase name to snake_case: `toSnakeCase('userName')` returns `'user_name'`.
  ///
  /// A word starts at an upper-case letter after a lower-case letter or a digit (`userName` → `user_name`,
  /// `item2Box` → `item2_box`), and at the last upper-case letter of an acronym before a lower-case one
  /// (`HTTPServer` → `http_server`, `userID` → `user_id`). Digits stay with their word (`Item2` → `item2`). Characters
  /// that are not letters, digits or `_` separate words (`Box<Note>` → `box_note`, `Map<String, int>` →
  /// `map_string_int`); repeated or trailing separators collapse, a leading `_` is kept (`_Draft` → `_draft`).
  ///
  /// Names the 1.x rule ([legacySnakeCase]) wrote differently are adopted at start: the table or column is renamed.
  static String toSnakeCase(String input) {
    if (Zone.current[_legacyKey] == true) return legacySnakeCase(input);
    final StringBuffer out = StringBuffer();
    bool pendingSeparator = false;
    for (int i = 0; i < input.length; i++) {
      final String c = input[i];
      if (!_wordChar.hasMatch(c) || c == '_') {
        // A leading `_` (a private Dart name) is kept; any other separator becomes one `_` before the next word.
        if (c == '_' && out.isEmpty && !pendingSeparator) {
          out.write('_');
        } else if (out.isNotEmpty) {
          pendingSeparator = true;
        }
        continue;
      }
      final bool upper = _isUpper(c);
      if (upper && out.isNotEmpty && !pendingSeparator && i > 0) {
        final String prev = input[i - 1];
        final bool nextLower = i + 1 < input.length && _isLower(input[i + 1]);
        if (_isLower(prev) || _digit.hasMatch(prev) || (_isUpper(prev) && nextLower)) pendingSeparator = true;
      }
      if (pendingSeparator) {
        final String text = out.toString();
        if (!text.endsWith('_')) out.write('_');
        pendingSeparator = false;
      }
      out.write(c.toLowerCase());
    }
    return out.toString();
  }

  /// The 1.x rule of [toSnakeCase]: every character after the first that `toUpperCase` leaves unchanged (upper-case
  /// letters, digits, `<`, `>`) gets an `_` before it unless the previous character is `_`; then everything is
  /// lowercased (`Item2` → `item_2`, `HTTPServer` → `h_t_t_p_server`, `Box<Note>` → `box_<_note_>`). Only used to
  /// find tables and columns of databases written by 1.x, which are then renamed.
  static String legacySnakeCase(String input) {
    final StringBuffer result = StringBuffer();
    for (int i = 0; i < input.length; i++) {
      final String char = input[i];
      if (char == char.toUpperCase() && char != '_' && i != 0) {
        if (input[i - 1] != '_') result.write('_');
      }
      result.write(char.toLowerCase());
    }
    return result.toString();
  }

  static bool _isUpper(String c) => c != c.toLowerCase();

  static bool _isLower(String c) => c != c.toUpperCase();
}
