import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/constants.dart';
import '../../shared/app_paths.dart';
import '../connection/connection_providers.dart';
import 'auth_api.dart';
import 'auth_providers.dart';

/// 登录/注册共用表单骨架：服务器地址 + 表单字段 + 提交。
///
/// 登录与注册仅差表单字段与提交回调，抽公用组件减少重复。
class AuthFormScaffold extends ConsumerStatefulWidget {
  const AuthFormScaffold({super.key, required this.isRegister});

  final bool isRegister;

  @override
  ConsumerState<AuthFormScaffold> createState() => _AuthFormScaffoldState();
}

class _AuthFormScaffoldState extends ConsumerState<AuthFormScaffold> {
  final _formKey = GlobalKey<FormState>();
  final _addressController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nicknameController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAddress());
  }

  @override
  void dispose() {
    _addressController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  /// 地址预填：上次使用的地址；为空时自动发现。
  Future<void> _loadAddress() async {
    final prefs = await SharedPreferences.getInstance();
    var saved = prefs.getString(AppConstants.prefKeyServerHost) ?? '';
    if (saved.isEmpty && mounted) {
      final resolved = await ref
          .read(connectionProvider.notifier)
          .autoResolveAddress();
      if (resolved != null) {
        saved = resolved.port == AppConstants.defaultPort
            ? resolved.host
            : '${resolved.host}:${resolved.port}';
      }
    }
    if (saved.isNotEmpty && mounted) {
      setState(() => _addressController.text = saved);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final controller = ref.read(authProvider.notifier);
      if (widget.isRegister) {
        await controller.register(
          address: _addressController.text,
          username: _usernameController.text.trim(),
          password: _passwordController.text,
          nickname: _nicknameController.text.trim(),
        );
      } else {
        await controller.login(
          address: _addressController.text,
          username: _usernameController.text.trim(),
          password: _passwordController.text,
        );
      }
      if (mounted) {
        // 登录即连接（阶段⑤）：认证状态变化会触发自动连接，直达消息页。
        context.go(AppPaths.chat);
      }
    } on AuthApiException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = '服务不可达，请检查服务器地址');
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.isRegister ? '注册账号' : '登录';
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: ListView(
            padding: const EdgeInsets.all(16),
            shrinkWrap: true,
            children: <Widget>[
              Text(
                widget.isRegister ? '创建账号后即可与局域网用户实时对话' : '登录账号以接入局域网中继服务',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextFormField(
                      controller: _addressController,
                      decoration: const InputDecoration(
                        labelText: '服务器地址',
                        hintText: '例如 192.168.1.100:9090',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.dns_outlined),
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? '请输入服务器地址' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _usernameController,
                      decoration: const InputDecoration(
                        labelText: '用户名',
                        hintText: '3-24 位字母、数字或下划线',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      validator: AuthValidators.username,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(
                        labelText: '密码',
                        hintText: '至少 8 位',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.lock_outline),
                      ),
                      obscureText: true,
                      textInputAction: widget.isRegister
                          ? TextInputAction.next
                          : TextInputAction.done,
                      validator: AuthValidators.password,
                      onFieldSubmitted: widget.isRegister
                          ? null
                          : (_) => unawaited(_submit()),
                    ),
                    if (widget.isRegister) ...<Widget>[
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _nicknameController,
                        decoration: const InputDecoration(
                          labelText: '昵称（可选）',
                          hintText: '聊天中展示的名字，缺省同用户名',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                        textInputAction: TextInputAction.done,
                        validator: AuthValidators.nickname,
                        onFieldSubmitted: (_) => unawaited(_submit()),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(widget.isRegister ? '注册并登录' : '登录'),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => context.go(
                  widget.isRegister
                      ? LoginPage.routePath
                      : RegisterPage.routePath,
                ),
                child: Text(widget.isRegister ? '已有账号？去登录' : '没有账号？去注册'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 登录页（/login）。
class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  static const String routePath = AppPaths.login;

  @override
  Widget build(BuildContext context) =>
      const AuthFormScaffold(isRegister: false);
}

/// 注册页（/register）。
class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key});

  static const String routePath = AppPaths.register;

  @override
  Widget build(BuildContext context) =>
      const AuthFormScaffold(isRegister: true);
}
