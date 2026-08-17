// 校准模式说话人管理条：进入手动校准即列出全部说话人，
// 点击标签直接重命名（如「消费者」「商家」），全局生效。

import 'package:flutter/material.dart';

import '../app_state.dart';

class SpeakerBar extends StatelessWidget {
  const SpeakerBar({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ids = model.speakerIds;
    if (ids.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.people_outline,
              size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final id in ids) _chip(context, theme, id),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, ThemeData theme, String id) {
    final color = id.hashCode % 2 == 0
        ? theme.colorScheme.primary
        : theme.colorScheme.tertiary;
    return ActionChip(
      avatar: Icon(Icons.edit, size: 12, color: color),
      label: Text(model.speakerLabel(id)),
      labelStyle: theme.textTheme.bodySmall?.copyWith(color: color),
      backgroundColor: color.withValues(alpha: 0.1),
      onPressed: () async {
        final controller =
            TextEditingController(text: model.speakerLabel(id));
        final ctx2 = context;
        final name = await showDialog<String>(
          context: ctx2,
          builder: (ctx) => AlertDialog(
            title: Text('重命名 ${model.speakerLabel(id)}'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration:
                  const InputDecoration(hintText: '如：消费者 / 商家 / 客服'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, controller.text.trim()),
                child: const Text('确定'),
              ),
            ],
          ),
        );
        if (name != null && name.isNotEmpty) {
          await model.renameSpeaker(id, name);
        }
      },
    );
  }
}
