// frb 集成冒烟：真实 Rust 动态库加载 + 基础调用。
// 运行：flutter test integration_test/simple_test.dart -d macos
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_asr/main.dart';
import 'package:simple_asr/frb_api.dart';
import 'package:simple_asr/src/rust/frb_generated.dart';
import 'package:simple_asr/src/rust/api/devices.dart' as rust_devices;
import 'package:simple_asr/src/rust/api/model.dart' as rust_model;

void main() {
  testWidgets('Rust 动态库加载且模型检查/目录接口可用', (tester) async {
    await RustLib.init();
    await tester.pumpWidget(const SimpleAsrApp());
    expect(find.text('Qwen3-ASR 语音转文字'), findsOneWidget);

    // Rust 侧真实调用（无需模型在盘）
    final dir = await rust_model.modelDirPath();
    expect(dir, contains('simple-asr'));
    expect(await rust_model.modelIsOnDisk(), isA<bool>());

    // 设备枚举：内存 + Metal 后端可用且至少一枚 GPU
    final info = await rust_devices.systemInfo();
    expect(info.totalMemoryBytes.toInt(), greaterThan(1024 * 1024 * 1024));
    final metal = info.backends.firstWhere((b) => b.id == 'metal');
    expect(metal.available, isTrue);
    expect(metal.devices, isNotEmpty);
    // ignore: avoid_print
    print('DEVINFO mem=${info.totalMemoryBytes} metal=${metal.devices.map((d) => '${d.name}/${d.memoryBytes.toInt()}')}');
  });
}

// FrbApi 引用，防止 analyzer 因仅测试使用而误报；亦是未来扩展锚点。
// ignore: unused_element
final _apiCheck = FrbApi;
