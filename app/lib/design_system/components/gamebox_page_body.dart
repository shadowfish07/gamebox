import 'package:flutter/material.dart';

import '../generated/gamebox_tokens.g.dart';

class GameboxPageBody extends StatelessWidget {
  const GameboxPageBody({required this.children, this.footer, super.key});

  final List<Widget> children;

  /// Pinned below the scrollable list, always visible even with the keyboard
  /// open, so primary actions never fall below the visible viewport.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final list = ListView.separated(
      padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
      itemCount: children.length,
      itemBuilder: (context, index) => children[index],
      separatorBuilder: (context, index) =>
          SizedBox(height: GameboxTokens.components.sectionSpacing),
    );
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: GameboxTokens.components.pageMaxWidth,
          ),
          child: footer == null
              ? list
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: list),
                    Padding(
                      padding: EdgeInsets.all(
                        GameboxTokens.components.pagePadding,
                      ),
                      child: footer,
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
