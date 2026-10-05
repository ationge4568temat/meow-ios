import SwiftUI

/// MvpTheme defines the clean, light design system colors and styling tokens
/// for the Block Ad MVP UI on iOS.
enum MvpTheme: Sendable {
    // Backgrounds & Surface Card Colors
    static let bgPrimary = Color(red: 0xF8 / 255.0, green: 0xFA / 255.0, blue: 0xFC / 255.0) // #F8FAFC
    static let cardBg = Color.white // #FFFFFF
    static let cardBorder = Color.black.opacity(0.05) // #000000 5% (0x0D000000)
    static let borderColor = Color.black.opacity(0.03) // #000000 3% (0x08000000)，接近卡片边框与阴影的柔和分界线

    // Primary Active & Accent Colors (Emerald Green #10B981)
    static let activeColor = Color(red: 16 / 255.0, green: 185 / 255.0, blue: 129 / 255.0) // #10B981

    // Inactive & Disabled Colors
    static let inactiveGray = Color(red: 209 / 255.0, green: 213 / 255.0, blue: 219 / 255.0) // #D1D5DB
    static let inactiveBadgeBg = Color(red: 229 / 255.0, green: 231 / 255.0, blue: 235 / 255.0) // #E5E7EB
    
    // Additional UI Colors
    static let dangerColor = Color(red: 239 / 255.0, green: 68 / 255.0, blue: 68 / 255.0) // #EF4444
    static let dangerText = Color(red: 248 / 255.0, green: 113 / 255.0, blue: 113 / 255.0) // #F87171 (soft red)
    static let inputBg = Color(red: 0xF9 / 255.0, green: 0xFA / 255.0, blue: 0xFB / 255.0) // #F9FAFB

    // Typography Colors
    static let textPrimary = Color(red: 0x0F / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0) // #0F172A
    static let textSecondary = Color(red: 0x64 / 255.0, green: 0x74 / 255.0, blue: 0x8B / 255.0) // #64748B
    static let textMuted = Color(red: 0x94 / 255.0, green: 0xA3 / 255.0, blue: 0xB8 / 255.0) // #94A3B8

    // Toast & Warning Colors
    static let toastBg = Color(red: 0x1E / 255.0, green: 0x29 / 255.0, blue: 0x3B / 255.0) // #1E293B
}
