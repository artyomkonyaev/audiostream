import AVFoundation
import Flutter
import UIKit
import os.log


public class SwiftAudioStreamerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  private var eventSink: FlutterEventSink?
  var engine = AVAudioEngine()
  var audioData: [Int16] = []
  var recording = false
  var preferredSampleRate: Int? = nil

  // Register plugin
  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SwiftAudioStreamerPlugin()

    // Set flutter communication channel for emitting updates
    let eventChannel = FlutterEventChannel.init(
      name: "audio_streamer.eventChannel", binaryMessenger: registrar.messenger())
    
    // Set flutter communication channel for receiving method calls related to sample rate
    let sampleRateMethodChannel = FlutterMethodChannel.init(
      name: "audio_streamer.sampleRateChannel", binaryMessenger: registrar.messenger())

    // Set flutter communication channel for receiving method calls related to permission request
    let permissionRequestMethodChannel = FlutterMethodChannel.init(
      name: "audio_streamer.permissionRequestChannel", binaryMessenger: registrar.messenger())

    sampleRateMethodChannel.setMethodCallHandler { (call: FlutterMethodCall, result: FlutterResult) -> Void in
      if call.method == "getSampleRate" {
        // Return sample rate that is currently being used, may differ from requested
        result(Int(AVAudioSession.sharedInstance().sampleRate))
      }
    }

    permissionRequestMethodChannel.setMethodCallHandler { (call: FlutterMethodCall, result: FlutterResult) -> Void in
      if call.method == "initPermissionRequest" {
        // Handle permission request
        var node = AVAudioEngine().inputNode
        result(0)
      }
    }
    eventChannel.setStreamHandler(instance)
    instance.setupNotifications()
  }

  private func setupNotifications() {
    // Get the default notification center instance.
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(notification:)),
      name: AVAudioSession.interruptionNotification,
      object: nil)
  }

  @objc func handleInterruption(notification: Notification) {
    // If no eventSink to emit events to, do nothing (wait)
    if eventSink == nil {
      return
    }

    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else {
      return
    }

    switch type {
    case .began: ()
    case .ended:
      // An interruption ended. Resume playback, if appropriate.

      guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else {
        return
      }
      let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
      if options.contains(.shouldResume) {
        startRecording(sampleRate: preferredSampleRate)
      }

    default:
      eventSink!(
        FlutterError(
          code: "100", message: "Recording was interrupted",
          details: "Another process interrupted recording."))
    }
  }

  // Handle stream emitting (Swift => Flutter)
  private func emitValues(values: [Int16]) {
    // If no eventSink to emit events to, do nothing (wait)
    if eventSink == nil {
        return
    }
    
    DispatchQueue.main.async {
        // Emit values count event to Flutter
        self.eventSink!(values)
    }
  }

  // Event Channel: On Stream Listen
  public func onListen(
    withArguments arguments: Any?,
    eventSink: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.eventSink = eventSink
    if let args = arguments as? [String: Any] {
      preferredSampleRate = args["sampleRate"] as? Int
      startRecording(sampleRate: preferredSampleRate)
    } else {
      startRecording(sampleRate: nil)
    }
    return nil
  }

  // Event Channel: On Stream Cancelled
  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    NotificationCenter.default.removeObserver(self)
    eventSink = nil
    engine.stop()
    return nil
  }

  func startRecording(sampleRate: Int?) {
    engine = AVAudioEngine()

    do {
        NSLog("Setting audio session category and activating session.")
        try AVAudioSession.sharedInstance().setCategory(
            AVAudioSession.Category.playAndRecord, options: .mixWithOthers)
        try AVAudioSession.sharedInstance().setActive(true)

        let inputNode = engine.inputNode
        let inputNodeFormat = inputNode.inputFormat(forBus: 0)
        NSLog("Default input node format: \(inputNodeFormat)")

        let desiredSampleRate = Double(sampleRate ?? 44100)
        if desiredSampleRate != inputNodeFormat.sampleRate {
            NSLog("Desired sample rate (\(desiredSampleRate)) is different from input node's default sample rate (\(inputNodeFormat.sampleRate)). Using default sample rate.")
        }

        let formatToUse = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inputNodeFormat.sampleRate, channels: inputNodeFormat.channelCount, interleaved: false) ?? inputNodeFormat

        NSLog("Installing tap on input node with format: \(formatToUse)")
        inputNode.installTap(onBus: 0, bufferSize: 4410, format: formatToUse) { buffer, _ in
            let frameLength = Int(buffer.frameLength)
            NSLog("Buffer received with frameLength: \(frameLength)")

            guard let pointer = buffer.int16ChannelData?[0] else {
                NSLog("int16ChannelData pointer is nil.")
                return
            }

            let bufferPointer = UnsafeBufferPointer(start: pointer, count: frameLength)
            let arr = Array(bufferPointer)
            self.emitValues(values: arr)
        }

        NSLog("Starting audio engine.")
        try engine.start()
    } catch {
        NSLog("Caught error: \(error.localizedDescription)")
        eventSink?(
            FlutterError(
                code: "AudioEngineError", 
                message: "Unable to start audio engine or install tap", 
                details: error.localizedDescription
            ))
    }
  }

}
