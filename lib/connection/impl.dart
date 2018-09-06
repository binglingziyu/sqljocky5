import 'dart:async';

import '../handlers/quit_handler.dart';

import '../prepared_statements/close_statement_handler.dart';
import '../prepared_statements/execute_query_handler.dart';
import '../prepared_statements/prepare_handler.dart';
import '../query/query_stream_handler.dart';
import '../results/results.dart';
import '../comm/comm.dart';

import 'connection.dart';

class MySqlConnectionImpl implements MySqlConnection {
  final Duration _timeout;

  final Comm _socket;
  bool _sentClose = false;

  MySqlConnectionImpl(this._timeout, this._socket);

  Future<StreamedResults> execute(String sql) =>
      _socket.execResultHandler(QueryStreamHandler(sql), _timeout);

  Future<StreamedResults> prepared(String sql, Iterable values) async {
    PreparedQuery prepared;
    try {
      prepared = await _socket.execHandler(PrepareHandler(sql), _timeout);
      var handler = ExecuteQueryHandler(prepared, false, values);
      return _socket.execResultHandler(handler, _timeout);
    } catch (e) {
      if (prepared != null) {
        await _socket.execHandlerNoResponse(
            CloseStatementHandler(prepared.statementHandlerId), _timeout);
      }
      rethrow;
    }
  }

  Future<Stream<StreamedResults>> preparedWithAll(
      String sql, Iterable<Iterable> values) async {
    var controller = StreamController<StreamedResults>();
    PreparedQuery prepared =
        await _socket.execHandler(PrepareHandler(sql), _timeout);
    Future.microtask(() async {
      try {
        for (int i = 0; i < values.length; i++) {
          Iterable v = values.elementAt(i);
          var handler = ExecuteQueryHandler(prepared, false, v);
          controller.add(await _socket.execResultHandler(handler, _timeout));
        }
      } catch (e) {
        controller.addError(e);
        if (prepared != null) {
          _socket.execHandlerNoResponse(
              CloseStatementHandler(prepared.statementHandlerId), _timeout);
        }
        rethrow;
      }
    });
    return controller.stream;
  }

  @override
  Future<Prepared> prepare(String sql) async {
    PreparedQuery prepared =
        await _socket.execHandler(PrepareHandler(sql), _timeout);
    throw UnimplementedError();
  }

  Future<Transaction> begin() => Transaction.begin(this);

  Future<void> transaction(Future<void> work(Transaction transaction)) async {
    Transaction trans = await Transaction.begin(this);
    try {
      await work(trans);
    } catch (e) {
      await trans.rollback();
      if (e is! RollbackError) rethrow;
      return e;
    }
    await trans.commit();
  }

  /// Closes the connection
  ///
  /// This method will never throw
  Future<void> close() async {
    if (_sentClose) return;
    _sentClose = true;

    // TODO peacefully close the current handler!

    try {
      await _socket.execHandlerNoResponse(QuitHandler(), _timeout);
    } catch (e) {}

    _socket.close();
  }

  static Future<MySqlConnection> connect(ConnectionSettings c) async {
    var comm = await Comm.connect(c);
    return MySqlConnectionImpl(c.timeout, comm);
  }

  Future<StreamedResults> _executePrepared(
      PreparedQuery query, Iterable values) {
    var handler = ExecuteQueryHandler(query, false, values);
    return _socket.execResultHandler(handler, _timeout);
  }
}

class PreparedImpl implements Prepared {
  final MySqlConnectionImpl _conn;
  final PreparedQuery _query;

  PreparedImpl._(this._conn, this._query);

  @override
  Future<StreamedResults> execute(Iterable values) =>
      _conn._executePrepared(_query, values);

  @override
  Stream<StreamedResults> executeAll(Iterable<Iterable> values) {
    var controller = StreamController<StreamedResults>();
    Future.microtask(() async {
      try {
        for (int i = 0; i < values.length; i++) {
          Iterable v = values.elementAt(i);
          var handler = ExecuteQueryHandler(prepared, false, v);
          controller.add(await _socket.execResultHandler(handler, _timeout));
        }
      } catch (e) {
        controller.addError(e);
        if (prepared != null) {
          _socket.execHandlerNoResponse(
              CloseStatementHandler(prepared.statementHandlerId), _timeout);
        }
        rethrow;
      }
    });
    return controller.stream;
  }
}
