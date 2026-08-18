// 校对播放栏：播放控制 + 时间码 + 剪辑式波形时间轴（点击/拖动跳转，
// 播放进度画布高亮，说话人分段着色刻度）。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../native_api.dart';

class PlayerBar extends StatelessWidget {
  const PlayerBar({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dur = model.durationSec > 0 ? model.durationSec : 1.0;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        children: [
          IconButton.filled(
            onPressed: model.togglePlay,
            icon: Icon(
              model.isPlaying ? Icons.pause : Icons.play_arrow,
              size: 26,
            ),
            tooltip: model.isPlaying ? '暂停' : '播放',
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 68,
            child: Text(
              '${fmtClock(model.positionSec)} / ${fmtClock(model.durationSec)}',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 4),
          // 倍速
          PopupMenuButton<double>(
            initialValue: model.playbackRate,
            onSelected: model.setPlaybackRate,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 0.5, child: Text('0.5x')),
              PopupMenuItem(value: 0.75, child: Text('0.75x')),
              PopupMenuItem(value: 1.0, child: Text('1.0x')),
              PopupMenuItem(value: 1.5, child: Text('1.5x')),
              PopupMenuItem(value: 2.0, child: Text('2.0x')),
              PopupMenuItem(value: 3.0, child: Text('3.0x')),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: theme.colorScheme.outlineVariant),
              ),
              child: Text('${model.playbackRate}x',
                  style: theme.textTheme.bodySmall),
            ),
          ),
          IconButton(
            onPressed: model.toggleLoop,
            icon: Icon(
              model.loopEnabled ? Icons.repeat_one : Icons.repeat,
              size: 20,
            ),
            color: model.loopEnabled
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
            tooltip: model.loopEnabled
                ? '区段循环中（拖选波形定区间，点此关闭）'
                : '开启区段循环（在波形上拖选区间）',
          ),
          const SizedBox(width: 4),
          const SizedBox(width: 8),
          Expanded(child: _WaveTimeline(model: model, duration: dur)),
        ],
      ),
    );
  }
}

/// 波形时间轴：峰值绘制 + 播放进度着色 + 说话人刻度 + 点击/拖动跳转。
class _WaveTimeline extends StatefulWidget {
  const _WaveTimeline({required this.model, required this.duration});

  final AppModel model;
  final double duration;

  @override
  State<_WaveTimeline> createState() => _WaveTimelineState();
}

class _WaveTimelineState extends State<_WaveTimeline> {
  double? _selStartDx;

  double _dxToSec(double dx, double width) =>
      (dx / width * widget.duration).clamp(0.0, widget.duration);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final model = widget.model;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return MouseRegion(
          cursor: model.loopEnabled
              ? SystemMouseCursors.precise
              : SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              model.exitProofEditing(); // 点击波形=非文本交互，退出编辑保住快捷键
              if (!model.loopEnabled) {
                model.seekTo(_dxToSec(d.localPosition.dx, width));
                return;
              }
              // 循环开启时点击：定位到已有区段（无区段则从点击处起 3 秒）
              if (model.loopStart == null || model.loopEnd == null) {
                final s = _dxToSec(d.localPosition.dx, width);
                model.setLoopRegion(s, s + 3.0);
                model.seekTo(s);
              } else {
                final t = _dxToSec(d.localPosition.dx, width);
                model.seekTo(t.clamp(model.loopStart!, model.loopEnd! - 0.1));
              }
            },
            // 循环开启：拖选定义区段；关闭：拖动跳转
            onHorizontalDragStart: (d) {
              model.exitProofEditing();
              if (model.loopEnabled) {
                _selStartDx = d.localPosition.dx;
              } else {
                model.seekTo(_dxToSec(d.localPosition.dx, width));
              }
            },
            onHorizontalDragUpdate: model.loopEnabled && _selStartDx != null
                ? (d) => model.setLoopRegion(
                      _dxToSec(_selStartDx!, width),
                      _dxToSec(d.localPosition.dx, width),
                    )
                : (!model.loopEnabled
                    ? (d) =>
                        model.seekTo(_dxToSec(d.localPosition.dx, width))
                    : null),
            onHorizontalDragEnd: (_) => _selStartDx = null,
            child: CustomPaint(
              size: Size(width, 56),
              painter: _WavePainter(
                peaks: widget.model.wavePeaks,
                progress: widget.duration > 0
                    ? widget.model.positionSec / widget.duration
                    : 0.0,
                played: theme.colorScheme.primary,
                unplayed: theme.colorScheme.outlineVariant,
                cursor: theme.colorScheme.onSurface,
                loopStart: model.loopEnabled && model.loopStart != null
                    ? model.loopStart! / widget.duration
                    : null,
                loopEnd: model.loopEnabled && model.loopEnd != null
                    ? model.loopEnd! / widget.duration
                    : null,
                loopColor: theme.colorScheme.tertiary,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.peaks,
    required this.progress,
    required this.played,
    required this.unplayed,
    required this.cursor,
    this.loopStart,
    this.loopEnd,
    required this.loopColor,
  });

  final List<double> peaks;
  final double progress;
  final Color played;
  final Color unplayed;
  final Color cursor;
  final double? loopStart;
  final double? loopEnd;
  final Color loopColor;

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final mid = h / 2;
    final playedX = size.width * progress.clamp(0.0, 1.0);
    final barW = math.max(1.0, size.width / math.max(1, peaks.length));
    final paintPlayed = Paint()..color = played;
    final paintUnplayed = Paint()..color = unplayed;
    for (var i = 0; i < peaks.length; i++) {
      final x = i * barW;
      final amp = (peaks[i] * (h / 2 - 2)).clamp(1.0, h / 2 - 2);
      final p = x + barW / 2 <= playedX ? paintPlayed : paintUnplayed;
      canvas.drawRect(Rect.fromLTRB(x, mid - amp, x + barW - 1, mid + amp), p);
    }
    // 循环区段覆盖（半透明带 + 边界线）
    final ls = loopStart, le = loopEnd;
    if (ls != null && le != null && le > ls) {
      final x1 = size.width * ls.clamp(0.0, 1.0);
      final x2 = size.width * le.clamp(0.0, 1.0);
      canvas.drawRect(
        Rect.fromLTRB(x1, 0, x2, h),
        Paint()..color = loopColor.withValues(alpha: 0.22),
      );
      final edge = Paint()
        ..color = loopColor
        ..strokeWidth = 1.5;
      canvas.drawLine(Offset(x1, 0), Offset(x1, h), edge);
      canvas.drawLine(Offset(x2, 0), Offset(x2, h), edge);
    }
    // 播放光标
    final cursorPaint = Paint()
      ..color = cursor
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(playedX, 0), Offset(playedX, h), cursorPaint);
  }

  @override
  bool shouldRepaint(_WavePainter old) =>
      old.peaks != peaks ||
      old.progress != progress ||
      old.loopStart != loopStart ||
      old.loopEnd != loopEnd;
}
