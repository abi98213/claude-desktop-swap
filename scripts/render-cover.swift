// Composes docs/cover.jpg (README header and GitHub social preview) from
// the app screenshots in docs/. Regenerate the screenshots first:
//
//   scripts/screenshots.sh && swift scripts/render-cover.swift
import AppKit
import SwiftUI

let docs = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "docs")

func image(_ name: String) -> NSImage {
    guard let img = NSImage(contentsOf: docs.appendingPathComponent(name)) else {
        fatalError("missing docs/\(name); run scripts/screenshots.sh first")
    }
    return img
}

struct Chip: View {
    let symbol: String, text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
            Text(text).font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(.white.opacity(0.10)))
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 1))
    }
}

struct Shot: View {
    let img: NSImage, width: CGFloat
    var body: some View {
        Image(nsImage: img).resizable().interpolation(.high)
            .aspectRatio(contentMode: .fit).frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.black.opacity(0.25), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
    }
}

struct Cover: View {
    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(colors: [Color(red: 0.11, green: 0.09, blue: 0.08),
                                    Color(red: 0.24, green: 0.14, blue: 0.10)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.82, y: 0.45), startRadius: 10, endRadius: 520)

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.circle.fill").font(.system(size: 30))
                    Text("macOS menu bar app · open source").font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(Color(red: 0.95, green: 0.66, blue: 0.52))
                Text("Claude Desktop Swap")
                    .font(.system(size: 60, weight: .bold, design: .rounded))
                    .lineLimit(1).fixedSize()
                    .foregroundStyle(.white)
                Text("All your Claude accounts in the desktop app.\nSwitch in one click — or automatically when one hits its limit.")
                    .font(.system(size: 23, weight: .regular))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Chip(symbol: "cursorarrow.click.2", text: "One-click switch")
                        Chip(symbol: "gauge.with.dots.needle.67percent", text: "Auto-switch at limit")
                    }
                    HStack(spacing: 10) {
                        Chip(symbol: "sidebar.left", text: "Same sessions everywhere")
                        Chip(symbol: "lock.shield", text: "Tokens never leave your Mac")
                    }
                }
                .padding(.top, 8)
            }
            .frame(width: 660, alignment: .leading)
            .padding(.leading, 72)

            ZStack(alignment: .topLeading) {
                Shot(img: image("menu-dark.png"), width: 330)
                    .offset(x: 0, y: 0)
                Shot(img: image("countdown.png"), width: 340)
                    .offset(x: 96, y: 418)
            }
            .frame(width: 520, height: 640, alignment: .topLeading)
            .offset(x: 800, y: 40)
        }
        .frame(width: 1280, height: 640)
        .clipped()
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Cover())
    renderer.scale = 2
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    // JPEG keeps it under GitHub's 1 MB social-preview limit.
    let out = docs.appendingPathComponent("cover.jpg")
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])!.write(to: out)
    print("wrote \(out.path) (\(cg.width)×\(cg.height))")
}
