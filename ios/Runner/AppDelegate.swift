import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HappyDriveMedia")
    else { return }
    let channel = FlutterMethodChannel(
      name: "happy_drive/media", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "transcodeAudio" else {
        return result(FlutterMethodNotImplemented)
      }
      guard let args = call.arguments as? [String: Any],
        let input = args["input"] as? String,
        let output = args["output"] as? String,
        let bits = args["bitsPerChannel"] as? Int
      else {
        return result(
          FlutterError(
            code: "args", message: "input, output and bitsPerChannel are required",
            details: nil))
      }
      AudioTranscoder.toAac(
        input: URL(fileURLWithPath: input), output: URL(fileURLWithPath: output),
        bitsPerChannel: bits
      ) { ok in DispatchQueue.main.async { result(ok) } }
    }

    let device = FlutterMethodChannel(
      name: "happy_drive/device", binaryMessenger: registrar.messenger())
    device.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any]
      switch call.method {
      case "storage":
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [
          .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values?.volumeTotalCapacity,
          let free = values?.volumeAvailableCapacityForImportantUsage
        else { return result(nil) }
        result(["total": Int64(total), "free": free])
      case "pdfPageCount":
        guard let path = args?["path"] as? String else { return result(nil) }
        PdfPages.queue.async {
          let count = PdfPages.document(path)?.numberOfPages
          DispatchQueue.main.async {
            if let count {
              result(count)
            } else {
              result(FlutterError(code: "pdf", message: "unreadable", details: nil))
            }
          }
        }
      case "pdfRenderPage":
        guard let path = args?["path"] as? String, let page = args?["page"] as? Int,
          let width = args?["width"] as? Int
        else { return result(nil) }
        PdfPages.queue.async {
          let jpeg = PdfPages.render(path: path, index: page, width: width)
          DispatchQueue.main.async {
            if let jpeg {
              result(FlutterStandardTypedData(bytes: jpeg))
            } else {
              result(FlutterError(code: "pdf", message: "page \(page)", details: nil))
            }
          }
        }
      case "pdfClose":
        PdfPages.queue.async { PdfPages.close() }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Draws PDF pages with Core Graphics, for the in-app preview. The document
/// stays open between pages, since they're asked for one after another as
/// they scroll into view. Only touched on [queue].
enum PdfPages {
  static let queue = DispatchQueue(label: "happy_drive.pdf")
  private static var path: String?
  private static var doc: CGPDFDocument?

  static func document(_ path: String) -> CGPDFDocument? {
    if self.path == path, let doc { return doc }
    close()
    guard let opened = CGPDFDocument(URL(fileURLWithPath: path) as CFURL),
      !opened.isEncrypted || opened.unlockWithPassword("")
    else { return nil }
    self.path = path
    doc = opened
    return opened
  }

  /// Page [index] (from 0) as a JPEG [width] pixels wide, on white.
  static func render(path: String, index: Int, width: Int) -> Data? {
    guard let page = document(path)?.page(at: index + 1) else { return nil }
    let box = page.getBoxRect(.cropBox)
    let rotated = page.rotationAngle % 180 != 0
    let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
    guard size.width > 0, size.height > 0 else { return nil }
    let scale = CGFloat(width) / size.width
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let target = CGSize(width: CGFloat(width), height: (size.height * scale).rounded())
    let image = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
      UIColor.white.setFill()
      ctx.fill(CGRect(origin: .zero, size: target))
      let cg = ctx.cgContext
      // PDF space runs bottom-up; flip it, then let the page map itself
      // (rotation included) into the box.
      cg.translateBy(x: 0, y: target.height)
      cg.scaleBy(x: 1, y: -1)
      cg.concatenate(
        page.getDrawingTransform(
          .cropBox, rect: CGRect(origin: .zero, size: target), rotate: 0,
          preserveAspectRatio: true))
      cg.drawPDFPage(page)
    }
    return image.jpegData(compressionQuality: 0.85)
  }

  static func close() {
    doc = nil
    path = nil
  }
}

/// Re-encodes a sound file as AAC in an .m4a with the system's own encoder.
///
/// Calls `done` exactly once, on a background queue. Anything it can't
/// handle — more than two channels, a rate AAC can't carry, a format the
/// system can't read — reports false, and the original is kept.
enum AudioTranscoder {
  static func toAac(
    input: URL, output: URL, bitsPerChannel: Int, done: @escaping (Bool) -> Void
  ) {
    let queue = DispatchQueue(label: "happy_drive.transcode")
    queue.async {
      try? FileManager.default.removeItem(at: output)
      let asset = AVURLAsset(url: input)
      guard let track = asset.tracks(withMediaType: .audio).first,
        let description = track.formatDescriptions.first,
        let basic = CMAudioFormatDescriptionGetStreamBasicDescription(
          description as! CMAudioFormatDescription)?.pointee
      else { return done(false) }
      let channels = Int(basic.mChannelsPerFrame)
      // AAC stops at 48 kHz; anything above is brought down to it.
      let rate = min(basic.mSampleRate, 48000)
      guard (1...2).contains(channels), rate >= 8000 else { return done(false) }
      guard let reader = try? AVAssetReader(asset: asset),
        let writer = try? AVAssetWriter(outputURL: output, fileType: .m4a)
      else { return done(false) }
      let readerOutput = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
          AVFormatIDKey: kAudioFormatLinearPCM,
          AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false,
          AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
          AVSampleRateKey: rate,
          AVNumberOfChannelsKey: channels,
        ])
      guard reader.canAdd(readerOutput) else { return done(false) }
      reader.add(readerOutput)

      // Low sample rates cap what AAC can spend, so the encoder is asked
      // which rates it takes and the nearest one at or under the ask wins.
      guard
        let pcm = AVAudioFormat(
          commonFormat: .pcmFormatInt16, sampleRate: rate,
          channels: AVAudioChannelCount(channels), interleaved: true),
        let aac = AVAudioFormat(settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: rate,
          AVNumberOfChannelsKey: channels,
        ]),
        let rates = AVAudioConverter(from: pcm, to: aac)?.applicableEncodeBitRates?
          .map({ $0.intValue }),
        let bits = rates.filter({ $0 <= bitsPerChannel * channels }).max() ?? rates.min()
      else { return done(false) }
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: rate,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: bits,
      ]
      guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
        return done(false)
      }
      let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
      input.expectsMediaDataInRealTime = false
      guard writer.canAdd(input) else { return done(false) }
      writer.add(input)

      guard writer.startWriting(), reader.startReading() else {
        reader.cancelReading()
        writer.cancelWriting()
        return done(false)
      }
      writer.startSession(atSourceTime: .zero)

      var finished = false
      input.requestMediaDataWhenReady(on: queue) {
        guard !finished else { return }
        while input.isReadyForMoreMediaData {
          if let buffer = readerOutput.copyNextSampleBuffer() {
            if input.append(buffer) { continue }
            finished = true
            reader.cancelReading()
            writer.cancelWriting()
            return done(false)
          }
          finished = true
          input.markAsFinished()
          guard reader.status == .completed else {
            writer.cancelWriting()
            return done(false)
          }
          writer.finishWriting { done(writer.status == .completed) }
          return
        }
      }
    }
  }
}
