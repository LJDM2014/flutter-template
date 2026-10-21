import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../auth/auth_api.dart';
import '../auth/auth_providers.dart';

/// 设置页：当前登录账号信息、修改昵称/密码（阶段⑧）与退出登录。
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  static const String routePath = '/settings';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(authProvider);
    final user = auth.user;
    final loggedIn = user != null;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            children: <Widget>[
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(
                            Icons.account_circle_outlined,
                            size: 20,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text('账号', style: theme.textTheme.titleSmall),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: CircleAvatar(
                          child: Text(
                            auth.displayName.isEmpty
                                ? '?'
                                : auth.displayName.characters.first
                                      .toUpperCase(),
                          ),
                        ),
                        title: Text(
                          auth.displayName.isEmpty ? '未登录' : auth.displayName,
                        ),
                        subtitle: user == null || user.username.isEmpty
                            ? null
                            : Text('@${user.username}'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('修改昵称'),
                subtitle: const Text('1-24 个字符，修改后全端生效'),
                enabled: loggedIn,
                onTap: () => _editNickname(context, ref, auth.displayName),
              ),
              ListTile(
                leading: const Icon(Icons.password_outlined),
                title: const Text('修改密码'),
                subtitle: const Text('修改后其他设备需重新登录'),
                enabled: loggedIn,
                onTap: () => _editPassword(context, ref),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: loggedIn
                    ? () async {
                        await ref.read(authProvider.notifier).signOut();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context)
                            ..hideCurrentSnackBar()
                            ..showSnackBar(
                              const SnackBar(content: Text('已退出登录')),
                            );
                        }
                      }
                    : null,
                icon: const Icon(Icons.logout),
                label: const Text('退出登录'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 修改昵称对话框：成功后更新状态（AppBar/头像等随 authProvider 刷新）。
  Future<void> _editNickname(
    BuildContext context,
    WidgetRef ref,
    String current,
  ) async {
    final controller = TextEditingController(text: current);
    final updated = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 24,
          decoration: const InputDecoration(
            labelText: '新昵称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final nickname = controller.text.trim();
              if (nickname.isEmpty) {
                return;
              }
              try {
                await ref.read(authProvider.notifier).changeNickname(nickname);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(true);
                }
              } on AuthApiException catch (error) {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(SnackBar(content: Text(error.message)));
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (updated == true && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('昵称已更新')));
    }
  }

  /// 修改密码对话框：旧密码 + 新密码 + 确认，成功提示其他设备需重登。
  Future<void> _editPassword(BuildContext context, WidgetRef ref) async {
    final oldController = TextEditingController();
    final newController = TextEditingController();
    final confirmController = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final updated = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('修改密码'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                controller: oldController,
                autofocus: true,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '当前密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    (value == null || value.isEmpty) ? '请输入当前密码' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: newController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '新密码（至少 8 位）',
                  border: OutlineInputBorder(),
                ),
                validator: AuthValidators.password,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: confirmController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: '确认新密码',
                  border: OutlineInputBorder(),
                ),
                validator: (value) =>
                    value != newController.text ? '两次输入的新密码不一致' : null,
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              if (formKey.currentState?.validate() != true) {
                return;
              }
              try {
                await ref
                    .read(authProvider.notifier)
                    .changePassword(
                      oldPassword: oldController.text,
                      newPassword: newController.text,
                    );
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop(true);
                }
              } on AuthApiException catch (error) {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(
                    dialogContext,
                  ).showSnackBar(SnackBar(content: Text(error.message)));
                }
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (updated == true && context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('密码已更新，其他设备需重新登录')));
    }
  }
}
