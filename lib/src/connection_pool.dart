part of sqljocky;

class ConnectionPool {
  final String _host;
  final int _port;
  final String _user;
  final String _password;
  final String _db;
  final Queue<Completer<Connection>> _pendingConnections;
  
  int _max;
  
  final List<Connection> _pool;
  final Map<String, Query> _preparedQueryCache;
  bool _inUse = false;

  ConnectionPool({String host: 'localhost', int port: 3306, String user, 
      String password, String db, int max: 5}) :
        _preparedQueryCache = new Map<String, Query>(),
        _pendingConnections = new Queue<Completer>(),
        _pool = new List<Connection>(),
        _host = host,
        _port = port,
        _user = user,
        _password = password,
        _db = db,
        _max = max;
  
  Future<Connection> _getConnection() {
    var completer = new Completer<Connection>();
    
    for (var cnx in _pool) {
      if (!cnx._inUse) {
        print("Reusing existing pooled connection");
        completer.complete(cnx);
        return completer.future;
      }
    }
    
    if (_pool.length < _max) {
      print("Creating new pooled connection");
      Connection cnx = new Connection(this);
      cnx.onClosed = _getConnectionClosedHandler(cnx);
      var future = cnx.connect(
          host: _host, 
          port: _port, 
          user: _user, 
          password: _password, 
          db: _db);
      _pool.add(cnx);
      future.then((x) {
        completer.complete(cnx);
      });
      future.handleException((e) {
        completer.completeException(e);
        return true;
      });
    } else {
      _pendingConnections.add(completer);
    }
    return completer.future;
  }
  
  _getConnectionClosedHandler(Connection cnx) {
    return () {
      if (!_pool.contains(cnx)) {
        print("_connectionClosed handler called for unmanaged connection");
        return;
      }
      
      if (_pendingConnections.length > 0) {
        print("Connection finished with - reusing for queued operation");
        var completer = _pendingConnections.removeFirst();
        completer.complete(cnx);
      } else {
        print("Marking pooled connection as not in use");
        cnx._inUse = false;
      }
    };
  }
  
  Future useDatabase(String dbName) {
    var completer = new Completer();
    
    var cnxFuture = _getConnection();
    cnxFuture.then((cnx) {
      var handler = new UseDbHandler(dbName);
      var future = _connection._processHandler(handler);
      future.then((x) {
        completer.completer();
      });
      future.handleException((e) {
        completer.completeException(e);
        return true;
      });
    });
    cnxFuture.handleException((e) {
      completer.completeException(e);
      return true;
    });
    
    return completer.future;
  }
  
  void close() {
    if (_pool != null) {
    } else {
      var handler = new QuitHandler();
      _connection._processHandler(handler, noResponse:true);
      _connection.close();
    }
  }

  Future<Results> query(String sql) {
    var completer = new Completer<Results>();
    
    var cnxFuture = _getConnection();
    cnxFuture.then((cnx) {
      var handler = new QueryHandler(sql);
      var queryFuture = cnx._processHandler(handler);
      queryFuture.then((results) {
        completer.complete(results);
      });
      queryFuture.handleException((e) {
        completer.completeException(e);
        return true;
      });
    });
    cnxFuture.handleException((e) {
      completer.completeException(e);
      return true;
    });
    
    return completer.future;
  }
  
  Future<int> update(String sql) {
  }
  
  Future ping() {
    var handler = new PingHandler();
    return _connection._processHandler(handler);
  }
  
  Future debug() {
    var handler = new DebugHandler();
    return _connection._processHandler(handler);
  }
  
  void _closeQuery(Query q) {
    _preparedQueryCache.remove(q.sql);
    var handler = new CloseStatementHandler(q.statementId);
    var cnxFuture = _getConnection();
    cnxFuture.then((cnx) {
      cnx._processHandler(handler, noResponse: true);
    });    
  }
  
  Future<Query> prepare(String sql) {
    Completer completer = new Completer<Query>();

    if (_preparedQueryCache.containsKey(sql)) {
      completer.complete(_preparedQueryCache[sql]);
      return completer.future;
    }
    
    var cnxFuture = _getConnection();
    cnxFuture.then((cnx) {
      var handler = new PrepareHandler(sql);
      Future<PreparedQuery> queryFuture = cnx._processHandler(handler);
      queryFuture.then((preparedQuery) {
        Query q = new Query._internal(this, preparedQuery, sql);
        _preparedQueryCache[sql] = q;
        completer.complete(q);
      });
      queryFuture.handleException((e) {
        completer.completeException(e);
        return true;
      });
    });
    cnxFuture.handleException((e) {
      completer.completeException(e);
      return true;
    });
    return completer.future;
  }
  
  Future<Transaction> startTransaction({bool consistent: false}) {
    var c = new Completer<Transaction>();
    
    var cnxFuture = _getConnection();
    cnxFuture.then((cnx) {
      var sql;
      if (consistent) {
        sql = "start transaction with consistent snapshot";
      } else {
        sql = "start transaction";
      }
      var handler = new QueryHandler(sql);
      var queryFuture = cnx._processHandler(handler);
      queryFuture.then((results) {
        var transaction = new Transaction(cnx);
        completer.complete(transaction);
      });
      queryFuture.handleException((e) {
        completer.completeException(e);
        return true;
      });
    });
    cnxFuture.handleException((e) {
      completer.completeException(e);
      return true;
    });
    
    return completer.future;
  }
  
  Future<Results> prepareExecute(String sql, List<dynamic> parameters) {
    var completer = new Completer<Results>();
    Future<Query> future = prepare(sql);
    future.then((Query q) {
      for (int i = 0; i < parameters.length; i++) {
        q[i] = parameters[i];
      }
      var future = q.execute();
      future.then((Results results) {
        completer.complete(results);
      });
      future.handleException((e) {
        completer.completeException(e);
        return true;
      });
    });
    future.handleException((e) {
      completer.completeException(e);
      return true;
    });
    return completer.future;
  }
  
//  dynamic fieldList(String table, [String column]);
//  dynamic refresh(bool grant, bool log, bool tables, bool hosts,
//                  bool status, bool threads, bool slave, bool master);
//  dynamic shutdown(bool def, bool waitConnections, bool waitTransactions,
//                   bool waitUpdates, bool waitAllBuffers,
//                   bool waitCriticalBuffers, bool killQuery, bool killConnection);
//  dynamic statistics();
//  dynamic processInfo();
//  dynamic processKill(int id);
//  dynamic changeUser(String user, String password, [String db]);
//  dynamic binlogDump(options);
//  dynamic registerSlave(options);
//  dynamic setOptions(int option);
}

class Query {
  final ConnectionPool _pool;
  final PreparedQuery _preparedQuery;
  final List<dynamic> _values;
  final String sql;
  bool _executed = false;

  int get statementId => _preparedQuery.statementHandlerId;
  
  Query._internal(ConnectionPool pool, PreparedQuery preparedQuery, this.sql) :
      _pool = pool,
      _preparedQuery = preparedQuery,
      _values = new List<dynamic>(preparedQuery.parameters.length);

  void close() {
    _pool._closeQuery(this);
  }
  
  Future<Results> execute() {
    var handler = new ExecuteQueryHandler(_preparedQuery, _executed, _values);
    return _pool._connection._processHandler(handler);
  }
  
  Future<List<Results>> executeMulti(List<List<dynamic>> parameters) {
    Completer<List<Results>> completer = new Completer<List<Results>>();
    List<Results> resultList = new List<Results>();
    exec(int i) {
      _values.setRange(0, _values.length, parameters[i]);
      var future = execute();
      future.then((Results results) {
        resultList.add(results);
        if (i < parameters.length - 1) {
          exec(i + 1);
        } else {
          completer.complete(resultList);
        }
      });
      future.handleException((e) {
        completer.completeException(e);
        return true;
      });
    }
    exec(0);
    return completer.future;
  } 
  
  Future<int> executeUpdate() {
    
  }

  dynamic operator [](int pos) => _values[pos];
  
  void operator []=(int index, dynamic value) {
    _values[index] = value;
    _executed = false;
  }
  
//  dynamic longData(int index, data);
//  dynamic reset();
//  dynamic fetch(int rows);
}

class Transaction {
  Connection cnx;
  
  Transaction._interal(this.cnx);
  
  Future commit() {
    return query("commit");
  }
  
  Future rollback() {
    return query("rollback");
  }

  Future<Results> query(String sql) {
    var c = new Completer<Results>();
    
    var handler = new QueryHandler(sql);
    var queryFuture = cnx._processHandler(handler);
    queryFuture.then((results) {
      c.complete(results);
    });
    queryFuture.handleException((e) {
      c.completeException(e);
      return true;
    });

    return c.future;
  }
  
  Future<Query> prepare(String sql) {
    
  }
  
  Future<Results> prepareExecute(String sql, List<dynamic> parameters) {
    
  }
}