import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:ml_card_scanner/src/model/card_info.dart';
import 'package:ml_card_scanner/src/parser/parser_algorithm.dart';
import 'package:ml_card_scanner/src/utils/image_processor.dart';
import 'package:ml_card_scanner/src/utils/stream_debouncer.dart';

class ScannerProcessor {
  static const _kDebugOutputCooldownMillis = 5000;

  final bool _usePreprocessingFilters;
  final bool _debugOutputFilteredImage;
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  StreamController<Uint8List>? _debugImageStreamController;

  bool _isProcessing = false;

  ScannerProcessor({
    bool usePreprocessingFilters = false,
    bool debugOutputFilteredImage = false,
  })  : _usePreprocessingFilters = usePreprocessingFilters,
        _debugOutputFilteredImage = debugOutputFilteredImage {
    if (_debugOutputFilteredImage) {
      _debugImageStreamController = StreamController<Uint8List>.broadcast();
    }
  }

  Stream<Uint8List>? get imageStream =>
      _debugImageStreamController?.stream.transform(
        debounceTransformer(
          const Duration(milliseconds: _kDebugOutputCooldownMillis),
        ),
      );

  Future<CardInfo?> computeImage(
      ParserAlgorithm parseAlgorithm,
      CameraImage image,
      InputImageRotation rotation,
      ) async {
    if (_isProcessing) return null;
    _isProcessing = true;

    try {
      final inputImage = await _createInputImage(image, rotation);
      final recognizedText = await _recognizer.processImage(inputImage);
      final parsedCard = await parseAlgorithm.parse(recognizedText);
      return parsedCard;
    } catch (e, st) {
      debugPrint('⚠️ computeImage error: $e\n$st');
      return null;
    } finally {
      _isProcessing = false;
    }
  }

  Future<InputImage> _createInputImage(
      CameraImage image,
      InputImageRotation rotation,
      ) async {
    final format = InputImageFormatValue.fromRawValue(image.format.raw);
    final bytes = Uint8List.fromList(
      image.planes.fold<List<int>>(
        [],
            (acc, plane) => acc..addAll(plane.bytes),
      ),
    );

    if (!_usePreprocessingFilters) {
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: format ?? InputImageFormat.yuv420,
          bytesPerRow: image.planes.first.bytesPerRow,
        ),
      );
    } else {
      ReceivePort? receivePort;
      if (_debugOutputFilteredImage) {
        receivePort = ReceivePort();
        receivePort.listen((message) {
          if (message is Uint8List &&
              _debugImageStreamController != null &&
              !_debugImageStreamController!.isClosed) {
            _debugImageStreamController?.add(message);
          }
        });
      }

      final inputImage = await createInputImageInIsolate(
        rawBytes: bytes,
        width: image.width,
        height: image.height,
        rawRotation: rotation.rawValue,
        rawFormat: image.format.raw,
        bytesPerRow: image.planes.first.bytesPerRow,
        debugSendPort: receivePort?.sendPort,
      );

      receivePort?.close();
      return inputImage;
    }
  }

  void dispose() {
    if (_debugImageStreamController != null &&
        !_debugImageStreamController!.isClosed) {
      _debugImageStreamController?.close();
    }
    unawaited(_recognizer.close());
  }
}
