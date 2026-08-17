import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_asr/app_state.dart';
import 'package:simple_asr/proof_diff.dart';
import 'package:simple_asr/main.dart';
import 'package:simple_asr/native_api.dart';
import 'package:simple_asr/widgets/timed_transcript_view.dart';

void main() {
  // 注入 StubApi：widget 测试不加载 Rust 动态库。
  testWidgets('模型未就绪时显示下载引导面板与顶栏', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(api: StubApi())),
    );
    await tester.pumpAndSettle();

    expect(find.text('Qwen3-ASR 语音转文字'), findsOneWidget);
    expect(find.text('需要先下载模型'), findsOneWidget);
    expect(find.text('未下载模型'), findsOneWidget);
    expect(find.text('ModelScope'), findsWidgets);
    expect(find.text('Hugging Face'), findsWidgets);
    expect(find.text('内置下载（ModelScope 源）'), findsOneWidget);
    expect(find.text('识别结果将显示在这里'), findsOneWidget);
  });

  testWidgets('模型在盘时启动不自动加载，点「加载模型」才加载', (tester) async {
    final api = _TrackingApi();
    await tester.pumpWidget(MaterialApp(home: HomePage(api: api)));
    await tester.pumpAndSettle();

    // 磁盘有模型：显示加载按钮，且未自动加载
    expect(api.loadCalls, 0);
    expect(find.text('加载模型'), findsOneWidget);

    await tester.tap(find.text('加载模型'));
    await tester.pumpAndSettle();
    expect(api.loadCalls, 1);
    expect(find.text('模型就绪'), findsOneWidget);
  });

  testWidgets('模型在盘未加载时底部常显「加载模型并识别」主按钮', (tester) async {
    final api = _AutoLoadApi();
    await tester.pumpWidget(MaterialApp(home: HomePage(api: api)));
    await tester.pumpAndSettle();

    // 主操作始终可见，不要求先点顶栏的「加载模型」（回归：曾整栏消失）
    expect(find.text('加载模型并识别'), findsOneWidget);
    expect(api.loadCalls, 0); // 仅显示，未自动加载
  });

  test('模型在盘未加载时点转写：先自动加载再转写（一键直达）', () async {
    final api = _AutoLoadApi();
    final model = AppModel(api: api);
    await model.startup();
    model.selectAudioFile('/tmp/demo.mp3');

    await model.transcribe();

    expect(api.calls, ['load', 'transcribe']);
    expect(model.isModelReady, isTrue);
    expect(model.errorMessage, isNull);
  });

  test('模型未下载时点转写：提示下载且不触发加载/转写', () async {
    final api = _AutoLoadApi(onDisk: false);
    final model = AppModel(api: api);
    await model.startup();
    model.selectAudioFile('/tmp/demo.mp3');

    await model.transcribe();

    expect(api.calls, isEmpty);
    expect(model.errorMessage, contains('模型未下载'));
  });

  test('按播放位置定位当前行（歌词式高亮核心逻辑）', () {
    const lines = [
      TranscriptLine(startSec: 0, endSec: 5, speaker: null, text: 'a'),
      TranscriptLine(startSec: 5, endSec: 12, speaker: null, text: 'b'),
      TranscriptLine(startSec: 12, endSec: 20, speaker: null, text: 'c'),
    ];
    expect(activeLineIndex(lines, -0.5), -1); // 开头前
    expect(activeLineIndex(lines, 0), 0);
    expect(activeLineIndex(lines, 4.9), 0);
    expect(activeLineIndex(lines, 5.0), 1);
    expect(activeLineIndex(lines, 13), 2);
    expect(activeLineIndex(lines, 99), 2); // 末行持续到结尾
    expect(activeLineIndex(const [], 1), -1);
  });

  test('校对 diff：纯删除段以红删除线保留', () {
    final d = diffLines(['今天天气很好嗯嗯'], ['今天天气很好']).single;
    expect(d.spans.length, 2);
    expect(d.spans[0].text, '今天天气很好');
    final removed = d.spans[1];
    expect(removed.text, '嗯嗯');
    expect(removed.removed, isTrue);
  });

  test('校对 diff：改写段同时展示旧删与新写', () {
    final d = diffLines(['明天去北京'], ['明天去上海']).single;
    final texts = d.spans.map((s) => s.text).toList();
    expect(texts, ['明天去', '北京', '上海']);
    expect(d.spans[1].removed, isTrue);
    expect(d.spans[2].changed, isTrue);
  });

  test('校对 diff：整行重写与未修改行', () {
    final ds = diffLines(['a', 'b'], ['a', 'xyz']);
    expect(ds[0].hasChange, isFalse);
    expect(ds[1].hasChange, isTrue);
    expect(ds[1].spans.where((s) => s.changed).single.text, 'xyz');
  });

  test('校对 diff：行数防御性对齐', () {
    final ds = diffLines(['a'], ['a', '新增行']);
    expect(ds.length, 2);
    expect(ds[1].hasChange, isTrue);
  });

  test('校对 diff：中间拆行不引起后续行连锁 diff（LCS 锚定）', () {
    // 用户场景：只在一行内回车拆行 → 后续行内容未变，退出校准
    // 不应满屏痕迹（曾按索引对齐全部错位）
    final ds = diffLines(['你好世界', '行B', '行C'], ['你好', '世界', '行B', '行C']);
    expect(ds.length, 4);
    // 拆分行本身：前半（删了后半）+ 新增后半
    expect(ds[0].hasChange, isTrue); // '你好世界' → '你好'
    expect(ds[1].hasChange, isTrue); // '' → '世界'
    // 后续行 clean
    expect(ds[2].hasChange, isFalse);
    expect(ds[2].newText, '行B');
    expect(ds[3].hasChange, isFalse);
    expect(ds[3].newText, '行C');
  });

  test('校对 diff：删除一行不引起后续行连锁 diff', () {
    final ds = diffLines(['a', 'b', 'c'], ['a', 'c']);
    expect(ds.length, 3);
    expect(ds[0].hasChange, isFalse);
    expect(ds[1].hasChange, isTrue); // 'b' 被删
    expect(ds[1].spans.single.removed, isTrue);
    expect(ds[2].hasChange, isFalse);
    expect(ds[2].newText, 'c');
  });

  testWidgets('小窗口下打开设置弹窗不溢出（720p 以下回归）', (tester) async {
    tester.view.physicalSize = const Size(900, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(home: HomePage(api: StubApi())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('计算后端'), findsOneWidget);
    expect(find.text('下载源'), findsOneWidget);
  });

  testWidgets('校准编辑态：回车在光标处拆行（焦点节点直接拦截）', (tester) async {
    final api = _SplitApi();
    final model = AppModel(api: api);
    model.proofLines = [
      const TranscriptLine(startSec: 0, endSec: 5, speaker: null, text: '你好世界'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: model,
          builder: (context, _) => TimedTranscriptView(model: model),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 聚焦第 0 行；enterText 光标落在末尾 → charPos = 4
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    expect(model.proofEditing, isTrue);
    await tester.enterText(find.byType(TextField).first, '你好世界');
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(api.splits.single, (0, 4, null));
    expect(model.proofLines.length, 2);
    // 视图消费拆行信号后置空；拆出的新行真正渲染（两个 TextField，
    // 行尾拆分 → 前半=整行、后半=空）
    expect(model.focusSplitLineAt, isNull);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, '你好世界');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, '');
  });

  testWidgets('回车拆行保持说话人 + Cmd+Z 撤销恢复（用户断句场景）',
      (tester) async {
    final api = _SplitApi();
    const text = ' 您好，请问有什么可以帮到您？这里可以继续补充说明。';
    api.lines = [
      const TranscriptLine(startSec: 5, endSec: 10.6, speaker: 'SPEAKER_01', text: text),
    ];
    final model = AppModel(api: api);
    model.proofLines = api.lines;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: model,
          builder: (context, _) => TimedTranscriptView(model: model),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 聚焦后把光标放在「您好，」之后（UTF-16 偏移 4：空格+您+好+，）
    await tester.tap(find.byType(TextField).first);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: text, selection: TextSelection.collapsed(offset: 4)),
    );
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // 在光标处拆行，且两行都保持原说话人（不挂「下一个人」）
    expect(api.splits.single, (0, 4, 'SPEAKER_01'));
    expect(model.proofLines.length, 2);
    expect(model.proofLines[0].text, ' 您好，');
    expect(model.proofLines[0].speaker, 'SPEAKER_01');
    expect(model.proofLines[1].text, text.substring(4));
    expect(model.proofLines[1].speaker, 'SPEAKER_01');
    expect(model.proofLines[1].startSec, greaterThan(model.proofLines[0].startSec));

    // UI 断言：两个 TextField 实际显示拆分后的文本（回归——controller
    // 缓存错位曾致新行显示原下一行文本、真正插入从未生效）
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(2));
    String fieldText(int i) =>
        tester.widget<TextField>(fields.at(i)).controller!.text;
    expect(fieldText(0), ' 您好，');
    expect(fieldText(1), text.substring(4));

    // Cmd+Z 撤销拆行：恢复单行
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(model.proofLines.length, 1);
    expect(model.proofLines[0].text, text);
    expect(model.proofLines[0].speaker, 'SPEAKER_01');
    // 再次撤销：栈空，无操作不报错
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(model.proofLines.length, 1);
  });

  testWidgets('校准非编辑态：i 键进入编辑（快捷键层保持工作）', (tester) async {
    final model = AppModel(api: _SplitApi());
    model.proofLines = [
      const TranscriptLine(startSec: 0, endSec: 5, speaker: null, text: 'a'),
    ];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListenableBuilder(
          listenable: model,
          builder: (context, _) => TimedTranscriptView(model: model),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(model.proofEditing, isFalse);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
    await tester.pump();
    expect(model.proofEditing, isTrue);
  });
}

class _TrackingApi extends StubApi {
  int loadCalls = 0;
  @override
  Future<bool> modelIsOnDisk() async => true;

  @override
  Future<void> loadModel(Settings s) async {
    loadCalls++;
  }
}

/// 记录调用顺序：验证「加载模型并识别」一键直达。
class _AutoLoadApi extends StubApi {
  _AutoLoadApi({this.onDisk = true});

  final bool onDisk;
  final calls = <String>[];
  int loadCalls = 0;

  @override
  Future<bool> modelIsOnDisk() async => onDisk;

  @override
  Future<void> loadModel(Settings s) async {
    loadCalls++;
    calls.add('load');
  }

  @override
  Future<void> transcribeFile(
    String path,
    Settings s,
    void Function(String text) onText, [
    void Function(String status)? onStatus,
  ]) async {
    calls.add('transcribe');
  }
}

/// 记录拆行调用并模拟 Rust 侧拆成两行（校准编辑态回车拆行测试用）。
class _SplitApi extends StubApi {
  final splits = <(int, int, String?)>[];
  List<TranscriptLine> lines = [
    const TranscriptLine(startSec: 0, endSec: 5, speaker: null, text: '你好世界'),
  ];
  final _undoStack = <List<TranscriptLine>>[];

  @override
  Future<List<TranscriptLine>> transcriptLines() async =>
      List.of(lines);

  @override
  Future<void> pushProofSnapshot() async {
    _undoStack.add(List.of(lines));
  }

  @override
  Future<bool> undoProofEdit() async {
    if (_undoStack.isEmpty) return false;
    lines = _undoStack.removeLast();
    return true;
  }

  @override
  Future<void> splitTranscriptLine(
      int index, int charPos, String? nextSpeaker) async {
    splits.add((index, charPos, nextSpeaker));
    final src = lines.removeAt(index);
    lines.insert(
        index,
        TranscriptLine(
          startSec: src.startSec,
          endSec: src.endSec,
          speaker: src.speaker,
          text: src.text.substring(0, charPos),
        ));
    lines.insert(
        index + 1,
        TranscriptLine(
          startSec: src.endSec,
          endSec: src.endSec,
          speaker: nextSpeaker,
          text: src.text.substring(charPos),
        ));
  }
}

