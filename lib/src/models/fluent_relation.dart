// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../core/core.dart';
import '../interfaces/interfaces.dart';
import '../utils/utils.dart';

/// Represents a relationship definition between database models.
///
/// [FluentDbRelation] acts as a bridge for complex schema operations like joins,
/// cross-table lookups, and cascading deletes. It supports both standard
/// relational mappings (1:1, 1:N, M:N) and polymorphic associations.
class FluentDbRelation<T extends FluentStorable> {
  Type _runtimeType;

  /// The runtime type of the target model for this relationship.
  Type get modelType => _runtimeType;

  /// The key in the parent object where the related data will be mapped.
  final String mapToKey;

  /// Custom selector to resolve the related entity from a parent context.
  final dynamic Function(FluentStorable parent)? entitySelector;

  /// The deserialization strategy used to map raw database rows into
  /// typed model instances or raw data collections.
  ///
  /// This determines whether the [FluentDbRelation] (or repository query) returns
  /// a single entity, a collection, or the raw underlying map representation.
  final FluentModelCast castType;

  /// The primary key column name on the remote (target) table.
  String? remoteKey;

  /// The foreign key column name on the local (source) table.
  String? localKey;

  /// The name of the target database table.
  String? targetTable;

  /// Whether the relation can point to multiple different types of tables.
  bool isPolymorphic;

  /// The column name that stores the type discriminator for polymorphic relations.
  String? polyTypeColumn;

  /// The mapping strategy and cardinality of this relationship.
  ///
  /// This property informs the query builder how to traverse tables,
  /// manage foreign key integrity, and whether to perform recursive
  /// loads for nested models.
  FluentDbRelationType relationType;

  /// The intermediate table name used for Many-to-Many relationships.
  String? pivotTable;

  /// Whether the relation should be automatically loaded during retrieval.
  final bool autoLoad;

  /// Whether deleting the parent should trigger the deletion of related children.
  final bool onDeleteCascade;

  /// Whether the relation should be loaded lazily on-demand.
  final bool isLazy;

  /// Internal state tracker for schema validation.
  bool _isValid = true;
  String? _validationError;

  /// Whether this relation is permitted to be null.
  final bool nullable;

  /// Creates a [FluentDbRelation] configuration defining how a model interacts with
  /// its related entities.
  ///
  /// This constructor maps an object property to a database schema relationship,
  /// providing the metadata required for JOIN operations, cascading deletions,
  /// and polymorphic data resolution.
  ///
  /// [mapToKey] The field name on the parent class used to store/access the relation.
  /// [entitySelector] A callback for custom logic to resolve the relationship from the parent instance.
  /// [castType] The strategy used to convert query results into types (e.g., [FluentModelCast.modelList]).
  /// [remoteKey] The foreign/primary key column name on the target table.
  /// [localKey] The column name on the current table acting as the foreign key.
  /// [targetTable] The name of the table to join or query.
  /// [relationType] Defines the cardinality (e.g., [FluentDbRelationType.manyToMany]).
  /// [isPolymorphic] Enables association with multiple potential model types using a discriminator column.
  /// [polyTypeColumn] The column name holding the type discriminator for polymorphic relations.
  /// [pivotTable] Required for [FluentDbRelationType.manyToMany] to define the association table.
  /// [autoLoad] Whether to eagerly resolve the relationship during the initial query.
  /// [onDeleteCascade] Whether to automatically remove related records when the parent is deleted.
  /// [isLazy] Determines if the relationship should be loaded only upon first access.
  /// [nullable] Whether the relationship can legitimately return null results.
  FluentDbRelation({
    required this.mapToKey,
    this.entitySelector,
    required this.castType,
    this.remoteKey,
    this.localKey,
    this.targetTable,
    this.relationType = FluentDbRelationType.auto,
    this.isPolymorphic = false,
    this.polyTypeColumn = 'parent_type',
    this.pivotTable,
    this.autoLoad = true,
    this.onDeleteCascade = true,
    this.isLazy = true,
    this.nullable = false,
  }) : _runtimeType = T;

  /// Returns `true` if the relationship configuration is valid and operational.
  ///
  /// An inactive relation indicates a schema mismatch or a failed initialization
  /// (e.g., missing pivot table or invalid foreign key), signaling the
  /// [FluentProvider] to ignore this relation during queries.
  bool get isActive => _isValid;

  /// The descriptive error message associated with this relation's validation failure.
  ///
  /// If the relation is [isActive] is false, this property contains the
  /// specific reason (e.g., missing pivot table, ambiguous foreign key)
  /// explaining why the relation was disabled during the schema validation phase.
  ///
  /// Returns `null` if the relation is valid or has not been validated.
  String? get validationError => _validationError;

  /// Deactivates this relationship and logs the specific reason for failure.
  ///
  /// This is used by the schema validator to "soft-disable" relations that
  /// cannot be resolved, preventing runtime crashes.
  ///
  /// [validError] A descriptive message explaining why the relation is invalid.
  void disable(String validError) {
    _isValid = false;
    _validationError = validError;

    FluentLog.warning('Relation disabled: $validError', tag: 'FluentDbRelation', context: {'error': validError});
  }

  /// Binds a concrete type to anonymous or generic relations at runtime.
  ///
  /// Many relations are defined as `DbStorable` or `dynamic` during model
  /// bootstrapping. This method performs the final type binding once the
  /// model has been registered in the [FluentDb].
  ///
  /// [type] The concrete class type to associate with this relation.
  void bindType(Type type) {
    final Type oldType = _runtimeType;

    if (_runtimeType == FluentStorable || _runtimeType == dynamic) {
      _runtimeType = type;

      FluentLog.debug('Fixed anonymous relation: $oldType -> $_runtimeType', tag: 'FluentDbRelation:bind', context: {'previousType': oldType.toString(), 'boundType': type.toString()});
    }
  }
}
