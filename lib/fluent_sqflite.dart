// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// fluent_sqflite: model-driven SQLite for Flutter — schema from your models, typed queries, relations, soft delete,
/// streams and server sync.
///
/// This is the public API. What the library uses internally (engine, registry, schema sync, row mapping, internal
/// extensions and enums) lives in `src/internal.dart` and is hidden here, so it cannot be misused by accident.
library;

export 'src/core/core.dart'
    hide
        FluentDbInternals,
        FluentFullTextSchema,
        FluentLifecycleHooks,
        FluentProviderInternals,
        FluentPullStats,
        FluentRelationLink,
        FluentRelationSaveContext,
        FluentRelationSchema,
        FluentSchema,
        FluentSchemaSync,
        FluentSchemaSyncContext,
        FluentSyncCore,
        buildFluentRelationGraph,
        ensureFluentSchemaTables,
        fluentLazyTrash,
        fluentLazyWithTrash,
        fluentMigrateRelations,
        fluentAdoptLegacyNames,
        fluentAdoptLegacyTypeValues,
        fluentSchemaUpToDate,
        fluentSchemaHistoryTable,
        fluentSchemaTable,
        readFluentSchemaHistory,
        readFluentSchemaSnapshots,
        writeFluentSchemaHistory;
export 'src/exceptions/exceptions.dart';
export 'src/interfaces/interfaces.dart' hide FluentStorableInternals, fluentSameKeyValue;
export 'src/models/models.dart' hide FluentDbColumnRules, fluentIsoText, fluentSqlLiteral;
export 'src/relations/relations.dart';
export 'src/soft_delete/soft_delete.dart';
export 'src/sync/sync.dart';
export 'src/timestamps/timestamps.dart';
// Extensions the library uses itself stay internal: they would add members to String, Map, DateTime in user code.
export 'src/utils/utils.dart'
    hide
        ExecutionPolicyUtils,
        FluentColorStrings,
        FluentDateTimeX,
        FluentDbAction,
        FluentDbActionX,
        FluentDeferredCondition,
        FluentFilterArgs,
        FluentFilterInternals,
        FluentIdentifier,
        FluentQuotedColumns,
        FluentQuotedRow,
        FluentJsonExtension,
        FluentKeyCondition,
        FluentRelatedCondition,
        FluentRelatedMode,
        FluentSearchCondition,
        fluentRetryCanHelp,
        fluentRetryDelay,
        fluentMaxRetryDelay,
        fluentValueKey,
        fluentFilterKey;
