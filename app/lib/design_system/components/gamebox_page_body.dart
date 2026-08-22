import 'package:flutter/material.dart';

import '../generated/gamebox_tokens.g.dart';

class GameboxPageBody extends StatelessWidget {
  const GameboxPageBody({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: GameboxTokens.components.pageMaxWidth,
        ),
        child: ListView.separated(
          padding: EdgeInsets.all(GameboxTokens.components.pagePadding),
          itemCount: children.length,
          itemBuilder: (context, index) => children[index],
          separatorBuilder: (context, index) =>
              SizedBox(height: GameboxTokens.components.sectionSpacing),
        ),
      ),
    ),
  );
}
