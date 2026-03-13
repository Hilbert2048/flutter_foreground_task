//
//  AudioKeepAliveManager.swift
//  flutter_foreground_task
//
//  Manages SilentAudioPlayer lifecycle, health monitoring, and audio interruption recovery.
//

import Foundation
import AVFoundation

class AudioKeepAliveManager {
  private var player: SilentAudioPlayer?
  private var healthCheckTimer: Timer?

  private let healthCheckInterval: TimeInterval = 10
  private let outputTimeoutThreshold: TimeInterval = 5

  private(set) var isRunning: Bool = false

  func start() {
    guard !isRunning else { return }

    player = SilentAudioPlayer()
    guard player?.start() == true else {
      player = nil
      return
    }

    isRunning = true
    startHealthCheck()
    registerInterruptionObserver()
  }

  func stop() {
    guard isRunning else { return }

    stopHealthCheck()
    unregisterInterruptionObserver()
    player?.stop()
    player = nil
    isRunning = false
  }

  // MARK: - Health Check

  private func startHealthCheck() {
    stopHealthCheck()
    healthCheckTimer = Timer.scheduledTimer(
      withTimeInterval: healthCheckInterval,
      repeats: true
    ) { [weak self] _ in
      self?.performHealthCheck()
    }
  }

  private func stopHealthCheck() {
    healthCheckTimer?.invalidate()
    healthCheckTimer = nil
  }

  private func performHealthCheck() {
    guard isRunning, let player = player else { return }

    let now = CACurrentMediaTime()
    let elapsed = now - player.lastOutputTime

    if player.lastOutputTime == 0 || elapsed > outputTimeoutThreshold {
      restartPlayer()
    }
  }

  private func restartPlayer() {
    player?.stop()
    player = nil

    player = SilentAudioPlayer()
    if player?.start() != true {
      player = nil
      isRunning = false
    }
  }

  // MARK: - Audio Interruption

  private func registerInterruptionObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  private func unregisterInterruptionObserver() {
    NotificationCenter.default.removeObserver(
      self,
      name: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance()
    )
  }

  @objc private func handleInterruption(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue)
    else { return }

    switch type {
    case .began:
      break
    case .ended:
      if isRunning {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
          self?.restartPlayer()
        }
      }
    @unknown default:
      break
    }
  }

  deinit {
    stop()
  }
}
