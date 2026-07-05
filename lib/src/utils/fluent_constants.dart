// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

part of '../core/fluent_sqlite_internal.dart';

/// The filename for the dedicated system database used by the FluentEngine.
const String _systemDbName = 'fluent_system.db';

/// The default retention interval for soft-deleted records before they qualify for hard deletion.
const Duration defaultSoftDeleteRetentionPeriod = Duration(days: 7);
