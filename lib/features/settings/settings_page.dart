import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/app_paths.dart';
import 'nickname_provider.dart';

/// 设置页：编辑并保存昵称（阶段② 将追加服务器相关配置）。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  static const String routePath = AppPaths.settings;

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('昵称不能为空')));
      return;
    }
    ref.read(nicknameProvider.notifier).save(text);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('已保存昵称：$text')));
  }

  @override
  Widget build(BuildContext context) {
    // 异步加载完成后，把当前昵称回填到输入框（仅在输入框为空时）。
    ref.listen<AsyncValue<String?>>(nicknameProvider, (_, next) {
      final value = next.value;
      if (value != null && _controller.text.isEmpty) {
        _controller.text = value;
      }
    });
    final nickname = ref.watch(nicknameProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            children: <Widget>[
              TextField(
                controller: _controller,
                decoration: const InputDecoration(
                  labelText: '昵称',
                  hintText: '局域网内展示的名字',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person_outline),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_outlined),
                label: const Text('保存'),
              ),
              const SizedBox(height: 8),
              nickname.when(
                loading: () => const SizedBox.shrink(),
                error: (error, _) => Text(
                  '读取昵称失败：$error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
                data: (value) => value == null
                    ? const SizedBox.shrink()
                    : Text('当前昵称：$value',
                        style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
