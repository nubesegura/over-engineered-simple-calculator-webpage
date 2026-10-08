import 'package:flutter/material.dart';

import '../constants.dart';
import 'session_controller.dart';

/// Email and password form shown while there is no session.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.session});

  final SessionController session;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (email.isEmpty || _password.text.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    final ok = await widget.session.login(email, _password.text);
    if (!mounted) return;
    setState(() {
      _submitting = false;
      if (!ok) _password.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final session = widget.session;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Over-Engineered Calculator'),
        backgroundColor: colors.primary,
        foregroundColor: colors.onPrimary,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: ListenableBuilder(
              listenable: session,
              builder: (context, _) => Column(
                children: [
                  TextField(
                    key: const Key('login-email-field'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    enabled: !_submitting,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('login-password-field'),
                    controller: _password,
                    obscureText: true,
                    enableSuggestions: false,
                    autocorrect: false,
                    enabled: !_submitting,
                    decoration: const InputDecoration(labelText: 'Password'),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('login-submit'),
                    onPressed: _submitting ? null : _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            key: Key('login-progress'),
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Log in', style: TextStyle(fontSize: 18)),
                  ),
                  if (session.message != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      session.message!,
                      key: const Key('login-message'),
                      style: TextStyle(color: colors.error),
                      textAlign: TextAlign.center,
                    ),
                  ],
                  if (session.canRetryRestore)
                    TextButton(
                      key: const Key('login-retry'),
                      onPressed: session.restore,
                      child: const Text('Try again'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown instead of the login screen where there is no BFF (the desktop build).
class WebOnlyPage extends StatelessWidget {
  const WebOnlyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            AuthConstants.webOnlyMessage,
            key: Key('web-only-message'),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
