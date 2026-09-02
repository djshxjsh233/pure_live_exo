import 'dart:async';
import 'package:flutter/material.dart';
import 'package:rxdart/rxdart.dart';
import 'package:video_player/video_player.dart';
import '../models/player_state.dart';
import '../models/player_exception.dart';
import '../models/player_error_type.dart';
import '../interface/unified_player_interface.dart';
import 'package:pure_live/common/index.dart';
// exo-dev 自动构建触发标记

/// ExoPlayer 内核适配器（官方 video_player 插件，Android 底层为 Google ExoPlayer/Media3）
/// - 原生支持 HLS/DASH/MP4
/// - 直播流优先使用 HLS（抖音等平台 HLS 为单音轨，天然规避 FLV 双音轨的声音忽大忽小问题）
/// - FLV/RTMP 由 media_kit 内核兜底（引擎自动回退）
class ExoPlayerAdapter implements UnifiedPlayer {
  VideoPlayerController? _controller;

  bool _initialized = false;

  bool _disposed = false;

  bool _isAudioOnly = false;

  String? _currentUrl;

  Map<String, String> _currentHeaders = {};

  Timer? _pollTimer;

  // =========================
  // subjects
  // =========================
  final _stateSubject = BehaviorSubject<PlayerState>.seeded(PlayerState.idle);
  final _playingSubject = BehaviorSubject<bool>.seeded(false);
  final _loadingSubject = BehaviorSubject<bool>.seeded(false);
  final _errorSubject = PublishSubject<PlayerException>();
  final _completeSubject = BehaviorSubject<bool>.seeded(false);
  final _widthSubject = BehaviorSubject<int?>.seeded(null);
  final _heightSubject = BehaviorSubject<int?>.seeded(null);

  /// video_player 无事件流，轮询 controller.value 驱动状态流
  static const Duration _pollInterval = Duration(milliseconds: 250);

  @override
  Future<void> init({bool audioOnly = false}) async {
    _isAudioOnly = audioOnly;
    // 音频模式：Exo 仍以视频管线播放（直播HLS含视频），保持默认行为即可
    _initialized = true;
    _stateSubject.add(PlayerState.initialized);
  }

  @override
  Future<void> setDataSource(
    String url,
    List<String> playUrls,
    Map<String, String> headers, {
    LiveRoom? room,
    bool audioOnly = false,
  }) async {
    await hardDispose();
    if (_disposed) return;
    _isAudioOnly = audioOnly;
    _currentUrl = url;
    _currentHeaders = headers;

    _stateSubject.add(PlayerState.initializing);
    try {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: headers,
      );
      await _controller!.initialize();
      if (_disposed || _controller == null) return;
      _stateSubject.add(PlayerState.ready);
      _startPolling();
    } catch (e) {
      // 诊断期: 展示失败原因以便定位
      try { ToastUtil.show('Exo初始化失败: $e'); } catch (_) {}
      _errorSubject.add(PlayerException(
        message: 'Exo初始化失败: $e',
        type: PlayerErrorType.initialization,
        error: e,
      ));
      _stateSubject.add(PlayerState.error);
    }
  }

  @override
  Future<void> play() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.play();
      _stateSubject.add(PlayerState.playing);
    } catch (e) {
      _errorSubject.add(PlayerException(message: 'Exo播放失败: $e', type: PlayerErrorType.native, error: e));
    }
  }

  @override
  Future<void> pause() async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.pause();
      _stateSubject.add(PlayerState.paused);
    } catch (e) {
      _errorSubject.add(PlayerException(message: 'Exo暂停失败: $e', type: PlayerErrorType.native, error: e));
    }
  }

  @override
  Future<void> stop() async {
    await pause();
    final c = _controller;
    if (c != null) {
      try {
        await c.seekTo(Duration.zero);
      } catch (_) {}
    }
    _stateSubject.add(PlayerState.stopped);
  }

  @override
  Future<void> softStop() async {
    _stopPolling();
    final c = _controller;
    if (c != null) {
      try {
        await c.pause();
      } catch (_) {}
    }
    _stateSubject.add(PlayerState.stopped);
  }

  @override
  Future<void> hardDispose() async {
    _stopPolling();
    final c = _controller;
    _controller = null;
    if (c != null) {
      try {
        await c.dispose();
      } catch (_) {}
    }
    _stateSubject.add(PlayerState.disposed);
  }

  @override
  Future<void> setVolume(double volume) async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.setVolume(volume.clamp(0.0, 1.0));
    } catch (_) {}
  }

  @override
  Widget getVideoWidget() {
    final c = _controller;
    if (c == null) {
      return const SizedBox.shrink();
    }
    return VideoPlayer(c);
  }

  @override
  bool get isInitialized => _controller != null;

  @override
  bool get isPlayingNow => _playingSubject.value;

  @override
  bool get isReusable => true;

  // --- 状态流 ---
  @override
  Stream<PlayerState> get onStateChanged => _stateSubject.stream;

  @override
  Stream<bool> get onPlaying => _playingSubject.stream;

  @override
  Stream<PlayerException> get onError => _errorSubject.stream;

  @override
  Stream<bool> get onLoading => _loadingSubject.stream;

  @override
  Stream<bool> get onComplete => _completeSubject.stream;

  @override
  Stream<int?> get width => _widthSubject.stream;

  @override
  Stream<int?> get height => _heightSubject.stream;

  // --- 轮询状态 ---
  void _startPolling() {
    _stopPolling();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  void _pollOnce() {
    final c = _controller;
    if (c == null) return;
    final v = c.value;
    if (v.hasError) {
      try { ToastUtil.show('Exo播放错误: ${v.errorDescription ?? 'unknown'}'); } catch (_) {}
      _errorSubject.add(PlayerException(
        message: 'Exo播放错误: ${v.errorDescription ?? 'unknown'}',
        type: PlayerErrorType.source,
      ));
      return;
    }
    _playingSubject.add(v.isPlaying);
    _loadingSubject.add(v.isBuffering);
    final w = v.size.width;
    final h = v.size.height;
    if (w != null && w > 0 && h != null && h > 0) {
      _widthSubject.add(w.round());
      _heightSubject.add(h.round());
    }
  }
}