//
//  SilentAudioPlayer.swift
//  flutter_foreground_task
//
//  Audio keep-alive: plays silent PCM data via AudioUnit to prevent iOS from suspending the app.
//

import Foundation
import AVFoundation
import AudioToolbox

private let kSampleRate: Float64 = 24000
private let kBitsPerChannel: UInt32 = 16
private let kChannelsPerFrame: UInt32 = 1
private let kBytesPerFrame: UInt32 = (kBitsPerChannel / 8) * kChannelsPerFrame
// 1 second of silence buffer
private let kSilenceBufferFrames: Int = Int(kSampleRate)
private let kSilenceBufferSize: Int = kSilenceBufferFrames * Int(kBytesPerFrame)

class SilentAudioPlayer {
  private var audioUnit: AudioComponentInstance?
  private var silenceData: Data
  private var cachedData: NSMutableData
  private let lock = NSLock()

  private(set) var isPlaying: Bool = false
  var lastOutputTime: CFTimeInterval = 0

  init() {
    silenceData = Data(count: kSilenceBufferSize)
    cachedData = NSMutableData(data: silenceData)
  }

  func start() -> Bool {
    if isPlaying { return true }

    if !configureAudioSession() {
      return false
    }

    guard let unit = createAudioUnit() else {
      return false
    }

    audioUnit = unit
    let status = AudioOutputUnitStart(unit)
    if status != noErr {
      disposeAudioUnit()
      return false
    }

    isPlaying = true
    return true
  }

  func stop() {
    guard isPlaying, let unit = audioUnit else { return }
    AudioOutputUnitStop(unit)
    disposeAudioUnit()
    isPlaying = false
    lastOutputTime = 0
  }

  // MARK: - AudioSession

  private func configureAudioSession() -> Bool {
    let session = AVAudioSession.sharedInstance()
    do {
      var options: AVAudioSession.CategoryOptions = [
        .mixWithOthers,
        .allowBluetooth,
        .defaultToSpeaker
      ]
      if #available(iOS 9.0, *) {
        options.insert(.interruptSpokenAudioAndMixWithOthers)
      }

      try session.setCategory(.playAndRecord, options: options)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      return true
    } catch {
      print("[SilentAudioPlayer] Failed to configure AVAudioSession: \(error)")
      return false
    }
  }

  // MARK: - AudioUnit

  private func createAudioUnit() -> AudioComponentInstance? {
    var desc = AudioComponentDescription(
      componentType: kAudioUnitType_Output,
      componentSubType: kAudioUnitSubType_VoiceProcessingIO,
      componentManufacturer: kAudioUnitManufacturer_Apple,
      componentFlags: 0,
      componentFlagsMask: 0
    )

    guard let component = AudioComponentFindNext(nil, &desc) else {
      return nil
    }

    var unit: AudioComponentInstance?
    guard AudioComponentInstanceNew(component, &unit) == noErr, let unit = unit else {
      return nil
    }

    var asbd = AudioStreamBasicDescription(
      mSampleRate: kSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
      mBytesPerPacket: kBytesPerFrame,
      mFramesPerPacket: 1,
      mBytesPerFrame: kBytesPerFrame,
      mChannelsPerFrame: kChannelsPerFrame,
      mBitsPerChannel: kBitsPerChannel,
      mReserved: 0
    )

    var callbackStruct = AURenderCallbackStruct(
      inputProc: silentRenderCallback,
      inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
    )

    let formatStatus = AudioUnitSetProperty(
      unit,
      kAudioUnitProperty_StreamFormat,
      kAudioUnitScope_Input,
      0,
      &asbd,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    )

    let callbackStatus = AudioUnitSetProperty(
      unit,
      kAudioUnitProperty_SetRenderCallback,
      kAudioUnitScope_Global,
      0,
      &callbackStruct,
      UInt32(MemoryLayout<AURenderCallbackStruct>.size)
    )

    let initStatus = AudioUnitInitialize(unit)

    if formatStatus != noErr || callbackStatus != noErr || initStatus != noErr {
      AudioComponentInstanceDispose(unit)
      return nil
    }

    return unit
  }

  private func disposeAudioUnit() {
    guard let unit = audioUnit else { return }
    AudioUnitUninitialize(unit)
    AudioComponentInstanceDispose(unit)
    audioUnit = nil

    lock.lock()
    cachedData = NSMutableData(data: silenceData)
    lock.unlock()
  }

  // MARK: - Render

  func fillBuffer(_ ioData: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
    lock.lock()
    defer { lock.unlock() }

    lastOutputTime = CACurrentMediaTime()

    guard let bufferPointer = ioData.pointee.mBuffers.mData else { return }
    let bufferSize = Int(ioData.pointee.mBuffers.mDataByteSize)

    memset(bufferPointer, 0, bufferSize)

    let available = cachedData.length
    let bytesNeeded = Int(frameCount) * Int(kBytesPerFrame)
    let bytesCopy = min(min(available, bytesNeeded), bufferSize)

    if bytesCopy > 0 {
      cachedData.getBytes(bufferPointer, length: bytesCopy)
      cachedData.replaceBytes(in: NSRange(location: 0, length: bytesCopy), withBytes: nil, length: 0)

      if cachedData.length == 0 {
        cachedData.append(silenceData)
      }
    }
  }
}

// C render callback — must be a free function
private func silentRenderCallback(
  inRefCon: UnsafeMutableRawPointer,
  ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
  inTimeStamp: UnsafePointer<AudioTimeStamp>,
  inBusNumber: UInt32,
  inNumberFrames: UInt32,
  ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
  guard let ioData = ioData else { return noErr }

  let player = Unmanaged<SilentAudioPlayer>.fromOpaque(inRefCon).takeUnretainedValue()
  player.fillBuffer(ioData, frameCount: inNumberFrames)

  ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)

  return noErr
}
