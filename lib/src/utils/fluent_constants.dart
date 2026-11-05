// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../core/fluent_sqlite_internal.dart';

/// The file of the telemetry database of earlier versions, deleted at start (query costs now live in each
/// database's `__fluent_stats` table).
const String legacyStatsDbName = 'fluent_system.db';
