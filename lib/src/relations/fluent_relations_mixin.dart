// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

import 'package:flutter/foundation.dart';

import '../core/core.dart';
import '../core/fluent_sqlite_internal.dart';
import '../core/utils/utils.dart';
import '../interfaces/interfaces.dart';
import '../models/models.dart';
import '../utils/utils.dart';

/// A mixin that enables bi-directional relationship management for [FluentProvider] instances.
///
/// [FluentRelationsMixin] provides the infrastructure for models to declare, link, and
/// resolve complex associations (one-to-one, one-to-many, many-to-many) with other
/// [FluentStorable] entities. It facilitates:
///
/// * **Automatic Linking:** Resolving foreign keys and pivot tables at runtime.
/// * **Backlink Propagation:** Automatically registering inverse relationships to
///   ensure data integrity across the entity graph.
/// * **Schema Awareness:** Managing a collection of both outgoing and incoming
///   database relations.
///
/// Use this mixin on your [FluentProvider] classes to unlock full relational
/// capabilities and automated JOIN support.
mixin FluentRelationsMixin<T extends FluentStorable> on FluentProvider<T> {
  /// Internal cache for resolved relationship definitions.
  /// Used to avoid redundant reflection or graph traversal during schema resolution.
  Map<Type, FluentDbRelation>? _relationsCache;

  /// Map of relationships targeting this model from other entities.
  ///
  /// This map acts as a registry for bidirectional links (backlinks), automatically
  /// populated during the schema discovery phase to ensure data integrity across
  /// the entity graph.
  ///
  /// **Note:** This collection is read-only for public consumers. Modifications
  /// are managed internally by the framework to prevent desynchronization.
  final Map<Type, FluentDbRelation> _incomingRelations = {};

  /// Returns an unmodifiable view of all relationships directed at this model
  /// from other entities (e.g., backlinks or foreign key references).
  Map<Type, FluentDbRelation> get incomingRelations => Map.unmodifiable(_incomingRelations);

  /// Defines the relationships this model has with other [FluentStorable] entities.
  ///
  /// Subclasses must override this to explicitly declare associations. This configuration
  /// allows the engine to resolve JOIN queries, manage foreign key constraints,
  /// and hydrate nested objects automatically.
  ///
  /// ### Usage Example:
  /// ```dart
  /// @override
  /// Map<Type, FluentDbRelation<FluentStorable, FluentStorable>> get relations => {
  ///   // 1:N relationship: One user has many posts
  ///   Post: FluentDbRelation<UserModel, Post>(
  ///     mapToKey: 'posts',
  ///     entitySelector: (parent) => parent.posts,
  ///     castType: FluentModelCast.modelList,
  ///   ),
  ///   // 1:1 relationship: One user has one profile
  ///   Profile: FluentDbRelation<UserModel, Profile>(
  ///     mapToKey: 'profile',
  ///     entitySelector: (parent) => parent.profile,
  ///     castType: FluentModelCast.model,
  ///     isLazy: false,
  ///   ),
  /// };
  /// ```
  Map<Type, FluentDbRelation<FluentStorable, FluentStorable>> get relations => {};

  /// Returns a synchronized, cached map of all relationships associated with this model.
  ///
  /// This getter implements lazy-loading for the relationship graph:
  /// * On first access, it triggers the [relations] configuration and populates the internal cache.
  /// * Subsequent calls return the cached map, minimizing reflection and instantiation overhead.
  /// * Returns an [UnmodifiableMapView] to protect the integrity of the relationship registry.
  Map<Type, FluentDbRelation> get resolvedRelations => Map.unmodifiable(_relationsCache ??= relations);

  /// Returns a list of all [Type]s that this model is related to.
  List<Type> get relatedTypes => relations.keys.toList();

  /// Retrieves the [FluentDbRelation] configuration for a specific related [Type].
  FluentDbRelation? relationFor(Type type) => relations[type];

  @internal
  @override
  void linkRelations(Iterable<FluentProvider> allProviders) {
    if (resolvedRelations.isEmpty) return;

    FluentLog.info('🔗 [LINK-START] Linking relations for table: "$tableName"', tag: 'FluentRelationMixin');

    for (final MapEntry<Type, FluentDbRelation> entry in resolvedRelations.entries) {
      final Type targetModelType = entry.key;
      final FluentDbRelation relation = entry.value;

      FluentProvider? targetProvider;
      try {
        targetProvider = allProviders.firstWhere((p) => p.modelType == targetModelType);
      } catch (_) {
        FluentLog.warning(
          'Provider not found for type: $targetModelType',
          tag: 'FluentRelationMixin',
          hint: 'Make sure the model class is registered in the FluentDb before attempting to link relations.',
        );
        targetProvider = null;
      }

      if (targetProvider == null) {
        continue;
      }

      FluentLog.debug('Processing relation: "$tableName" ➔ "${targetProvider.tableName}"', tag: 'FluentRelationMixin', context: {'type': relation.relationType.name});

      relation.targetTable = targetProvider.tableName;

      String cleanName(Type type) => type.toString().replaceAll('Model', '');
      FluentDbRelationType currentType = relation.relationType;
      String? currentLocalKey = relation.localKey;
      String? currentRemoteKey = relation.remoteKey;

      if (currentType == FluentDbRelationType.manyToMany) {
        if (relation.pivotTable == null) {
          final tables = [tableName, targetProvider.tableName]..sort();
          relation.pivotTable = "pivot_${tables[0]}_${tables[1]}";
        }
        currentLocalKey ??= "${FluentUtils.toSnakeCase(cleanName(modelType))}_id";
        currentRemoteKey ??= "${FluentUtils.toSnakeCase(cleanName(targetModelType))}_id";

        relation.localKey = currentLocalKey;
        relation.remoteKey = currentRemoteKey;
        FluentLog.debug('M2M detected', tag: 'FluentRelationMixin', context: {'pivot': relation.pivotTable, 'localKey': currentLocalKey, 'remoteKey': currentRemoteKey});
      } else if (currentType == FluentDbRelationType.auto) {
        String? remoteFk = relation.remoteKey;
        String? localFk = relation.localKey;

        if (targetProvider is FluentRelationsMixin && (remoteFk == null || localFk == null)) {
          final FluentRelationsMixin<FluentStorable> neighborMixin = targetProvider;
          final FluentDbRelation<FluentStorable, FluentStorable>? neighborRel = neighborMixin.resolvedRelations[modelType];

          if (neighborRel != null) {
            remoteFk ??= neighborRel.localKey;
            localFk ??= neighborRel.remoteKey;
          }
        }

        final Set<String> childRawColumns = targetProvider.modelSample.tableSchema.map((c) => c.name).toSet();
        final Set<String> myRawColumns = modelSample.tableSchema.map((c) => c.name).toSet();

        final String myShortName = FluentUtils.toSnakeCase(cleanName(modelType));
        final String neighborShortName = FluentUtils.toSnakeCase(cleanName(targetProvider.modelType));

        final String inferredChildFk = "${myShortName}_id";
        final String inferredMyFk = "${neighborShortName}_id";

        FluentLog.debug('Scanning schema for Auto-relation', tag: 'FluentRelationMixin', context: {'inferredChildFk': inferredChildFk, 'inferredMyFk': inferredMyFk});

        if (remoteFk == null && localFk == null) {
          if (childRawColumns.contains('owner_uuid') && myRawColumns.contains('user_uuid')) {
            remoteFk = 'owner_uuid';
            localFk = 'user_uuid';
            FluentLog.info('Custom key-pair match found (UUIDs)', tag: 'FluentRelationMixin');
          }
        }

        if (remoteFk == null && localFk == null) {
          if (childRawColumns.contains(inferredChildFk)) {
            remoteFk = inferredChildFk;
            localFk = modelSample.primaryKey.name;
          } else if (myRawColumns.contains(inferredMyFk)) {
            localFk = inferredMyFk;
            remoteFk = targetProvider.modelSample.primaryKey.name;
          } else if (childRawColumns.contains('parent_id')) {
            remoteFk = 'parent_id';
            localFk = modelSample.primaryKey.name;
          }
        }

        if (remoteFk != null && localFk != null) {
          if (childRawColumns.contains(remoteFk) && localFk == modelSample.primaryKey.name) {
            currentType = FluentDbRelationType.oneToMany;
          } else {
            currentType = FluentDbRelationType.manyToOne;
          }
        } else if (remoteFk != null) {
          currentType = FluentDbRelationType.oneToMany;
          localFk ??= modelSample.primaryKey.name;
        } else if (localFk != null) {
          currentType = FluentDbRelationType.manyToOne;
          remoteFk ??= targetProvider.modelSample.primaryKey.name;
        } else {
          currentType = FluentDbRelationType.oneToMany;
          remoteFk = inferredChildFk;
          localFk = modelSample.primaryKey.name;
        }
        FluentLog.info('Auto-inference result', tag: 'FluentRelationMixin', context: {'type': currentType.name, 'localKey': localFk, 'remoteKey': remoteFk});

        relation.relationType = currentType;
        relation.localKey = localFk;
        relation.remoteKey = remoteFk;
      }

      if (currentType != FluentDbRelationType.manyToMany) {
        if (currentType == FluentDbRelationType.oneToMany) {
          currentLocalKey ??= modelSample.primaryKey.name;
          currentRemoteKey ??= "${FluentUtils.toSnakeCase(cleanName(modelType))}_id";
        } else {
          currentLocalKey ??= "${FluentUtils.toSnakeCase(cleanName(targetProvider.modelType))}_id";
          currentRemoteKey ??= targetProvider.modelSample.primaryKey.name;
        }

        relation.localKey = currentLocalKey;
        relation.remoteKey = currentRemoteKey;
      }

      FluentLog.debug(
        'Final relation state',
        tag: 'FluentRelationMixin',
        context: {'type': relation.relationType.name, 'localKey': relation.localKey, 'remoteKey': relation.remoteKey, 'targetTable': relation.targetTable},
      );

      if (currentType == FluentDbRelationType.oneToMany) {
        final FluentModelCast backlinkCast = (relation.castType == FluentModelCast.modelList || relation.castType == FluentModelCast.model) ? FluentModelCast.model : FluentModelCast.map;

        final String backlinkMapKey = '_backlink_${tableName}_$currentRemoteKey';

        final FluentDbRelation backRel = FluentDbRelation(
          mapToKey: backlinkMapKey,
          relationType: FluentDbRelationType.manyToOne,
          localKey: currentRemoteKey,
          remoteKey: currentLocalKey,
          onDeleteCascade: relation.onDeleteCascade,
          castType: backlinkCast,
          entitySelector: (parent) => null,
        );
        backRel.targetTable = tableName;
        backRel.bindType(modelType);

        if (targetProvider is FluentRelationsMixin) {
          FluentLog.debug('Generating backlink', tag: 'FluentRelationMixin', context: {'key': backlinkMapKey});

          targetProvider.addIncomingRelation(modelType, backRel);
        } else {
          FluentLog.warning(
            'Target provider does not support FluentRelationsMixin, skipping backlink',
            tag: 'FluentRelationMixin',
            context: {'target': targetProvider.tableName},
            hint: 'Ensure that the target model class implements the FluentRelationsMixin to support bidirectional relationships.',
          );
        }
      }
    }
    FluentLog.info('Linking complete', tag: 'FluentRelationMixin');
  }

  /// Registers a reverse relationship from a related model back to this entity.
  ///
  /// This is used by the linker to maintain bidirectional data integrity. When
  /// an incoming relationship is added, the model's schema is refreshed to
  /// reflect the updated metadata and potential new query paths.
  ///
  /// [type] The [Type] of the model originating the relation.
  /// [relation] The [FluentDbRelation] configuration defining the inverse link.
  @internal
  void addIncomingRelation(Type type, FluentDbRelation relation) {
    _incomingRelations[type] = relation;
    refreshSchema();

    FluentLog.debug(
      'Added incoming relation from $type. Schema cache cleared.',
      tag: 'FluentRelationMixin:$tableName',
      context: {'targetTable': tableName, 'originType': type.toString(), 'relationType': relation.relationType.name},
    );
  }
}
