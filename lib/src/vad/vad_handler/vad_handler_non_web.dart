// iOS and Android implementation of VAD handler
// Adapted from https://github.com/keyur2maru/vad/blob/master/lib/src/vad_handler_non_web.dart

import 'dart:async';

import 'package:flutter/cupertino.dart';

import '../../recorder/default_recorder.dart';
import '../../recorder/recorder_base.dart';
import '../vad_iterator/vad_event.dart';
import '../vad_iterator/vad_iterator.dart';
import '../vad_iterator/vad_iterator_base.dart';
import 'vad_handler_base.dart';

/// VadHandlerNonWeb class
class VadHandlerNonWeb implements VadHandlerBase {
  /// Constructor
  VadHandlerNonWeb({
    required this.isDebug,
    this.recorder,
  });

  /// Recorder
  final RecorderBase? recorder;

  late final RecorderBase _recorder = recorder ?? AudioRecorder();

  /// VAD iterator
  late VadIteratorBase _vadIterator;

  /// Audio stream subscription
  StreamSubscription<List<int>>? _audioStreamSubscription;

  /// Debug flag
  bool isDebug = false;
  bool _isInitialized = false;
  bool _submitUserSpeechOnPause = false;

  /// Sample rate
  static const int sampleRate = 16000;

  /// Default Silero VAD Legacy (v4) model path (used for non-web)
  static const String vadLegacyModelPath = 'assets/silero_vad_legacy.onnx';

  /// Default Silero VAD V5 model path (used for non-web)
  static const String vadV5ModelPath = 'assets/silero_vad_v5.onnx';

  final _onSpeechEndController = StreamController<List<double>>.broadcast();
  final _onFrameProcessedController = StreamController<
      ({double isSpeech, double notSpeech, List<double> frame})>.broadcast();
  final _onSpeechStartController = StreamController<void>.broadcast();
  final _onRealSpeechStartController = StreamController<void>.broadcast();
  final _onVADMisfireController = StreamController<void>.broadcast();
  final _onErrorController = StreamController<String>.broadcast();

  @override
  Stream<List<double>> get onSpeechEnd => _onSpeechEndController.stream;

  @override
  Stream<({double isSpeech, double notSpeech, List<double> frame})>
      get onFrameProcessed => _onFrameProcessedController.stream;

  @override
  Stream<void> get onSpeechStart => _onSpeechStartController.stream;

  @override
  Stream<void> get onRealSpeechStart => _onRealSpeechStartController.stream;

  @override
  Stream<void> get onVADMisfire => _onVADMisfireController.stream;

  @override
  Stream<String> get onError => _onErrorController.stream;

  /// Handle VAD event
  void _handleVadEvent(VadEvent event) {
    if (isDebug) {
      debugPrint(
        'VadHandlerNonWeb: VAD Event: ${event.type} with message ${event.message}',
      );
    }
    switch (event.type) {
      case VadEventType.start:
        _onSpeechStartController.add(null);
      case VadEventType.realStart:
        _onRealSpeechStartController.add(null);
      case VadEventType.end:
        if (event.audioData != null) {
          final int16List = event.audioData!.buffer.asInt16List();
          final floatSamples = int16List.map((e) => e / 32768.0).toList();
          _onSpeechEndController.add(floatSamples);
        }
      case VadEventType.frameProcessed:
        if (event.probabilities != null && event.frameData != null) {
          _onFrameProcessedController.add(
            (
              isSpeech: event.probabilities!.isSpeech,
              notSpeech: event.probabilities!.notSpeech,
              frame: event.frameData!
            ),
          );
        }
      case VadEventType.misfire:
        _onVADMisfireController.add(null);
      case VadEventType.error:
        _onErrorController.add(event.message);
    }
  }

  @override
  Future<void> startListening({
    double positiveSpeechThreshold = 0.5,
    double negativeSpeechThreshold = 0.35,
    int preSpeechPadFrames = 1,
    int redemptionFrames = 8,
    int frameSamples = 1536,
    int minSpeechFrames = 3,
    bool submitUserSpeechOnPause = false,
    SileroVADModel model = SileroVADModel.v4,
  }) async {
    if (!_isInitialized) {
      _vadIterator = VadIterator.create(
        isDebug: isDebug,
        sampleRate: sampleRate,
        frameSamples: frameSamples,
        positiveSpeechThreshold: positiveSpeechThreshold,
        negativeSpeechThreshold: negativeSpeechThreshold,
        redemptionFrames: redemptionFrames,
        preSpeechPadFrames: preSpeechPadFrames,
        minSpeechFrames: minSpeechFrames,
        submitUserSpeechOnPause: submitUserSpeechOnPause,
        model: model,
      );
      final modelPath = switch (model) {
        SileroVADModel.v5 => vadV5ModelPath,
        SileroVADModel.v4 => vadLegacyModelPath,
      };
      await _vadIterator.initModel(modelPath);
      _vadIterator.setVadEventCallback(_handleVadEvent);
      _submitUserSpeechOnPause = submitUserSpeechOnPause;
      _isInitialized = true;
    }

    final bool hasPermission = await _recorder.hasPermission();
    if (!hasPermission) {
      _onErrorController
          .add('VadHandlerNonWeb: No permission to record audio.');
      if (isDebug) {
        debugPrint('VadHandlerNonWeb: No permission to record audio.');
      }
      return;
    }

    // Start recording with a stream
    final stream = await _recorder.startStream().onError((e, st) {
      _onErrorController.add('AudioStreamer error: $e');
      if (isDebug) debugPrint('Error starting audio stream: $e');
      return Stream.value([]);
    });

    _audioStreamSubscription = stream.listen(
      (data) async {
        await _vadIterator.processAudioData(data);
      },
      onError: (Object? e, StackTrace? st) {
        _onErrorController.add('AudioStreamer error: $e');
        if (isDebug) debugPrint('Error processing audio data: $e');
      },
    );
  }

  @override
  Future<void> stopListening() async {
    if (isDebug) debugPrint('stopListening');
    try {
      // Before stopping the audio stream, handle forced speech end if needed
      if (_submitUserSpeechOnPause) {
        _vadIterator.forceEndSpeech();
      }

      await _audioStreamSubscription?.cancel();
      _audioStreamSubscription = null;
      await _recorder.stopStream();
      _vadIterator.reset();
    } catch (e) {
      _onErrorController.add(e.toString());
      if (isDebug) debugPrint('Error stopping audio stream: $e');
    }
  }

  @override
  Future<void> pauseListening() async {
    if (isDebug) debugPrint('pauseListening');
    try {
      // Handle forced speech end if needed
      if (_submitUserSpeechOnPause) {
        _vadIterator.forceEndSpeech();
      }

      _audioStreamSubscription?.pause();
      await _recorder.pauseStream();
    } catch (e) {
      _onErrorController.add(e.toString());
      if (isDebug) debugPrint('Error pausing audio stream: $e');
    }
  }

  @override
  Future<void> resumeListening() async {
    if (isDebug) debugPrint('resumeListening');
    try {
      _audioStreamSubscription?.resume();
      await _recorder.resumeStream();
    } catch (e) {
      _onErrorController.add(e.toString());
      if (isDebug) debugPrint('Error resuming audio stream: $e');
    }
  }

  @override
  void dispose() {
    if (isDebug) debugPrint('VadHandlerNonWeb: dispose');
    stopListening();
    _vadIterator.release();
    _onSpeechEndController.close();
    _onFrameProcessedController.close();
    _onSpeechStartController.close();
    _onRealSpeechStartController.close();
    _onVADMisfireController.close();
    _onErrorController.close();
    if (recorder == null) _recorder.dispose();
  }
}

/// Create a VAD handler for the iOS and Android.
///
/// Parameters:
/// - isDebug: Whether to print debug messages.
/// - recorder: The recorder to use.
/// - modelPath: The path to the model file.
VadHandlerBase createVadHandler({
  required bool isDebug,
  RecorderBase? recorder,
}) =>
    VadHandlerNonWeb(
      isDebug: isDebug,
      recorder: recorder,
    );
