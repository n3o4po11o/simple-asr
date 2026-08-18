// 转写结果区：可选中复制的滚动文本 + 空态 + 自动滚到底部。
// 对齐 Swift ContentView 的 ScrollViewReader + onChange(scrollTo)。

import 'package:flutter/material.dart';

import '../proof_diff.dart';

class TranscriptView extends StatefulWidget {
  const TranscriptView({super.key, required this.text, this.diff});

  final String text;
  /// 校对成果（null = 无校准或未变化）；修改处高亮展示。
  final List<LineDiff>? diff;

  @override
  State<TranscriptView> createState() => _TranscriptViewState();
}

class _TranscriptViewState extends State<TranscriptView> {
  final _controller = ScrollController();

  @override
  void didUpdateWidget(TranscriptView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text != oldWidget.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_controller.hasClients) {
          _controller.jumpTo(_controller.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// diff 行渲染：未改行普通、修改段绿底、删除段红删除线；行间换行。
  List<InlineSpan> _lineSpans(BuildContext context, LineDiff line) {
    final theme = Theme.of(context);
    if (!line.hasChange) {
      return [TextSpan(text: '${line.newText}\n')];
    }
    return [
      for (final seg in line.spans)
        if (seg.text.isNotEmpty)
          TextSpan(
            text: seg.text,
            style: TextStyle(
              backgroundColor: seg.changed
                  ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
                  : null,
              color: seg.removed
                  ? theme.colorScheme.error.withValues(alpha: 0.7)
                  : null,
              decoration: seg.removed ? TextDecoration.lineThrough : null,
              fontWeight: seg.changed ? FontWeight.w600 : null,
            ),
          ),
      const TextSpan(text: '\n'),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: widget.text.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.chat_bubble_outline,
                    size: 40,
                    color: theme.colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '识别结果将显示在这里',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.outlineVariant,
                    ),
                  ),
                ],
              ),
            )
          : Scrollbar(
              controller: _controller,
              child: SingleChildScrollView(
                controller: _controller,
                padding: const EdgeInsets.all(12),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: widget.diff == null
                      ? SelectableText(
                          widget.text,
                          style: const TextStyle(fontSize: 15, height: 1.6),
                        )
                      : SelectableText.rich(
                          TextSpan(
                            style: const TextStyle(fontSize: 15, height: 1.7),
                            children: [
                              for (final line in widget.diff!)
                                ..._lineSpans(context, line),
                            ],
                          ),
                        ),
                ),
              ),
            ),
    );
  }
}
