import SwiftUI

/// Sample shell session colored from a theme's ANSI palette, shared by the
/// appearance settings and the theme gallery so previews show the palette in
/// action rather than just the foreground color.
struct TerminalPreviewView: View {
    var theme: TerminalTheme
    var fontName: String
    var fontSize: Double

    private var fg: Color { Color(nsColor: HexColor.nsColor(theme.foreground)) }
    private func ansi(_ i: Int) -> Color { Color(nsColor: HexColor.nsColor(theme.ansi[i])) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            promptLine
            listingLine
            codeKeywordLine
            codeCommentLine
            codeCallLine
        }
        .font(.custom(fontName, size: fontSize))
        .foregroundColor(fg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: HexColor.nsColor(theme.background)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // Text concatenation needs `foregroundColor` (returns Text), not
    // `foregroundStyle` (returns some View).
    private var promptLine: Text {
        Text("tim@portside").foregroundColor(ansi(10))
            + Text(":")
            + Text("~/deploy").foregroundColor(ansi(12)).bold()
            + Text("$ cat main.swift")
    }

    private var listingLine: Text {
        Text("drwxr-xr-x  ")
            + Text("config/").foregroundColor(ansi(4)).bold()
            + Text("  ")
            + Text("restart.sh*").foregroundColor(ansi(2))
    }

    private var codeKeywordLine: Text {
        Text("func ").foregroundColor(ansi(5))
            + Text("connect")
            + Text("(host: ")
            + Text("String").foregroundColor(ansi(6))
            + Text(") {")
    }

    private var codeCommentLine: Text {
        Text("    // retry with backoff").foregroundColor(ansi(8))
    }

    private var codeCallLine: Text {
        Text("    session.open(port: ")
            + Text("22").foregroundColor(ansi(3))
            + Text(", banner: ")
            + Text("\"ahoy\"").foregroundColor(ansi(1))
            + Text(")")
    }
}
