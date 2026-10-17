import 'dart:async';
import 'dart:math';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../core/ph_sample.dart';

/// Persists every pH reading (sqflite). Writes are buffered and flushed in
/// batches so a steady 2 Hz stream costs one transaction every few seconds.
class SampleStore {
  /// [factory] and [path] default to the platform database; tests inject an
  /// in-memory one.
  SampleStore({DatabaseFactory? factory, this._path})
    : _factory = factory ?? databaseFactory;

  static const _flushDelay = Duration(seconds: 3);
  static const _flushSize = 50;

  final DatabaseFactory _factory;
  final String? _path;

  Future<Database>? _db;
  final _buffer = <PhSample>[];
  Timer? _timer;

  /// Tail of the flush chain; never completes with an error.
  Future<void> _queue = Future.value();

  Future<Database> get _database => _db ??= _open();

  Future<Database> _open() async {
    final path = _path ?? join(await _factory.getDatabasesPath(), 'samples.db');
    return _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        // ts is the rowid, so range scans need no extra index.
        onCreate: (db, _) => db.execute(
          'CREATE TABLE samples (ts INTEGER PRIMARY KEY, ph REAL NOT NULL)',
        ),
      ),
    );
  }

  /// Buffers one sample; flushed automatically.
  void add(PhSample sample) {
    _buffer.add(sample);
    if (_buffer.length >= _flushSize) {
      unawaited(flush());
    } else {
      _timer ??= Timer(_flushDelay, flush);
    }
  }

  /// Writes buffered samples now. A failed write drops that batch.
  Future<void> flush() {
    _timer?.cancel();
    _timer = null;
    if (_buffer.isEmpty) return _queue;
    final batch = List.of(_buffer);
    _buffer.clear();
    final done = _queue.then((_) => _write(batch));
    _queue = done.onError((_, _) {});
    return done;
  }

  Future<void> _write(List<PhSample> batch) async {
    final db = await _database;
    final b = db.batch();
    for (final s in batch) {
      b.insert('samples', {
        'ts': s.time.millisecondsSinceEpoch,
        'ph': s.ph,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await b.commit(noResult: true);
  }

  /// Samples in [from, to], downsampled to at most about [maxPoints] points
  /// (bucket average) so long ranges stay fast to load and draw.
  Future<List<PhSample>> query(
    DateTime from,
    DateTime to, {
    int maxPoints = 1000,
  }) async {
    await flush();
    final start = from.millisecondsSinceEpoch;
    final end = to.millisecondsSinceEpoch;
    final bucketMs = max(1, (end - start) ~/ maxPoints);
    final db = await _database;
    final rows = await db.rawQuery(
      'SELECT MIN(ts) AS t, AVG(ph) AS ph FROM samples '
      'WHERE ts BETWEEN ? AND ? GROUP BY ts / ? ORDER BY t',
      [start, end, bucketMs],
    );
    return [
      for (final r in rows)
        PhSample(
          DateTime.fromMillisecondsSinceEpoch(r['t']! as int),
          (r['ph']! as num).toDouble(),
        ),
    ];
  }

  Future<void> close() async {
    try {
      await flush();
    } finally {
      final db = _db;
      _db = null;
      await (await db)?.close();
    }
  }
}
