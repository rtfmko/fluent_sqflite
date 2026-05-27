// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../utils/utils.dart';

/// Defines the structural and serialization configuration for a [FluentProvider].
///
/// This configuration object governs how data is transformed between the Dart
/// domain model and the physical SQLite database layer. It allows for per-table
/// fine-tuning of storage formats, ensuring consistency across the persistence layer
class FluentTableConfig {
  /// Whether to automatically sanitize and type-cast database values upon retrieval.
  ///
  /// When true, the provider uses system metadata to attempt to restore precise
  /// types (e.g., converting stored integers to booleans) during hydration.
  final bool sanitizeTypes;

  /// The storage strategy for [DateTime] properties within this table.
  ///
  /// This configuration dictates whether date values are serialized as standard
  /// ISO 8601 strings or numeric epoch timestamps, allowing developers to
  /// prioritize either human-readability or high-performance range filtering
  /// depending on the specific model requirements.
  final FluentDateTimeFormat dateTimeFormat;

  /// Policy for persisting Dart [Enum] values.
  ///
  /// If `true`, enums are stored as their String names (human-readable, schema-stable).
  /// If `false`, enums are stored as their integer index (compact, but vulnerable to order changes).
  final bool storeEnumsAsNames;

  /// Creates an immutable [FluentTableConfig] instance with optional overrides.
  ///
  /// This constructor provides the default configuration profile for table
  /// interactions, balancing performance and data integrity.
  const FluentTableConfig({this.sanitizeTypes = true, this.dateTimeFormat = FluentDateTimeFormat.timestamp, this.storeEnumsAsNames = true});

  /// Returns a new [FluentTableConfig] instance with the specified properties updated.
  ///
  /// This implementation of the "copy-with" pattern is essential for
  /// immutability, allowing you to derive customized configurations from the
  /// base default instance without mutating global settings.
  FluentTableConfig copyWith({bool? sanitizeTypes, FluentDateTimeFormat? dateTimeFormat, bool? storeEnumsAsNames}) =>
      FluentTableConfig(sanitizeTypes: sanitizeTypes ?? this.sanitizeTypes, dateTimeFormat: dateTimeFormat ?? this.dateTimeFormat, storeEnumsAsNames: storeEnumsAsNames ?? this.storeEnumsAsNames);
}
