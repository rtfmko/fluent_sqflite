// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// A utility mixin for database-related string transformations.
///
/// This mixin provides helper functions to standardize data before it hits
/// the SQLite engine, such as converting CamelCase property names to
/// snake_case column names.
mixin FluentUtils {
  /// Converts a CamelCase or PascalCase string to snake_case.
  ///
  /// **Logic:**
  /// * Iterates through the input string character by character.
  /// * Inserts an underscore before any uppercase letter (if not at the start).
  /// * Converts all characters to lowercase.
  /// * Ensures no double underscores are created if the input already contains them.
  ///
  /// Example: `toSnakeCase('userName')` returns `'user_name'`.
  static String toSnakeCase(String input) {
    if (input.isEmpty) return '';

    final StringBuffer result = StringBuffer();

    for (int i = 0; i < input.length; i++) {
      final String char = input[i];

      if (char == char.toUpperCase() && i != 0) {
        if (input[i - 1] != '_') {
          result.write('_');
        }
        result.write(char.toLowerCase());
      } else {
        result.write(char.toLowerCase());
      }
    }

    return result.toString();
  }
}
