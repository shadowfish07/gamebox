import 'package:flutter/material.dart';

import '../generated/gamebox_tokens.g.dart';

class GameboxPendingButton extends StatelessWidget {
  const GameboxPendingButton({
    required this.identifier,
    required this.label,
    required this.pendingLabel,
    this.isPending = false,
    this.onPressed,
    super.key,
  });

  final String identifier;
  final String label;
  final String pendingLabel;
  final bool isPending;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      identifier: identifier,
      child: FilledButton(
        onPressed: isPending ? null : onPressed,
        child: isPending
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: GameboxTokens.components.smallProgressSize,
                    child: const CircularProgressIndicator(),
                  ),
                  SizedBox(width: GameboxTokens.spacing.compact),
                  Text(pendingLabel),
                ],
              )
            : Text(label),
      ),
    ),
  );
}
