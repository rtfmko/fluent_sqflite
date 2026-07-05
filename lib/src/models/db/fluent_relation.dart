// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import '../../core/core.dart';
import '../../core/fluent_sqlite_internal.dart';
import '../../exceptions/exceptions.dart';
import '../../interfaces/interfaces.dart';
import '../../utils/utils.dart';

/// Represents a relationship definition between database models.
///
/// [FluentDbRelation] acts as a bridge for complex schema operations such as
/// cascading persistence, cross-table lookups, and relational integrity.
///
/// Type parameters:
/// * [P] - The parent model type (the owner of the relationship).
/// * [C] - The child/target model type (the related entity).
///
/// This bridge supports standard relational mappings (1:1, 1:N, M:N) and
/// polymorphic associations, ensuring type-safe access to child entities
/// through the [entitySelector].
class FluentDbRelation<P extends FluentStorable, C extends FluentStorable> {
  Type _runtimeType;

  /// The runtime type of the target model for this relationship.
  Type get modelType => _runtimeType;

  /// The key in the parent object where the related data will be mapped.
  final String mapToKey;

  /// Custom selector function used to resolve related entities from a parent instance.
  ///
  /// The selector is internally wrapped to ensure type safety while allowing
  /// the [FluentDbRelation] to be stored in non-generic collections.
  /// It maps the parent instance [P] to the corresponding related child entity or list of entities.
  final Object? Function(P parent) _internalSelector;

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

  /// Defines the synchronization strategy for relational associations when
  /// persisting the parent entity.
  final FluentRelationUpdateMode updateMode;

  /// Creates a [FluentDbRelation] configuration defining how a model [P] interacts with
  /// its related child entity [C].
  ///
  /// This constructor establishes a bridge between an object property and the database
  /// schema. It provides the metadata required for JOIN operations, cascading persistence,
  /// and relational integrity.
  ///
  /// [mapToKey] The field name in the parent JSON/Map used to store or access the relation.
  /// [entitySelector] A selector function that extracts the related entity (or list of entities)
  /// from a parent instance. This function is internally wrapped to ensure type safety
  /// while maintaining compatibility with the engine's non-generic storage.
  /// [castType] The strategy used to convert query results into the target type
  /// (e.g., [FluentModelCast.modelList]).
  /// [remoteKey] The foreign or primary key column name on the target table [C].
  /// [localKey] The column name on the current table [P] acting as the foreign key.
  /// [targetTable] The name of the table to join or query.
  /// [relationType] Defines the cardinality (e.g., [FluentDbRelationType.manyToMany]).
  /// [isPolymorphic] Enables association with multiple potential model types using a discriminator.
  /// [polyTypeColumn] The column name holding the type discriminator for polymorphic relations.
  /// [pivotTable] Required for [FluentDbRelationType.manyToMany] to define the association table.
  /// [autoLoad] Whether to eagerly resolve the relationship during the initial query.
  /// [onDeleteCascade] Whether to automatically remove related records when the parent is deleted.
  /// [isLazy] Determines if the relationship should be loaded only upon first access.
  /// [nullable] Whether the relationship can legitimately return null results.
  /// [updateMode] Defines the synchronization strategy for relational associations
  /// when persisting the parent entity, determining how the engine handles empty
  /// or null states.
  FluentDbRelation({
    required this.mapToKey,
    required Object? Function(P parent) entitySelector,
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
    this.updateMode = FluentRelationUpdateMode.skipOnNull,
  }) : _runtimeType = C,
       _internalSelector = ((parent) => entitySelector(parent));

  /// Resolves the related entity from the given [parent] instance.
  ///
  /// This method acts as a type-safe bridge for the database engine. It takes a
  /// generic [parent] instance (typically a [FluentStorable]), safely casts it to
  /// the expected parent type [P], and executes the [entitySelector] to retrieve
  /// the associated child entity or collection.
  ///
  /// Throws a [FluentRelationException] if the provided [parent] is not an
  /// instance of [P], providing clear diagnostic context.
  Object? select(Object parent) {
    if (parent is! P) {
      final FluentRelationException exception = FluentRelationException(
        'Type mismatch during relational resolution. '
        'The relation expected a parent entity of type "$P", '
        'but received an instance of "${parent.runtimeType}". '
        'Ensure the relation is registered to the correct model.',
        stackTrace: StackTrace.current,
      );
      FluentLog.error(
        exception.message,
        exception,
        exception.stackTrace,
        tag: 'FluentDbRelation:select',
        hint:
            'Verify that the model registered in your FluentDbRelation matches the '
            'actual instance being passed to the query. This usually happens when '
            'an entity is incorrectly mapped to a relation config of a different model.',
        context: {'expectedType': '$P', 'receivedType': '${parent.runtimeType}'},
      );
      throw exception;
    }

    return _internalSelector(parent);
  }

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

    FluentLog.warning('Relation disabled: $validError', tag: 'FluentDbRelation:disable', context: {'error': validError});
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
