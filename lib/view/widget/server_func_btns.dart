import 'dart:io';

import 'package:flutter/material.dart';
import 'package:toolbox/core/extension/context/common.dart';
import 'package:toolbox/core/extension/context/dialog.dart';
import 'package:toolbox/core/extension/context/locale.dart';
import 'package:toolbox/core/extension/context/snackbar.dart';
import 'package:toolbox/core/extension/ssh_client.dart';
import 'package:toolbox/core/extension/uint8list.dart';
import 'package:toolbox/core/extension/widget.dart';
import 'package:toolbox/core/utils/platform/base.dart';
import 'package:toolbox/core/utils/platform/path.dart';
import 'package:toolbox/data/model/app/menu/server_func.dart';
import 'package:toolbox/data/model/app/shell_func.dart';
import 'package:toolbox/data/model/pkg/manager.dart';
import 'package:toolbox/data/model/server/dist.dart';
import 'package:toolbox/data/model/server/snippet.dart';
import 'package:toolbox/data/res/path.dart';
import 'package:toolbox/data/res/provider.dart';
import 'package:toolbox/data/res/store.dart';
import 'package:toolbox/data/res/ui.dart';

import '../../core/route.dart';
import '../../core/utils/server.dart';
import '../../data/model/pkg/upgrade_info.dart';
import '../../data/model/server/server_private_info.dart';
import 'popup_menu.dart';

class ServerFuncBtnsTopRight extends StatelessWidget {
  final ServerPrivateInfo spi;

  const ServerFuncBtnsTopRight({
    super.key,
    required this.spi,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenu<ServerFuncBtn>(
      items: ServerFuncBtn.values
          .map((e) => PopupMenuItem<ServerFuncBtn>(
                value: e,
                child: Row(
                  children: [
                    Icon(e.icon),
                    const SizedBox(
                      width: 10,
                    ),
                    Text(e.toStr),
                  ],
                ),
              ))
          .toList(),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      onSelected: (val) => _onTapMoreBtns(val, spi, context),
    );
  }
}

class ServerFuncBtns extends StatelessWidget {
  const ServerFuncBtns({
    super.key,
    required this.spi,
    this.iconSize,
  });

  final ServerPrivateInfo spi;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final btns = () {
      try {
        return Stores.setting.serverFuncBtns
            .fetch()
            .map((e) => ServerFuncBtn.values[e]);
      } catch (e) {
        return ServerFuncBtn.values;
      }
    }();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: btns
          .map(
            (e) => Stores.setting.moveOutServerTabFuncBtns.fetch()
                ? IconButton(
                    onPressed: () => _onTapMoreBtns(e, spi, context),
                    padding: EdgeInsets.zero,
                    tooltip: e.toStr,
                    icon: Icon(e.icon, size: iconSize ?? 15),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: () => _onTapMoreBtns(e, spi, context),
                        padding: EdgeInsets.zero,
                        icon: Icon(e.icon, size: iconSize ?? 15),
                      ),
                      Text(e.toStr, style: UIs.text11Grey)
                    ],
                  ).padding(const EdgeInsets.only(bottom: 13)),
          )
          .toList(),
    );
  }
}

void _onTapMoreBtns(
  ServerFuncBtn value,
  ServerPrivateInfo spi,
  BuildContext context,
) async {
  switch (value) {
    case ServerFuncBtn.pkg:
      _onPkg(context, spi);
      break;
    case ServerFuncBtn.sftp:
      AppRoute.sftp(spi: spi).checkGo(
        context: context,
        check: () => _checkClient(context, spi.id),
      );
      break;
    case ServerFuncBtn.snippet:
      final snippet = await context.showPickSingleDialog<Snippet>(
        items: Pros.snippet.snippets,
        name: (e) => e.name,
      );
      if (snippet == null) return;

      AppRoute.ssh(spi: spi, initCmd: snippet.fmtWith(spi)).checkGo(
        context: context,
        check: () => _checkClient(context, spi.id),
      );
      break;
    case ServerFuncBtn.container:
      AppRoute.docker(spi: spi).checkGo(
        context: context,
        check: () => _checkClient(context, spi.id),
      );
      break;
    case ServerFuncBtn.process:
      AppRoute.process(spi: spi).checkGo(
        context: context,
        check: () => _checkClient(context, spi.id),
      );
      break;
    case ServerFuncBtn.terminal:
      _gotoSSH(spi, context);
      break;
    case ServerFuncBtn.iperf:
      AppRoute.iperf(spi: spi).checkGo(
        context: context,
        check: () => _checkClient(context, spi.id),
      );
      break;
  }
}

void _gotoSSH(ServerPrivateInfo spi, BuildContext context) async {
  // run built-in ssh on macOS due to incompatibility
  if (isMobile || isMacOS) {
    AppRoute.ssh(spi: spi).go(context);
    return;
  }
  final extraArgs = <String>[];
  if (spi.port != 22) {
    extraArgs.addAll(['-p', '${spi.port}']);
  }

  final path = await () async {
    final tempKeyFileName = 'srvbox_pk_${spi.keyId}';

    /// For security reason, save the private key file to app doc path
    return joinPath(await Paths.doc, tempKeyFileName);
  }();
  final file = File(path);
  final shouldGenKey = spi.keyId != null;
  if (shouldGenKey) {
    if (await file.exists()) {
      await file.delete();
    }
    await file.writeAsString(getPrivateKey(spi.keyId!));
    extraArgs.addAll(["-i", path]);
  }

  final sshCommand = ["ssh", "${spi.user}@${spi.ip}"] + extraArgs;
  final system = OS.type;
  switch (system) {
    case OS.windows:
      await Process.start("cmd", ["/c", "start"] + sshCommand);
      break;
    case OS.linux:
      await Process.start("x-terminal-emulator", ["-e"] + sshCommand);
      break;
    default:
      context.showSnackBar('Mismatch system: $system');
  }

  if (shouldGenKey) {
    if (!await file.exists()) return;
    await Future.delayed(const Duration(seconds: 2), file.delete);
  }
}

bool _checkClient(BuildContext context, String id) {
  final server = Pros.server.pick(id: id);
  if (server == null || server.client == null) {
    context.showSnackBar(l10n.waitConnection);
    return false;
  }
  return true;
}

Future<void> _onPkg(BuildContext context, ServerPrivateInfo spi) async {
  final server = spi.server;
  if (server == null) {
    context.showSnackBar(l10n.noClient);
    return;
  }
  final sys = server.status.more[StatusCmdType.sys];
  if (sys == null) {
    context.showSnackBar(l10n.noResult);
    return;
  }
  final pkg = PkgManager.fromDist(sys.dist);

  // Update pkg list
  context.showLoadingDialog();
  final updateCmd = pkg?.update;
  if (updateCmd != null) {
    await server.client!.execWithPwd(
      updateCmd,
      context: context,
    );
  }
  context.pop();

  final listCmd = pkg?.listUpdate;
  if (listCmd == null) {
    context.showSnackBar('Unsupported dist: $sys');
    return;
  }

  // Get upgrade list
  context.showLoadingDialog();
  final result = await server.client?.run(listCmd).string;
  context.pop();
  if (result == null) {
    context.showSnackBar(l10n.noResult);
    return;
  }
  final list = pkg?.updateListRemoveUnused(result.split('\n'));
  final upgradeable = list?.map((e) => UpgradePkgInfo(e, pkg)).toList();
  if (upgradeable == null || upgradeable.isEmpty) {
    context.showSnackBar(l10n.noUpdateAvailable);
    return;
  }
  final args = upgradeable.map((e) => e.package).join(' ');
  final isSU = server.spi.user == 'root';
  final upgradeCmd = isSU ? pkg?.upgrade(args) : 'sudo ${pkg?.upgrade(args)}';

  // Confirm upgrade
  final gotoUpgrade = await context.showRoundDialog<bool>(
    title: Text(l10n.attention),
    child: SingleChildScrollView(
      child: Text('${l10n.foundNUpdate(upgradeable.length)}\n\n$upgradeCmd'),
    ),
    actions: [
      TextButton(
        onPressed: () => context.pop(true),
        child: Text(l10n.update),
      ),
    ],
  );

  if (gotoUpgrade != true) return;

  AppRoute.ssh(spi: spi, initCmd: upgradeCmd).checkGo(
    context: context,
    check: () => _checkClient(context, spi.id),
  );
}
