import SwiftUI
import UIKit
import CoreImage.CIFilterBuiltins

func fmtBytes(_ n: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(min(n, UInt64(Int64.max))), countStyle: .binary)
}

func fmtSpeed(_ b: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(b, 0)), countStyle: .binary) + "/s"
}

func fmtUptime(_ s: Int) -> String {
    let d = s / 86400
    let h = (s % 86400) / 3600
    let m = (s % 3600) / 60
    if d > 0 { return "\(d)天\(h)小时" }
    if h > 0 { return "\(h)小时\(m)分" }
    return "\(m)分钟"
}

/// 去掉终端颜色码和回车，方便在文本框里显示
func stripANSI(_ s: String) -> String {
    s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        .replacingOccurrences(of: "\r", with: "")
}

/// 参数只保留安全字符，避免注入到 shell 脚本里
func safeParam(_ s: String) -> String {
    String(s.filter { $0.isLetter || $0.isNumber || ".-_:/".contains($0) })
}

func qrImage(_ s: String) -> UIImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(s.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let ctx = CIContext()
    guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
    return UIImage(cgImage: cg)
}

func infoRow(_ k: String, _ v: String) -> some View {
    HStack(alignment: .top) {
        Text(k).foregroundColor(Theme.textDim)
        Spacer()
        Text(v).multilineTextAlignment(.trailing)
    }
    .font(.subheadline)
}

struct QRItem: Identifiable {
    let id = UUID()
    let text: String
}

struct QRSheet: View {
    let text: String
    @Environment(\.presentationMode) private var mode

    var body: some View {
        VStack(spacing: 16) {
            if let img = qrImage(text) {
                Image(uiImage: img)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(Color.white)
                    .cornerRadius(12)
                    .frame(maxWidth: 300)
            }
            Text(text)
                .font(.caption2)
                .lineLimit(4)
                .foregroundColor(Theme.textDim)
            Button("关闭") { mode.wrappedValue.dismiss() }
                .buttonStyle(NeonButtonStyle())
        }
        .padding()
        .neonBackground()
    }
}

struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            Path { p in
                guard values.count > 1 else { return }
                for (i, v) in values.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(values.count - 1)
                    let y = geo.size.height * (1 - CGFloat(v / maxV))
                    if i == 0 {
                        p.move(to: CGPoint(x: x, y: y))
                    } else {
                        p.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
            .shadow(color: tint.opacity(0.8), radius: 4)
        }
    }
}

struct RingGauge: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(value, 0), 1)))
                    .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.7), radius: 6)
                Text("\(Int(min(max(value, 0), 1) * 100))%")
                    .font(.subheadline.bold().monospacedDigit())
            }
            .frame(width: 76, height: 76)
            Text(title).font(.caption.bold())
            Text(detail)
                .font(.caption2)
                .foregroundColor(Theme.textDim)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}
