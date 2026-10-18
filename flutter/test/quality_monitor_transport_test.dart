import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final _sessionId = UuidValue('00000000-0000-0000-0000-000000000000');

class _FakeFFI implements FFI {
  @override
  UuidValue get sessionId => _sessionId;

  @override
  late final FfiModel ffiModel = FfiModel(WeakReference(this));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VisibleMonitor extends QualityMonitorModel {
  _VisibleMonitor(FFI ffi) : super(WeakReference(ffi));
  @override
  bool get show => true;
}

void main() {
  test('hidden monitor keeps current data without scheduling a UI frame', () {
    final ffi = _FakeFFI();
    final model = QualityMonitorModel(WeakReference(ffi));
    var notifications = 0;
    model.addListener(() => notifications++);
    model.updateQualityStatus({'speed': '1 MB/s', 'codec_format': 'H264'});
    model.updateQualityStatus({'speed': '2 MB/s', 'delay': '9'});
    expect(model.data.speed, '2 MB/s');
    expect(model.data.codecFormat, 'H264');
    expect(model.data.delay, '9');
    expect(notifications, 0);
  });

  test('visible monitor still notifies when quality data changes', () {
    final model = _VisibleMonitor(_FakeFFI());
    var notifications = 0;
    model.addListener(() => notifications++);
    model.updateQualityStatus({'speed': '1 MB/s', 'delay': '9'});
    expect(model.data.speed, '1 MB/s');
    expect(notifications, 1);
  });

  test('the quality monitor names the WebRTC transport only on web', () {
    final ffi = _FakeFFI();
    ffi.ffiModel.cachedPeerData.streamType = 'WebRTC';
    final model = QualityMonitorModel(WeakReference(ffi));
    // Off the web the session tab's tooltip already names the transport.
    expect(isWeb, isFalse);
    expect(model.webrtcTransport, isNull);
  });
}
