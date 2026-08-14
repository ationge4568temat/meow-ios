import SwiftUI

/// MvpTheme defines the clean, light design system colors and styling tokens
/// for the Block Ad MVP UI on iOS, strictly matching the Android (FlClash) palette.
enum MvpTheme {
    // Backgrounds & Surface Card Colors
    static let bgPrimary = Color(red: 0xF8 / 255.0, green: 0xFA / 255.0, blue: 0xFC / 255.0) // #F8FAFC
    static let cardBg = Color.white // #FFFFFF
    static let borderColor = Color(red: 0xE2 / 255.0, green: 0xE8 / 255.0, blue: 0xF0 / 255.0) // #E2E8F0

    // Primary Active & Accent Colors (Emerald Green #10B981)
    static let activeColor = Color(red: 16 / 255.0, green: 185 / 255.0, blue: 129 / 255.0) // #10B981

    // Inactive & Disabled Colors
    static let inactiveGray = Color(red: 209 / 255.0, green: 213 / 255.0, blue: 219 / 255.0) // #D1D5DB
    static let inactiveBadgeBg = Color(red: 229 / 255.0, green: 231 / 255.0, blue: 235 / 255.0).opacity(0.6) // #E5E7EB @ 60%
    
    // Additional UI Colors
    static let dangerColor = Color(red: 239 / 255.0, green: 68 / 255.0, blue: 68 / 255.0) // #EF4444
    static let dangerText = Color(red: 248 / 255.0, green: 113 / 255.0, blue: 113 / 255.0) // #F87171 (soft red)
    static let dangerBadgeBg = Color(red: 239 / 255.0, green: 68 / 255.0, blue: 68 / 255.0).opacity(0.05) // subtle light red tint
    static let inputBg = Color(red: 249 / 255.0, green: 250 / 255.0, blue: 251 / 255.0) // #F9FAFB

    // Typography Colors
    static let textPrimary = Color(red: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0) // #0F172A
    static let textSecondary = Color(red: 0x64 / 255.0, green: 0x74 / 255.0, blue: 0x8B / 255.0) // #64748B

    // Toast & Warning Colors
    static let toastBg = Color(red: 0x1E / 255.0, green: 0x29 / 255.0, blue: 0x3B / 255.0) // #1E293B
}
