// 校对 diff：进入校准时快照行原文，退出时与编辑后行对行比较，
// 前后缀收缩聚焦修改段（O(n)，行同源同序不重排，无需完整 LCS）。

/// 行内 diff 片段：未改动（plain）或修改/新增（changed）。
class DiffSpan {
  const DiffSpan(this.text, {this.changed = false, this.removed = false});

  final String text;
  /// 修改/新增内容（校准后文本里的新写法，绿色高亮）。
  final bool changed;
  /// 被删除的原文（红色删除线内联显示，标记删了什么）。
  final bool removed;
}

/// 一行的 diff：oldText → newText 的可视化片段。
/// changed 为 true 的片段即用户校对修改过的位置。
class LineDiff {
  LineDiff(this.oldText, this.newText, this.spans);

  final String oldText;
  final String newText;
  final List<DiffSpan> spans;

  bool get hasChange => oldText != newText;
}

/// 行级 diff：先用 LCS 锚定未变行（拆行/删行会改变行数，同索引比较
/// 会把后续行全部错位成 diff——用户只拆了一行，退出时满屏痕迹），
/// 剩余变化段内按顺序配对做行内前后缀收缩，多出的旧行纯删除、
/// 新行纯新增。
List<LineDiff> diffLines(List<String> oldLines, List<String> newLines) {
  // LCS DP：old[i..] 与 new[j..] 的最长公共子序列长度（行相等才配对）。
  // 行数百级 + 退出校准一次性计算，O(n·m) 足够。
  final n = oldLines.length, m = newLines.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      dp[i][j] = oldLines[i] == newLines[j]
          ? dp[i + 1][j + 1] + 1
          : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
    }
  }
  // 回溯得到锚定配对（old i ↔ new j；两侧游标按 LCS 跳过非锚行）
  final pairs = <(int, int)>[];
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (oldLines[i] == newLines[j]) {
      pairs.add((i, j));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  // 锚点把两侧切成对应的变化段；段内 zip 配对做行内 diff，
  // 多出的旧行纯删除（红删除线）、新行纯新增（绿高亮）。
  final result = <LineDiff>[];
  var oi = 0, nj = 0;
  void emitSegment(int endOld, int endNew) {
    for (var k = 0; oi + k < endOld || nj + k < endNew; k++) {
      final hasOld = oi + k < endOld, hasNew = nj + k < endNew;
      if (hasOld && hasNew) {
        result.add(_diffOne(oldLines[oi + k], newLines[nj + k]));
      } else if (hasOld) {
        result.add(LineDiff(oldLines[oi + k], '',
            [DiffSpan(oldLines[oi + k], removed: true)]));
      } else {
        result.add(LineDiff('', newLines[nj + k],
            [DiffSpan(newLines[nj + k], changed: true)]));
      }
    }
  }

  for (final (a, b) in pairs) {
    emitSegment(a, b);
    result.add(LineDiff(oldLines[a], newLines[b], [DiffSpan(newLines[b])]));
    oi = a + 1;
    nj = b + 1;
  }
  emitSegment(n, m);
  return result;
}

LineDiff _diffOne(String old, String neu) {
  if (old == neu) {
    return LineDiff(old, neu, [DiffSpan(neu)]);
  }
  final oc = old.runes.toList();
  final nc = neu.runes.toList();
  var pre = 0;
  while (pre < oc.length && pre < nc.length && oc[pre] == nc[pre]) {
    pre++;
  }
  var suf = 0;
  while (suf < oc.length - pre &&
      suf < nc.length - pre &&
      oc[oc.length - 1 - suf] == nc[nc.length - 1 - suf]) {
    suf++;
  }
  final spans = <DiffSpan>[];
  if (pre > 0) {
    spans.add(DiffSpan(String.fromCharCodes(oc.sublist(0, pre))));
  }
  // 被删的原文（红删除线）与新写法（绿高亮）都展示
  final delMid =
      String.fromCharCodes(oc.sublist(pre, oc.length - suf));
  final newMid =
      String.fromCharCodes(nc.sublist(pre, nc.length - suf));
  if (delMid.isNotEmpty) {
    spans.add(DiffSpan(delMid, removed: true));
  }
  if (newMid.isNotEmpty) {
    spans.add(DiffSpan(newMid, changed: true));
  }
  if (suf > 0) {
    spans.add(DiffSpan(String.fromCharCodes(nc.sublist(nc.length - suf))));
  }
  return LineDiff(old, neu, spans);
}
