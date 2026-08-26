import 'package:flutter/material.dart';

import '../generated/gamebox_tokens.g.dart';

class GameboxAsyncPanel extends StatelessWidget {
  const GameboxAsyncPanel({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
    this.isLoading = false,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: GameboxTokens.components.minimumTouchTarget,
              child: Center(
                child: isLoading
                    ? SizedBox.square(
                        dimension: GameboxTokens.components.smallProgressSize,
                        child: const CircularProgressIndicator(),
                      )
                    : Icon(
                        icon,
                        size: GameboxTokens.spacing.large,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
              ),
            ),
            SizedBox(height: GameboxTokens.spacing.compact),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            SizedBox(height: GameboxTokens.spacing.layout),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            SizedBox(height: GameboxTokens.spacing.page),
            SizedBox(
              height: GameboxTokens.components.minimumTouchTarget,
              child: !isLoading && actionLabel != null
                  ? FilledButton(onPressed: onAction, child: Text(actionLabel!))
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}
