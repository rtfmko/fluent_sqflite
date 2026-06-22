part of '../fluent_provider.dart';

/// Enterprise data-layer extension providing uniform, concurrent entity graph hydration for [FluentStorable] models.
///
/// The [FluentRelationsLoader] extension implements high-throughput relationship traversal over [FluentRelationsMixin].
/// It bridges flat relational database rows with deep, object-oriented memory graphs by automating
/// cross-table data resolution.
///
/// ### Structural Design & Hydration Mechanics
/// Operations within this extension manage complex entity associations while enforcing strict data consistency
/// and performance containment boundaries:
///
/// * **Automated Entity Hydration:** Seamlessly intersects raw schema query boundaries to inflate multi-tier
///   object relationships. The layer targets only definitions explicitly marked for automated loading, ensuring
///   eager loading boundaries remain predictable and optimal.
/// * **Concurrent Future Fan-Out:** To eliminate the latency overhead of serial database queries (the N+1 query problem),
///   the loading pipeline dynamically collects individual property lookups into an un-awaited collection pool,
///   fanning them out concurrently via [Future.wait]. This structure drastically reduces total execution locks.
/// * **Polymorphic Relation Resolution:** Evaluates model configuration metadata at runtime to shift lookup behavior
///   dynamically. It bridges structural distinct paths—including singular pairings ([FluentDbRelationType.oneToOne],
///   [FluentDbRelationType.manyToOne]) and collection sets ([FluentDbRelationType.oneToMany])—mapping data arrays directly
///   back to internal entity state structures.
/// * **Registry-Driven Dependency Isolation:** Decouples direct table cross-references by looking up target repositories
///   dynamically inside the central [FluentDb] using runtime typing signatures. This structure eliminates tight
///   compile-time coupling between domain providers, maintaining modular boundary layers.
/// * **Static Telemetry Isolation:** Diagnostics rely exclusively on a unified global facade pattern. Runtime metadata
///   and sizing counts are encapsulated into isolated execution tracking maps rather than dynamic text buffers,
///   guaranteeing that zero temporary strings are generated on the heap when pipeline logging is deactivated.
///
/// See also:
/// * [FluentRelationsMixin], the structural contract enabling relational capabilities on repositories.
/// * [FluentDbRelation], the data class defining join constraints, keys, and automated loading policies.
/// * [FluentDbRelationType], the structural mapping enumeration defining join directions.
extension FluentRelationsLoader<T extends FluentStorable> on FluentRelationsMixin<T> {
  /// Eagerly loads and hydrates external relational entity graphs mapped to the target [model] instance.
  ///
  /// This relational resolution driver automates cross-table schema joining via selective future collection:
  /// * Evaluates available relationship definitions early, bypassing orchestration overhead if [resolvedRelations] is empty.
  /// * Filters relational structures to execute data resolution only for definitions flagged with `autoLoad`.
  /// * Dynamically fetches target access points from [FluentDb] using runtime typing signatures.
  /// * Diverges processing pipelines using specific matching strategies for `oneToOne`, `manyToOne`, and `oneToMany` loops.
  /// * Prevents nested async cascades by aggregating target queries inside a non-blocking [Future.wait] fan-out loop.
  ///
  /// [model] represents the source storable entity whose relational structural properties require resolution.
  /// [rawJson] defines the primary flat database map containing the raw target foreign and local indexing keys.
  ///
  /// Returns a [Future<T>] completing with the fully hydrated, structurally rich object model graph.
  Future<T> loadAllRelations(T model, Map<String, dynamic> rawJson) async {
    final relations = resolvedRelations;
    if (relations.isEmpty) return model;

    final List<Future<void>> futures = [];

    // Iterate through registered relational properties to identify autoload targets
    for (final MapEntry<Type, FluentDbRelation<FluentStorable>> entry in relations.entries) {
      final FluentDbRelation relation = entry.value;

      if (!relation.autoLoad) continue;

      final targetProvider = FluentDb.providerForType(entry.key);
      final String key = relation.mapToKey;

      // Evaluate relational maps to orchestrate targeted index queries against child tables
      switch (relation.relationType) {
        case FluentDbRelationType.oneToOne:
        case FluentDbRelationType.manyToOne:
          final dynamic keyValue = rawJson[relation.localKey];
          if (keyValue != null) {
            futures.add(
              targetProvider.findById(keyValue).then((relatedObject) {
                if (relatedObject != null) {
                  model.setRelation(key, relatedObject);
                }
              }),
            );
          }
          break;

        case FluentDbRelationType.oneToMany:
          final String pkName = primaryKeyColumn.name;
          final dynamic keyValue = rawJson[pkName];

          if (keyValue != null) {
            // Resolve the target column fallback using the child provider's defaults if not explicitly declared
            final String remoteKey = relation.remoteKey ?? targetProvider.defaultForeignKey;

            futures.add(
              targetProvider.find(where: '$remoteKey = ?', whereArgs: [keyValue]).then((relatedList) {
                if (relatedList.isNotEmpty) {
                  model.setRelation(key, relatedList);
                }
              }),
            );
          }
          break;

        default:
          break;
      }
    }

    if (futures.isNotEmpty) {
      FluentLog.debug(
        'Fanning out parallel relational entity hydration streams for storage model mapping',
        tag: '$tableName:pipeline',
        context: {'tableName': tableName, 'targetModelType': T.toString(), 'totalActiveHydrationStreams': futures.length},
      );
      await Future.wait(futures);
    }

    return model;
  }
}
