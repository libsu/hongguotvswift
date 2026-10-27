// SPDX-License-Identifier: GPL-3.0-only
// Sources/GUI/PlayerKeyboard.swift
import Foundation

// MARK: - 播放器键位表
//
// 普通窗口的全局监听与全屏窗口的本地监听共用同一张键位表，
// 避免空格/方向键/Esc 在两个入口各写一遍。

enum PlayerKeyCommand: Equatable {
    case togglePlayback
    case skip(Double)
    case moveRecommendation(Int)
    case escape

    init?(keyCode: UInt16) {
        switch keyCode {
        case 49: self = .togglePlayback       // 空格
        case 123: self = .skip(-10)           // ←
        case 124: self = .skip(10)            // →
        case 125: self = .moveRecommendation(1)   // ↓
        case 126: self = .moveRecommendation(-1)  // ↑
        case 53: self = .escape               // Esc
        default: return nil
        }
    }
}
