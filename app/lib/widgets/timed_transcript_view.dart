// 校对视图：歌词式时间轴行——当前播放行高亮 + 自动滚动跟随 + 点行跳转 +
// 行内编辑文本 + 说话人标签（点击换行归属 / 重命名）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_state.dart';
import '../native_api.dart';

/// 回车拆行：拦截换行符插入，改为在该位置触发拆行（时间按字符比例拆分，
/// 后半行挂下一个人标签）。换行本身不进入文本。
class _EnterSplitFormatter extends TextInputFormatter {
  _EnterSplitFormatter(this.onEnterAt);

  final void Function(int charPos) onEnterAt;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (!newValue.text.contains('\n')) {
      return newValue;
    }
    final utf16Pos = newValue.text.indexOf('\n');
    // 字符位置按编辑器当前文本换算（防抖未落盘时模型文本可能滞后）
    final charPos =
        _charPosFromUtf16(newValue.text.substring(0, utf16Pos), utf16Pos);
    // 拒绝换行插入；微任务里走拆行（避免在文本编辑管线内改状态）
    scheduleMicrotask(() => onEnterAt(charPos));
    return oldValue;
  }
}

/// UTF-16 偏移 → Unicode 字符数（Rust 按字符数切分；BMP 汉字两者一致，
/// 含 emoji（代理对）时需转换）。
int _charPosFromUtf16(String text, int utf16Offset) {
  var units = 0, chars = 0;
  for (final r in text.runes) {
    if (units >= utf16Offset) break;
    units += r > 0xFFFF ? 2 : 1;
    chars++;
  }
  return chars;
}


class TimedTranscriptView extends StatefulWidget {
  const TimedTranscriptView({super.key, required this.model});

  final AppModel model;

  @override
  State<TimedTranscriptView> createState() => _TimedTranscriptViewState();
}

class _TimedTranscriptViewState extends State<TimedTranscriptView> {
  final _scroll = ScrollController();
  /// 行键必须跨构建稳定（曾每次 build 新建 GlobalKey → TextField 元素
  /// 被重建、焦点丢失，用户改一个字光标就没了）。按索引缓存。
  final _lineKeys = <int, GlobalKey>{};
  final _controllers = <int, TextEditingController>{};
  final _focusNodes = <int, FocusNode>{};
  final _rootFocus = FocusNode();
  /// 上次滚动定位到的行（新旧 widget 共享同一 model 实例，
  /// didUpdateWidget 里比较 old.model 恒等——必须用状态内变量记变化）。
  int? _lastFollowedIdx;
  /// 上次见到的撤销纪元（undo 恢复行内容/锚点——行数可能不变，
  /// 必须靠纪元强制重建控制器，否则 TextField 显示撤销前的文本）。
  int _lastEpoch = 0;
  /// 上次见到的行数（新旧 widget 共享同一 model 实例，didUpdateWidget
  /// 里比较 old.model 恒等——行数变化必须用状态内变量记，否则拆行后
  /// 按索引缓存的 controller 错位一行：新行显示的是原下一行的文本）。
  int _lastLineCount = -1;

FocusNode _focusNodeFor(int i) => _focusNodes.putIfAbsent(i, () {
      final n = FocusNode(
        onKeyEvent: (node, event) {
          // 回车拆行不依赖平台 IME 插入 '\n'（物理回车在 macOS 上不走
          // updateEditingValue，formatter 收不到），在焦点节点上直接拦截：
          // 光标位置换算字符数后走 splitLine。IME 组词中的回车让位输入法。
          if (event is! KeyDownEvent ||
              event is KeyRepeatEvent ||
              event.logicalKey != LogicalKeyboardKey.enter) {
            return KeyEventResult.ignored;
          }
          final c = _controllers[i];
          if (c != null && c.value.composing != TextRange.empty) {
            return KeyEventResult.ignored;
          }
          final text = c?.value.text ?? '';
          var utf16 = c?.selection.baseOffset ?? text.length;
          if (utf16 < 0 || utf16 > text.length) utf16 = text.length;
          widget.model
              .splitLine(i, _charPosFromUtf16(text.substring(0, utf16), utf16));
          return KeyEventResult.handled;
        },
      );
      n.addListener(() => widget.model.setProofEditing(n.hasFocus));
      return n;
    });

  GlobalKey _lineKeyFor(int i) => _lineKeys.putIfAbsent(i, GlobalKey.new);

  /// 行编辑控制器（按行缓存；仅用户输入触发回写，避免回环）。
  TextEditingController _controllerFor(int i, String initial) {
    final existing = _controllers[i];
    if (existing != null) return existing;
    final c = TextEditingController(text: initial);
    c.addListener(() {
      if (c.value.composing != TextRange.empty) return;
      if (i >= widget.model.proofLines.length) return;
      if (c.value.text != widget.model.proofLines[i].text) {
        widget.model.editLineText(i, c.value.text);
      }
    });
    _controllers[i] = c;
    return c;
  }

  void _followActive(int? prevIdx) {
    final idx = widget.model.activeLineIdx;
    // 用状态内记录比较（同一 model 实例的新旧比较恒等，永远检测不到变化）
    if (idx < 0 || idx == _lastFollowedIdx) return;
    _lastFollowedIdx = idx;
    final ctx = _lineKeys[idx]?.currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      alignment: 0.3, // 当前行保持在视口上部 30%（歌词式）
      duration: const Duration(milliseconds: 250),
    );
  }

  @override
  void didUpdateWidget(TimedTranscriptView old) {
    super.didUpdateWidget(old);
    // 行数变化（拆行）或撤销恢复（纪元变化）→ 按索引缓存的
    // controller/focus/key 全部错位或过时，全量重建（惰性按需创建）；
    // 拆行把焦点送到新行（光标置开头），撤销保持原聚焦行。
    final epochChanged = widget.model.proofEpoch != _lastEpoch;
    _lastEpoch = widget.model.proofEpoch;
    final linesChanged =
        widget.model.proofLines.length != _lastLineCount;
    _lastLineCount = widget.model.proofLines.length;
    if (linesChanged || epochChanged) {
      int? focused;
      for (final e in _focusNodes.entries) {
        if (e.value.hasFocus) {
          focused = e.key;
          break;
        }
      }
      for (final c in _controllers.values) {
        c.dispose();
      }
      for (final f in _focusNodes.values) {
        f.dispose();
      }
      _controllers.clear();
      _focusNodes.clear();
      _lineKeys.clear();
      _lastFollowedIdx = null;
      final target = widget.model.focusSplitLineAt ??
          (epochChanged ? focused : null);
      if (target != null && target < widget.model.proofLines.length) {
        widget.model.focusSplitLineAt = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _focusNodeFor(target).requestFocus();
          final c = _controllers[target];
          if (c != null) {
            c.selection = const TextSelection.collapsed(offset: 0);
          }
        });
      }
    }
    _followActive(_lastFollowedIdx);
  }

  @override
  void dispose() {
    if (widget.model.requestProofFocus == _rootFocus.requestFocus) {
      widget.model.requestProofFocus = null;
    }
    _scroll.dispose();
    _rootFocus.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focusNodes.values) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 键盘交互（非编辑态）：空格=播放/暂停，←/→=±5s，i=编辑当前行，
    // ESC=退出编辑；Cmd/Ctrl+Z=撤销校准操作（两态共用；编辑态下 TextField
    // 内置的单行 undo 栈空时按键自然穿透到这层）。
    // 编辑态除 ESC/撤销外不注册：CallbackShortcuts 匹配到键即消费（即使
    // 回调因 proofEditing 空转），macOS 的字符插入走平台 IME 通道、拿不到
    // 已被消费的按键——空格/方向键/字母 i 曾因此在编辑态全部打不出。
    final model = widget.model;
    final undo = model.undoProofEdit;
    final undoBindings = <SingleActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): undo,
      const SingleActivator(LogicalKeyboardKey.keyZ, control: true): undo,
    };
    final editing = model.proofEditing;
    return CallbackShortcuts(
      bindings: editing
          ? {
              const SingleActivator(LogicalKeyboardKey.escape): _exitEdit,
              ...undoBindings,
            }
          : {
              const SingleActivator(LogicalKeyboardKey.escape): _exitEdit,
              const SingleActivator(LogicalKeyboardKey.space):
                  model.togglePlay,
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () => model
                  .seekTo((model.positionSec - 5)
                      .clamp(0, double.infinity)),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  model.seekTo(model.positionSec + 5),
              const SingleActivator(LogicalKeyboardKey.keyI): _focusActiveLine,
              ...undoBindings,
            },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        child: _scrollBody(),
      ),
    );
  }

  void _exitEdit() {
    widget.model.setProofEditing(false);
    FocusManager.instance.primaryFocus?.unfocus();
    _rootFocus.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    widget.model.requestProofFocus = _rootFocus.requestFocus;
    _lastLineCount = widget.model.proofLines.length;
  }

  /// i 键：聚焦当前播放行的输入框，光标置于末尾。
  void _focusActiveLine() {
    final idx = widget.model.activeLineIdx;
    if (idx < 0 || idx >= widget.model.proofLines.length) return;
    _focusNodeFor(idx).requestFocus();
    final c = _controllers[idx];
    if (c != null) {
      c.selection = TextSelection.collapsed(offset: c.text.length);
    }
  }

  Widget _scrollBody() {
    final theme = Theme.of(context);
    final lines = widget.model.proofLines;
    final active = widget.model.activeLineIdx;
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < lines.length; i++)
            _buildLine(theme, lines[i], i == active, i),
        ],
      ),
    );
  }

  Widget _buildLine(ThemeData theme, TranscriptLine line, bool isActive, int i) {
    final key = _lineKeyFor(i);
    final speakerColor = line.speaker == null
        ? null
        : [theme.colorScheme.primary, theme.colorScheme.tertiary][
            line.speaker!.hashCode % 2];

    return InkWell(
      key: key,
      onTap: () => widget.model.seekTo(line.startSec),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isActive
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 66,
              child: Text(
                fmtClock(line.startSec),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isActive
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                  fontFeatures: [const FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (line.speaker != null)
              _SpeakerChip(
                model: widget.model,
                lineIdx: i,
                color: speakerColor,
              ),
            Expanded(
              child: TextField(
                controller: _controllerFor(i, line.text),
                focusNode: _focusNodeFor(i),
                inputFormatters: [
                  _EnterSplitFormatter(
                    (charPos) => widget.model.splitLine(i, charPos),
                  ),
                ],
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.35,
                  color:
                      isActive ? theme.colorScheme.onPrimaryContainer : null,
                  fontWeight: isActive ? FontWeight.w600 : null,
                ),
                maxLines: null,
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 说话人标签：点开菜单——换本行说话人（diar 修正）/ 重命名（全局生效）。
class _SpeakerChip extends StatefulWidget {
  const _SpeakerChip({
    required this.model,
    required this.lineIdx,
    this.color,
  });

  final AppModel model;
  final int lineIdx;
  final Color? color;

  @override
  State<_SpeakerChip> createState() => _SpeakerChipState();
}

class _SpeakerChipState extends State<_SpeakerChip> {
  _SpeakerChip get _w => widget;

  @override
  Widget build(BuildContext ctx) {
    final theme = Theme.of(ctx);
    final spk = _w.model.proofLines[_w.lineIdx].speaker!;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final box = ctx.findRenderObject() as RenderBox;

        final overlay = Overlay.of(ctx).context.findRenderObject() as RenderBox;
        final pos = overlay.globalToLocal(
          box.localToGlobal(Offset(0, box.size.height)),
        );
        final v = await showMenu<String>(
          context: ctx,
          position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 80, 0),
          items: [
            for (final id in _w.model.speakerIds)
              PopupMenuItem(
                value: 'spk:$id',
                child: Text(
                  '${_w.model.speakerLabel(id)}${id == spk ? '（当前）' : ''}',
                  style: TextStyle(
                    fontWeight: id == spk ? FontWeight.w700 : null,
                  ),
                ),
              ),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'none', child: Text('无说话人')),
            const PopupMenuItem(value: 'rename', child: Text('重命名此说话人…')),
          ],
        );
        if (v == null) return;
        if (v == 'rename') {
          final controller =
              TextEditingController(text: _w.model.speakerLabel(spk));
          if (!mounted) return;
          final name = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text('重命名 ${_w.model.speakerLabel(spk)}'),
              content: TextField(
                controller: controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: '如：客服 / 顾客'),
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
            await _w.model.renameSpeaker(spk, name);
          }
          return;
        }
        if (v == 'none') {
          await _w.model.setLineSpeaker(_w.lineIdx, null);
          return;
        }
        if (v.startsWith('spk:')) {
          await _w.model.setLineSpeaker(_w.lineIdx, v.substring(4));
        }
      },
      child: Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: _w.color?.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _w.model.speakerLabel(spk),
              style: theme.textTheme.bodySmall?.copyWith(color: _w.color),
            ),
            Icon(Icons.arrow_drop_down, size: 14, color: _w.color),
          ],
        ),
      ),
    );
  }
}
