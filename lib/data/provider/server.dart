import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:computer/computer.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:toolbox/core/extension/ssh_client.dart';
import 'package:toolbox/core/utils/platform/path.dart';
import 'package:toolbox/data/model/app/shell_func.dart';
import 'package:toolbox/data/model/server/system.dart';
import 'package:toolbox/data/model/sftp/req.dart';
import 'package:toolbox/data/res/logger.dart';
import 'package:toolbox/data/res/path.dart';
import 'package:toolbox/data/res/provider.dart';
import 'package:toolbox/data/res/store.dart';

import '../../core/extension/order.dart';
import '../../core/extension/uint8list.dart';
import '../../core/utils/server.dart';
import '../model/server/server.dart';
import '../model/server/server_private_info.dart';
import '../model/server/server_status_update_req.dart';
import '../model/server/snippet.dart';
import '../model/server/try_limiter.dart';
import '../res/status.dart';

class ServerProvider extends ChangeNotifier {
  final Map<String, Server> _servers = {};
  Iterable<Server> get servers => _servers.values;
  final Order<String> _serverOrder = [];
  Order<String> get serverOrder => _serverOrder;
  final List<String> _tags = [];
  List<String> get tags => _tags;

  Timer? _timer;

  Future<void> load() async {
    // Issue #147
    // Clear all servers because of restarting app will cause duplicate servers
    final oldServers = Map<String, Server>.from(_servers);
    _servers.clear();
    _serverOrder.clear();

    final spis = Stores.server.fetch();
    for (int idx = 0; idx < spis.length; idx++) {
      final spi = spis[idx];
      final originServer = oldServers[spi.id];
      final newServer = genServer(spi);

      /// Issues #258
      /// If not [shouldReconnect], then keep the old state.
      if (originServer != null && !originServer.spi.shouldReconnect(spi)) {
        newServer.state = originServer.state;
      }
      _servers[spi.id] = newServer;
    }
    final serverOrder_ = Stores.setting.serverOrder.fetch();
    if (serverOrder_.isNotEmpty) {
      spis.reorder(
        order: serverOrder_,
        finder: (n, id) => n.id == id,
      );
      _serverOrder.addAll(spis.map((e) => e.id));
    } else {
      _serverOrder.addAll(_servers.keys);
    }
    // Must use [equals] to compare [Order] here.
    if (!_serverOrder.equals(serverOrder_)) {
      Stores.setting.serverOrder.put(_serverOrder);
    }
    _updateTags();
    notifyListeners();
  }

  /// Get a [Server] by [spi] or [id].
  ///
  /// Priority: [spi] > [id]
  Server? pick({ServerPrivateInfo? spi, String? id}) {
    if (spi != null) {
      return _servers[spi.id];
    }
    if (id != null) {
      return _servers[id];
    }
    return null;
  }

  void _updateTags() {
    _tags.clear();
    for (final s in _servers.values) {
      if (s.spi.tags == null) continue;
      for (final t in s.spi.tags!) {
        if (!_tags.contains(t)) {
          _tags.add(t);
        }
      }
    }
    _tags.sort();
    notifyListeners();
  }

  void renameTag(String old, String new_) {
    for (final s in _servers.values) {
      if (s.spi.tags == null) continue;
      for (var i = 0; i < s.spi.tags!.length; i++) {
        if (s.spi.tags![i] == old) {
          s.spi.tags![i] = new_;
        }
      }
      Stores.server.update(s.spi, s.spi);
    }
    _updateTags();
  }

  Server genServer(ServerPrivateInfo spi) {
    return Server(spi, InitStatus.status, ServerState.disconnected);
  }

  /// if [spi] is specificed then only refresh this server
  /// [onlyFailed] only refresh failed servers
  Future<void> refresh({
    ServerPrivateInfo? spi,
    bool onlyFailed = false,
  }) async {
    if (spi != null) {
      await _getData(spi);
      return;
    }

    await Future.wait(_servers.values.map((s) => _connectFn(s, onlyFailed)));
  }

  Future<void> _connectFn(Server s, bool onlyFailed) async {
    if (onlyFailed) {
      if (s.state != ServerState.failed) return;
      TryLimiter.reset(s.spi.id);
    }

    /// If [spi.autoConnect] is false and server is disconnected, then skip.
    ///
    /// If [spi.autoConnect] is false and server is connected, then refresh.
    /// If no this, the server will only refresh once by clicking refresh button.
    ///
    /// If [spi.autoConnect] is true, then refresh.
    if (!(s.spi.autoConnect ?? true) && s.state == ServerState.disconnected) {
      return;
    }
    return await _getData(s.spi);
  }

  static final refreshKey = GlobalKey<RefreshIndicatorState>();

  Future<void> startAutoRefresh() async {
    var duration = Stores.setting.serverStatusUpdateInterval.fetch();
    stopAutoRefresh();
    if (duration == 0) return;
    if (duration < 0 || duration > 10 || duration == 1) {
      duration = 3;
      Loggers.app.warning('Invalid duration: $duration, use default 3');
    }
    refreshKey.currentState?.show();
    _timer = Timer.periodic(Duration(seconds: duration), (_) async {
      await refresh();
    });
  }

  void stopAutoRefresh() {
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  bool get isAutoRefreshOn => _timer != null;

  void setDisconnected() {
    for (final s in _servers.values) {
      s.state = ServerState.disconnected;
    }
    //TryLimiter.clear();
    notifyListeners();
  }

  void closeServer({String? id}) {
    if (id == null) {
      for (final s in _servers.values) {
        _closeOneServer(s.spi.id);
      }
      return;
    }
    _closeOneServer(id);
  }

  void _closeOneServer(String id) {
    _servers[id]?.client?.close();
    _servers[id]?.client = null;
  }

  void addServer(ServerPrivateInfo spi) {
    _servers[spi.id] = genServer(spi);
    notifyListeners();
    Stores.server.put(spi);
    _serverOrder.add(spi.id);
    Stores.setting.serverOrder.put(_serverOrder);
    _updateTags();
    refresh(spi: spi);
  }

  void delServer(String id) {
    _servers.remove(id);
    _serverOrder.remove(id);
    Stores.setting.serverOrder.put(_serverOrder);
    _updateTags();
    notifyListeners();
    Stores.server.delete(id);
  }

  void deleteAll() {
    _servers.clear();
    _serverOrder.clear();
    Stores.setting.serverOrder.put(_serverOrder);
    _updateTags();
    notifyListeners();
    Stores.server.deleteAll();
  }

  Future<void> updateServer(
    ServerPrivateInfo old,
    ServerPrivateInfo newSpi,
  ) async {
    if (old != newSpi) {
      Stores.server.update(old, newSpi);
      _servers[old.id]?.spi = newSpi;

      if (newSpi.id != old.id) {
        _servers[newSpi.id] = _servers[old.id]!;
        _servers[newSpi.id]?.spi = newSpi;
        _servers.remove(old.id);
        _serverOrder.update(old.id, newSpi.id);
        Stores.setting.serverOrder.put(_serverOrder);
      }

      // Only reconnect if neccessary
      if (newSpi.shouldReconnect(old)) {
        // Use [newSpi.id] instead of [old.id] because [old.id] may be changed
        TryLimiter.reset(newSpi.id);
        refresh(spi: newSpi);
      }

      // Only update if [spi.tags] changed
      _updateTags();
    }
  }

  void _setServerState(Server s, ServerState ss) {
    s.state = ss;
    notifyListeners();
  }

  Future<void> _writeInstallerScript(Server s) async {
    void ensure(String? writeResult) {
      if (writeResult == null || writeResult.isNotEmpty) {
        throw Exception("Failed to write installer script: $writeResult");
      }
    }

    final client = s.client;
    if (client == null) {
      throw Exception("Invalid state: s.client cannot be null");
    }

    ensure(await client.run(ShellFunc.installerMkdirs).string);

    ensure(await client.runForOutput(ShellFunc.installerShellWriter,
            action: (session) async {
              session.stdin.add(utf8.encode(ShellFunc.allScript));
            })
        .string);

    ensure(await client.run(ShellFunc.installerPermissionModifier).string);
  }

  Future<void> _getData(ServerPrivateInfo spi) async {
    final sid = spi.id;
    final s = _servers[sid];

    if (s == null) return;

    if (!TryLimiter.canTry(sid)) {
      if (s.state != ServerState.failed) {
        _setServerState(s, ServerState.failed);
      }
      return;
    }

    s.status.err = null;

    if (s.needGenClient || (s.client?.isClosed ?? true)) {
      _setServerState(s, ServerState.connecting);

      try {
        final time1 = DateTime.now();
        s.client = await genClient(
          spi,
          timeout: Duration(seconds: Stores.setting.timeout.fetch()),
        );
        final time2 = DateTime.now();
        final spentTime = time2.difference(time1).inMilliseconds;
        if (spi.jumpId == null) {
          Loggers.app.info('Connected to ${spi.name} in $spentTime ms.');
        } else {
          Loggers.app.info(
            'Connected to ${spi.name} via jump server in $spentTime ms.',
          );
        }
      } catch (e) {
        TryLimiter.inc(sid);
        s.status.err = e.toString();
        _setServerState(s, ServerState.failed);

        /// In order to keep privacy, print [spi.name] instead of [spi.id]
        Loggers.app.warning('Connect to ${spi.name} failed', e);
        return;
      }

      _setServerState(s, ServerState.connected);

      // Write script to server
      // by ssh
      try {
        await _writeInstallerScript(s);
      } on SSHAuthAbortError catch (e) {
        TryLimiter.inc(sid);
        s.status.err = e.toString();
        _setServerState(s, ServerState.failed);
        return;
      } catch (e) {
        Loggers.app.warning('Write script to ${spi.name} by shell', e);

        /// by sftp
        final localPath = joinPath(await Paths.doc, 'install.sh');
        final file = File(localPath);
        try {
          file.writeAsString(ShellFunc.allScript);
          final completer = Completer();
          final homePath = (await s.client?.run('echo \$HOME').string)?.trim();
          if (homePath == null || homePath.isEmpty) {
            throw Exception('Got empty home path');
          }
          final remotePath = ShellFunc.getShellPath(homePath);
          final reqId = Pros.sftp.add(
            SftpReq(spi, remotePath, localPath, SftpReqType.upload),
            completer: completer,
          );
          await completer.future;
          final err = Pros.sftp.get(reqId)?.error;
          if (err != null) {
            throw err;
          }
        } catch (e) {
          TryLimiter.inc(sid);
          s.status.err = e.toString();
          _setServerState(s, ServerState.failed);
          Loggers.app.warning('Write script to ${spi.name} by sftp', e);
          return;
        } finally {
          if (await file.exists()) await file.delete();
        }
      }
    }

    /// Keep [finished] state, or the UI will be refreshed to [loading] state
    /// instead of the '$Temp | $Uptime'.
    /// eg: '32C | 7 days'
    if (s.state != ServerState.finished) {
      _setServerState(s, ServerState.loading);
    }

    List<String>? segments;
    String? raw;

    try {
      raw = await s.client?.run(ShellFunc.status.exec).string;
      segments = raw?.split(seperator).map((e) => e.trim()).toList();
      if (raw == null || raw.isEmpty || segments == null || segments.isEmpty) {
        TryLimiter.inc(sid);
        s.status.err = 'Seperate segments failed, raw:\n$raw';
        _setServerState(s, ServerState.failed);
        return;
      }
    } catch (e) {
      TryLimiter.inc(sid);
      s.status.err = e.toString();
      _setServerState(s, ServerState.failed);
      Loggers.app.warning('Get status from ${spi.name} failed', e);
      return;
    }

    final systemType = SystemType.parse(segments[0]);
    if (!systemType.isSegmentsLenMatch(segments.length)) {
      TryLimiter.inc(sid);
      s.status.err =
          'Segments not match: expect ${systemType.segmentsLen}, got ${segments.length}';
      _setServerState(s, ServerState.failed);
      return;
    }
    s.status.system = systemType;

    try {
      final req = ServerStatusUpdateReq(
        ss: s.status,
        segments: segments,
        system: systemType,
      );
      s.status = await Computer.shared.start(
        getStatus,
        req,
        taskName: 'StatusUpdateReq<${s.id}>',
      );
    } catch (e, trace) {
      TryLimiter.inc(sid);
      s.status.err = 'Parse failed: $e\n\n$raw';
      _setServerState(s, ServerState.failed);
      Loggers.parse.warning('Server status', e, trace);
      return;
    }

    /// Call this every time for setting [Server.isBusy] to false
    _setServerState(s, ServerState.finished);
    // reset try times only after prepared successfully
    TryLimiter.reset(sid);
  }

  Future<SnippetResult?> runSnippet(String id, Snippet snippet) async {
    final server = _servers[id];
    if (server == null) return null;
    final watch = Stopwatch()..start();
    final result = await server.client?.run(snippet.fmtWith(server.spi)).string;
    final time = watch.elapsed;
    watch.stop();
    if (result == null) return null;
    return SnippetResult(
      dest: _servers[id]?.spi.name,
      result: result,
      time: time,
    );
  }

  // Future<List<SnippetResult?>> runSnippetsMulti(
  //   List<String> ids,
  //   Snippet snippet,
  // ) async {
  //   return await Future.wait(ids.map((id) async => runSnippet(id, snippet)));
  // }
}
