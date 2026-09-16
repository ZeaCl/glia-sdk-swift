import SwiftUI

/// Configuración visual y de tema completamente agnóstica para GliaChatView
public struct GliaTheme: Sendable {
    public let backgroundColor: Color
    public let surfaceColor: Color
    public let surfaceContainerHigh: Color
    public let primaryColor: Color
    public let textColor: Color
    public let textMutedColor: Color
    public let userBubbleColor: Color
    public let userBubbleTextColor: Color
    public let agentBubbleColor: Color
    public let agentBubbleTextColor: Color
    public let thinkingBgColor: Color
    public let thinkingTextColor: Color
    public let thinkingBorderColor: Color
    public let errorColor: Color

    public init(
        backgroundColor: Color = Color(red: 0.07, green: 0.07, blue: 0.07),
        surfaceColor: Color = Color(red: 0.12, green: 0.12, blue: 0.12),
        surfaceContainerHigh: Color = Color(red: 0.18, green: 0.18, blue: 0.18),
        primaryColor: Color = Color(red: 0.20, green: 0.60, blue: 1.0),
        textColor: Color = .white,
        textMutedColor: Color = Color(white: 0.65),
        userBubbleColor: Color = Color(red: 0.20, green: 0.60, blue: 1.0),
        userBubbleTextColor: Color = .white,
        agentBubbleColor: Color = Color(red: 0.14, green: 0.14, blue: 0.14),
        agentBubbleTextColor: Color = .white,
        thinkingBgColor: Color = Color(red: 0.20, green: 0.60, blue: 1.0).opacity(0.12),
        thinkingTextColor: Color = Color(red: 0.40, green: 0.80, blue: 1.0),
        thinkingBorderColor: Color = Color(red: 0.20, green: 0.60, blue: 1.0).opacity(0.4),
        errorColor: Color = Color(red: 0.95, green: 0.25, blue: 0.25)
    ) {
        self.backgroundColor = backgroundColor
        self.surfaceColor = surfaceColor
        self.surfaceContainerHigh = surfaceContainerHigh
        self.primaryColor = primaryColor
        self.textColor = textColor
        self.textMutedColor = textMutedColor
        self.userBubbleColor = userBubbleColor
        self.userBubbleTextColor = userBubbleTextColor
        self.agentBubbleColor = agentBubbleColor
        self.agentBubbleTextColor = agentBubbleTextColor
        self.thinkingBgColor = thinkingBgColor
        self.thinkingTextColor = thinkingTextColor
        self.thinkingBorderColor = thinkingBorderColor
        self.errorColor = errorColor
    }
}
