import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toolbox/core/extension/context/common.dart';
import 'package:toolbox/core/extension/context/dialog.dart';
import 'package:toolbox/core/extension/context/locale.dart';
import 'package:toolbox/core/extension/context/snackbar.dart';
import 'package:toolbox/core/extension/stringx.dart';
import 'package:toolbox/core/route.dart';
import 'package:toolbox/data/model/app/menu/container.dart';
import 'package:toolbox/data/model/container/image.dart';
import 'package:toolbox/data/model/container/type.dart';
import 'package:toolbox/data/res/store.dart';
import 'package:toolbox/view/widget/expand_tile.dart';
import 'package:toolbox/view/widget/input_field.dart';

import '../../data/model/container/ps.dart';
import '../../data/model/server/server_private_info.dart';
import '../../data/provider/container.dart';
import '../../data/res/ui.dart';
import '../widget/appbar.dart';
import '../widget/popup_menu.dart';
import '../widget/cardx.dart';
import '../widget/two_line_text.dart';

class ContainerPage extends StatefulWidget {
  final ServerPrivateInfo spi;
  const ContainerPage({required this.spi, super.key});

  @override
  State<ContainerPage> createState() => _ContainerPageState();
}

class _ContainerPageState extends State<ContainerPage> {
  final _textController = TextEditingController();
  late final _container = ContainerProvider(
    client: widget.spi.server?.client,
    userName: widget.spi.user,
    hostId: widget.spi.id,
    context: context,
  );

  @override
  void dispose() {
    super.dispose();
    _textController.dispose();
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => _container,
      builder: (_, __) => Consumer<ContainerProvider>(
        builder: (_, ___, __) {
          return Scaffold(
            appBar: CustomAppBar(
              centerTitle: true,
              title: TwoLineText(up: 'Container', down: widget.spi.name),
              actions: [
                IconButton(
                  onPressed: () async {
                    context.showLoadingDialog();
                    await _container.refresh();
                    context.pop();
                  },
                  icon: const Icon(Icons.refresh),
                )
              ],
            ),
            body: _buildMain(),
            floatingActionButton: _container.error == null ? _buildFAB() : null,
          );
        },
      ),
    );
  }

  Widget _buildFAB() {
    return FloatingActionButton(
      onPressed: () async => await _showAddFAB(),
      child: const Icon(Icons.add),
    );
  }

  Widget _buildMain() {
    if (_container.error != null && _container.items == null) {
      return SizedBox.expand(
        child: Column(
          children: [
            const Spacer(),
            const Icon(
              Icons.error,
              size: 37,
            ),
            UIs.height13,
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 23),
              child: Text(_container.error?.toString() ?? l10n.unknownError),
            ),
            const Spacer(),
            _buildEditHost(),
            _buildSwitchProvider(),
            UIs.height13,
          ],
        ),
      );
    }
    if (_container.items == null || _container.images == null) {
      return UIs.centerLoading;
    }

    final items = <Widget>[
      _buildLoading(),
      _buildVersion(),
      _buildPs(),
      _buildImage(),
      _buildEditHost(),
      _buildSwitchProvider(),
    ].map((e) => CardX(child: e)).toList();
    return ListView(
      padding: const EdgeInsets.only(left: 13, right: 13, top: 13, bottom: 37),
      children: items,
    );
  }

  Widget _buildImage() {
    return ExpandTile(
      title: Text(l10n.imagesList),
      subtitle: Text(
        l10n.dockerImagesFmt(_container.images!.length),
        style: UIs.textGrey,
      ),
      initiallyExpanded: (_container.images?.length ?? 0) <= 3,
      children: _container.images?.map(_buildImageItem).toList() ?? [],
    );
  }

  Widget _buildImageItem(ContainerImg e) {
    return ListTile(
      title: Text(e.repository ?? l10n.unknown),
      subtitle: Text('${e.tag} - ${e.sizeMB}', style: UIs.textGrey),
      trailing: IconButton(
        padding: EdgeInsets.zero,
        alignment: Alignment.centerRight,
        icon: const Icon(Icons.delete),
        onPressed: () => _showImageRmDialog(e),
      ),
    );
  }

  Widget _buildLoading() {
    if (_container.runLog == null) return UIs.placeholder;
    return Padding(
      padding: const EdgeInsets.all(17),
      child: Column(
        children: [
          const Center(
            child: CircularProgressIndicator(),
          ),
          UIs.height13,
          Text(_container.runLog ?? '...'),
        ],
      ),
    );
  }

  Widget _buildVersion() {
    return Padding(
      padding: const EdgeInsets.all(17),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(_container.type.name.upperFirst),
          Text(_container.version ?? l10n.unknown),
        ],
      ),
    );
  }

  Widget _buildPs() {
    final items = _container.items;
    if (items == null) return UIs.placeholder;
    return ExpandTile(
      title: Text(l10n.containerStatus),
      subtitle: Text(
        _buildPsCardSubtitle(items),
        style: UIs.textGrey,
      ),
      initiallyExpanded: items.length <= 7,
      children: items.map(_buildPsItem).toList(),
    );
  }

  Widget _buildPsItem(ContainerPs item) {
    return ListTile(
      title: Text(item.name ?? l10n.unknown),
      subtitle: Text(
        '${item.image ?? l10n.unknown} - ${item.running ? l10n.running : l10n.stopped}',
        style: UIs.text13Grey,
      ),
      trailing: _buildMoreBtn(item),
    );
  }

  Widget _buildMoreBtn(ContainerPs dItem) {
    return PopupMenu(
      items: ContainerMenu.items(dItem.running).map((e) => e.widget).toList(),
      onSelected: (item) => _onTapMoreBtn(item, dItem),
    );
  }

  String _buildPsCardSubtitle(List<ContainerPs> running) {
    final runningCount = running.where((element) => element.running).length;
    final stoped = running.length - runningCount;
    if (stoped == 0) {
      return l10n.dockerStatusRunningFmt(runningCount);
    }
    return l10n.dockerStatusRunningAndStoppedFmt(runningCount, stoped);
  }

  Widget _buildEditHost() {
    final children = <Widget>[];
    final emptyImgs = _container.images?.isEmpty ?? false;
    final emptyPs = _container.items?.isEmpty ?? false;
    if (emptyPs && emptyImgs) {
      children.add(Padding(
        padding: const EdgeInsets.fromLTRB(17, 17, 17, 0),
        child: Text(
          l10n.dockerEmptyRunningItems,
          textAlign: TextAlign.center,
        ),
      ));
    }
    children.add(
      TextButton(
        onPressed: _showEditHostDialog,
        child: Text(l10n.dockerEditHost),
      ),
    );
    return Column(
      children: children,
    );
  }

  Widget _buildSwitchProvider() {
    late final Widget child;
    if (_container.type == ContainerType.podman) {
      child = TextButton(
        onPressed: () {
          _container.setType(ContainerType.docker);
        },
        child: Text(l10n.switchTo('Docker')),
      );
    } else {
      child = TextButton(
        onPressed: () {
          _container.setType(ContainerType.podman);
        },
        child: Text(l10n.switchTo('Podman')),
      );
    }
    return child;
  }

  Future<void> _showAddFAB() async {
    final imageCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final argsCtrl = TextEditingController();
    await context.showRoundDialog(
      title: Text(l10n.newContainer),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Input(
            autoFocus: true,
            type: TextInputType.text,
            label: l10n.image,
            hint: 'xxx:1.1',
            controller: imageCtrl,
          ),
          Input(
            type: TextInputType.text,
            controller: nameCtrl,
            label: l10n.containerName,
            hint: 'xxx',
          ),
          Input(
            type: TextInputType.text,
            controller: argsCtrl,
            label: l10n.extraArgs,
            hint: '-p 2222:22 -v ~/.xxx/:/xxx',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () async {
            context.pop();
            await _showAddCmdPreview(
              _buildAddCmd(
                imageCtrl.text.trim(),
                nameCtrl.text.trim(),
                argsCtrl.text.trim(),
              ),
            );
          },
          child: Text(l10n.ok),
        )
      ],
    );
  }

  Future<void> _showAddCmdPreview(String cmd) async {
    await context.showRoundDialog(
      title: Text(l10n.preview),
      child: Text(cmd),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () async {
            context.pop();
            context.showLoadingDialog();
            final result = await _container.run(cmd);
            context.pop();
            if (result != null) {
              context.showSnackBar(result.message ?? l10n.unknownError);
            }
          },
          child: Text(l10n.run),
        )
      ],
    );
  }

  String _buildAddCmd(String image, String name, String args) {
    var suffix = '';
    if (args.isEmpty) {
      suffix = image;
    } else {
      suffix = '$args $image';
    }
    if (name.isEmpty) {
      return 'run -itd $suffix';
    }
    return 'run -itd --name $name $suffix';
  }

  Future<void> _showEditHostDialog() async {
    final id = widget.spi.id;
    final host = Stores.docker.fetch(id);
    final ctrl = TextEditingController(text: host);
    await context.showRoundDialog(
      title: Text(l10n.dockerEditHost),
      child: Input(
        maxLines: 2,
        controller: ctrl,
        onSubmitted: _onSaveDockerHost,
        hint: 'unix:///run/user/1000/docker.sock',
      ),
      actions: [
        TextButton(
          onPressed: () => _onSaveDockerHost(ctrl.text),
          child: Text(l10n.ok),
        ),
      ],
    );
  }

  void _onSaveDockerHost(String val) {
    context.pop();
    Stores.docker.put(widget.spi.id, val.trim());
    _container.refresh();
  }

  void _showImageRmDialog(ContainerImg e) {
    context.showRoundDialog(
      title: Text(l10n.attention),
      child: Text(l10n.askContinue('${l10n.delete} Image(${e.repository})')),
      actions: [
        TextButton(
          onPressed: () => context.pop(),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () async {
            context.pop();
            final result = await _container.run('rmi ${e.id} -f');
            if (result != null) {
              context.showSnackBar(result.message ?? l10n.unknownError);
            }
          },
          child: Text(l10n.ok, style: UIs.textRed),
        ),
      ],
    );
  }

  void _onTapMoreBtn(ContainerMenu item, ContainerPs dItem) async {
    final id = dItem.id;
    if (id == null) {
      context.showSnackBar('Id is null');
      return;
    }
    switch (item) {
      case ContainerMenu.rm:
        var force = false;
        context.showRoundDialog(
          title: Text(l10n.attention),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(l10n.askContinue(
                '${l10n.delete} Container(${dItem.name})',
              )),
              UIs.height13,
              Row(
                children: [
                  StatefulBuilder(builder: (_, setState) {
                    return Checkbox(
                      value: force,
                      onChanged: (val) => setState(
                        () => force = val ?? false,
                      ),
                    );
                  }),
                  Text(l10n.force),
                ],
              )
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                context.pop();
                context.showLoadingDialog();
                final result = await _container.delete(id, force);
                context.pop();
                if (result != null) {
                  context.showRoundDialog(
                    title: Text(l10n.error),
                    child: Text(result.message ?? l10n.unknownError),
                  );
                }
              },
              child: Text(l10n.ok),
            )
          ],
        );
        break;
      case ContainerMenu.start:
        context.showLoadingDialog();
        final result = await _container.start(id);
        context.pop();
        if (result != null) {
          context.showRoundDialog(
            title: Text(l10n.error),
            child: Text(result.message ?? l10n.unknownError),
          );
        }
        break;
      case ContainerMenu.stop:
        context.showLoadingDialog();
        final result = await _container.stop(id);
        context.pop();
        if (result != null) {
          context.showRoundDialog(
            title: Text(l10n.error),
            child: Text(result.message ?? l10n.unknownError),
          );
        }
        break;
      case ContainerMenu.restart:
        context.showLoadingDialog();
        final result = await _container.restart(id);
        context.pop();
        if (result != null) {
          context.showRoundDialog(
            title: Text(l10n.error),
            child: Text(result.message ?? l10n.unknownError),
          );
        }
        break;
      case ContainerMenu.logs:
        AppRoute.ssh(
          spi: widget.spi,
          initCmd: 'docker logs -f --tail 100 ${dItem.id}',
        ).go(context);
        break;
      case ContainerMenu.terminal:
        AppRoute.ssh(
          spi: widget.spi,
          initCmd: 'docker exec -it ${dItem.id} sh',
        ).go(context);
        break;
      // case DockerMenuType.stats:
      //   showRoundDialog(
      //     context: context,
      //     title: Text(l10n.stats),
      //     child: Text(
      //       'CPU: ${dItem.cpu}\n'
      //       'Mem: ${dItem.mem}\n'
      //       'Net: ${dItem.net}\n'
      //       'Block: ${dItem.disk}',
      //     ),
      //     actions: [
      //       TextButton(
      //         onPressed: () => context.pop(),
      //         child: Text(l10n.ok),
      //       ),
      //     ],
      //   );
      //   break;
    }
  }
}
