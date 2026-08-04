import Foundation
import AppKit
import PDFKit
import CoreText
import CoreGraphics
import Darwin
import ImageIO
import UniformTypeIdentifiers

// MARK: - Hex to RGBA Color Extension
extension NSColor {
    /// Initializes an NSColor from a hex string. Accepts "#RRGGBB", "RRGGBB",
    /// 3-digit "#RGB" (each digit doubled) and 8-digit "RRGGBBAA".
    /// Invalid strings fall back to black and print a warning.
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        var hexFormatted = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexFormatted.hasPrefix("#") {
            hexFormatted = String(hexFormatted.dropFirst())
        }
        if hexFormatted.count == 3 {
            hexFormatted = hexFormatted.map { "\($0)\($0)" }.joined()
        }

        guard let rgbValue = UInt64(hexFormatted.prefix(6), radix: 16) else {
            print("⚠️ Invalid hex color \"\(hex)\", falling back to black.")
            self.init(calibratedWhite: 0, alpha: 1.0)
            return
        }

        // Extract and convert RGB components to 0.0~1.0 range
        let r = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgbValue & 0x0000FF) / 255.0

        var effectiveAlpha = alpha
        if hexFormatted.count >= 8, let embedded = UInt64(hexFormatted.suffix(2), radix: 16) {
            effectiveAlpha *= CGFloat(embedded) / 255.0
        }

        self.init(calibratedRed: r, green: g, blue: b, alpha: effectiveAlpha)
    }
}

// ================= Visual Settings Center =================
struct WatermarkStyleSettings {

    // MARK: - 1. User Color Pool (UI Layer)
    struct ColorChoice {
        let name: String
        let color: NSColor
    }
    /// Color options displayed to the user in the terminal list.
    let availableColors: [ColorChoice]
    /// Default selected color index when user presses Enter directly (0-based).
    /// Falls back to 0 when out of bounds.
    let defaultColorIndex: Int

    // MARK: - 2. Transparent Image Rendering (PNG / HEIC)
    /// Watermark opacity on transparent images (0.0 ~ 1.0).
    /// Also controls the intensity of the Multiply blend on opaque images.
    let imageWatermarkOpacity: CGFloat

    // MARK: - 3. Opaque Image Rendering (JPG / JPEG)
    /// Watermark color for opaque images rendered with Multiply blend mode.
    /// Set to nil to use the user-selected color (recommended, honors the user's
    /// choice). Set to a light color (e.g. NSColor(white: 0.96, alpha: 1.0)) to
    /// force a neutral gray watermark regardless of the selected color.
    /// Visible intensity = `imageWatermarkOpacity` × color, e.g. a 0.6-alpha
    /// light gray darkens the image by roughly 40% where the text is.
    let opaqueImageForceColor: NSColor?

    // MARK: - 4. PDF Watermark Rendering
    /// Watermark opacity for PDFs (0.0 ~ 1.0).
    let pdfWatermarkOpacity: CGFloat

    // MARK: - 5. Layout & Compression Parameters
    /// Diagonal length ratio (controls watermark size).
    let diagonalRatio: CGFloat
    /// Line height multiplier for multi-line watermarks.
    let lineHeightMultiplier: CGFloat
    /// JPG output compression quality (0.0 ~ 1.0).
    let jpegCompressionQuality: CGFloat

    // ================= Default Configuration Instance =================
    static let `default` = WatermarkStyleSettings(
        availableColors: [
            ColorChoice(name: "Neutral Gray", color: NSColor(hex: "#A9A9A9")),
            ColorChoice(name: "Yellow", color: NSColor(hex: "#FFBF00"))
            // Add more colors here
        ],
        defaultColorIndex: 0,
        imageWatermarkOpacity: 0.6,
        opaqueImageForceColor: nil,
        pdfWatermarkOpacity: 0.3,
        diagonalRatio: 0.8,
        lineHeightMultiplier: 1.2,
        jpegCompressionQuality: 0.95
    )
}

// ================= Global Constants & Temp Management =================
private let supportedFileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "pdf"]
// Shared temp directory for PDF intermediate files. Only safe for single-run CLI use —
// if run() is ever called more than once per process, each invocation should use its own subdirectory.
let pdfTempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftWatermark_\(getpid())")

private let fontMapping: [String: String] = [
    "PingFangSC-Regular": "PingFangSC-Regular",
    "PingFangSC-Semibold": "PingFangSC-Semibold",
    "STKaiti": "STKaiti",
    "STSong": "STSong",
    "STFangsong": "STFangsong",
    "STYuanti": "STYuanti",
    "SimHei": "SimHei",
    "SimSun": "SimSun",
    "KaiTi": "KaiTi",
    "STHupo": "STHupo",
    "STLiti": "STLiti"
]

// ================= OOP Architecture =================
struct WatermarkConfig {
    let lines: [String]
    let maxLineText: String
    let color: NSColor
    let font: NSFont
    let colorChoiceName: String
    let fontChoiceName: String
}

/// A target file together with the directory whose relative structure is
/// mirrored under its `watermarked/` output folder.
struct TargetFile {
    let url: URL
    /// Directory that owns the output: files dropped directly use their parent
    /// directory; files found by recursing a dropped folder use that folder.
    let sourceRoot: URL
}

// MARK: - Terminal UI & System Dialogs
enum TerminalUI {
    private static let knownTerminals = ["Terminal", "iTerm", "Warp", "Alacritty", "kitty", "WezTerm", "Ghostty", "Tabby", "Hyper", "VS Code", "Code"]

    /// Brings the parent terminal window back to the foreground after a dialog closes.
    static func activateParentTerminal() {
        let parentPID = getppid()
        if let parentApp = NSRunningApplication(processIdentifier: parentPID),
           let appName = parentApp.localizedName,
           knownTerminals.contains(where: { appName.contains($0) }) {
            parentApp.activate()
        }
    }

    /// Executes an AppleScript string and returns its output.
    private static func runOsaScript(_ script: String) -> String? {
        defer { activateParentTerminal() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()

            // Drain both pipes concurrently while the process runs, so a full
            // pipe buffer can never deadlock the wait (classic Process trap).
            // Started only AFTER run() succeeds, so a launch failure can never
            // leave two threads blocked on readDataToEndOfFile forever.
            let outFH = outPipe.fileHandleForReading
            let errFH = errPipe.fileHandleForReading
            let drainGroup = DispatchGroup()
            var outData = Data()
            var errData = Data()
            drainGroup.enter()
            DispatchQueue.global().async { outData = outFH.readDataToEndOfFile(); drainGroup.leave() }
            drainGroup.enter()
            DispatchQueue.global().async { errData = errFH.readDataToEndOfFile(); drainGroup.leave() }

            process.waitUntilExit()
            drainGroup.wait()

            if process.terminationStatus == 0 {
                return String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .newlines) ?? ""
            } else {
                let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !errMsg.isEmpty, !errMsg.contains("User canceled"), !errMsg.contains("-128") {
                    print("⚠️ Dialog error: \(errMsg)")
                }
                return nil
            }
        } catch {
            print("⚠️ Failed to launch osascript: \(error)")
            return nil
        }
    }

    /// Shows a macOS native input dialog for watermark text.
    static func showInputDialog() -> String? {
        let script = """
        try
            set userResponse to display dialog "Please enter watermark text:\\n(Use '|' for line breaks, e.g.: Line1|Line2)" default answer "" with title "Input Watermark" buttons {"Cancel", "OK"} default button "OK"
            return text returned of userResponse
        on error errMsg number errNum
            if errNum is equal to -128 then error number -128
            error number -1
        end try
        """
        return runOsaScript(script)
    }

    /// Prompts the user in the terminal to select a font.
    static func selectFontInTerminal() -> (name: String, font: NSFont)? {
        let allFonts = ["System Default (PingFangSC-Bold)"] + fontMapping.keys.sorted()
        print("🔔 Please select watermark font (Press Enter for default):")
        for (index, fontName) in allFonts.enumerated() {
            print(" \(index + 1). \(fontName)\(index == 0 ? " (Default)" : "")")
        }
        print("Enter your choice (1-\(allFonts.count)): ", terminator: "")

        // Handle default selection (direct Enter)
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            let defaultName = allFonts[0]
            let defaultFont = NSFont.systemFont(ofSize: 100.0, weight: .bold)
            return (defaultName, defaultFont)
        }

        guard let choice = Int(input), (1...allFonts.count).contains(choice) else {
            print("✘ Invalid font choice.")
            return nil
        }

        let selectedName = allFonts[choice - 1]
        let nsFont: NSFont

        if selectedName == "System Default (PingFangSC-Bold)" {
            nsFont = NSFont.systemFont(ofSize: 100.0, weight: .bold)
        } else if let mappedName = fontMapping[selectedName], let font = NSFont(name: mappedName, size: 100.0) {
            nsFont = font
        } else {
            print("⚠️ Warning: Font [\(selectedName)] missing, using fallback.")
            return ("System Default (Fallback)", NSFont.systemFont(ofSize: 100.0, weight: .bold))
        }

        return (selectedName, nsFont)
    }

    /// Prompts the user in the terminal to select a color. Accepts external settings.
    static func selectColorInTerminal(settings: WatermarkStyleSettings) -> (name: String, color: NSColor)? {
        guard !settings.availableColors.isEmpty else {
            print("✘ No colors configured in WatermarkStyleSettings.")
            return nil
        }
        // Defensive: a misconfigured defaultColorIndex must not crash the app.
        let defaultIndex = settings.availableColors.indices.contains(settings.defaultColorIndex) ? settings.defaultColorIndex : 0

        print("🎨 Please select watermark color (Press Enter for default):")
        for (index, option) in settings.availableColors.enumerated() {
            print(" \(index + 1). \(option.name)\(index == defaultIndex ? " (Default)" : "")")
        }
        print("Enter your choice (1-\(settings.availableColors.count)): ", terminator: "")

        // Apply default config index on direct Enter
        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty else {
            let defaultOption = settings.availableColors[defaultIndex]
            return (defaultOption.name, defaultOption.color)
        }

        guard let choice = Int(input), (1...settings.availableColors.count).contains(choice) else {
            print("✘ Invalid color choice.")
            return nil
        }

        let selected = settings.availableColors[choice - 1]
        return (selected.name, selected.color)
    }
}

extension CGImageAlphaInfo {
    var hasAlpha: Bool {
        self != .none && self != .noneSkipFirst && self != .noneSkipLast
    }
}

// MARK: - Core Watermark Processing Engine
enum WatermarkEngine {

    // MARK: - Output Path Management
    /// Output paths already written during this run. Used to uniquify
    /// same-basename collisions (e.g. photo.heic → photo.png next to an
    /// existing photo.png) instead of silently overwriting them.
    static var writtenOutputPaths: Set<String> = []

    /// Safely parses dragged-and-dropped paths, handling spaces and quotes.
    static func parseInputPaths(input: String) -> [String] {
        var paths: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false

        for char in input {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "\"" { inQuotes.toggle(); continue }
            if char.isWhitespace && !inQuotes {
                if !current.isEmpty { paths.append(current); current = "" }
                continue
            }
            current.append(char)
        }
        // A trailing backslash is a literal path character, not an escape.
        if escaped { current.append("\\") }
        if !current.isEmpty { paths.append(current) }
        return paths
    }

    /// Generates the output URL for a target file, mirroring the source
    /// directory structure under a `watermarked/` root so same-named files in
    /// different subdirectories never collide. HEIC is forced to PNG output.
    static func getOutputURL(for target: TargetFile) -> URL? {
        let watermarkedRoot = target.sourceRoot.appendingPathComponent("watermarked")

        // Resolve symlinks for the DIRECTORY part only (so /tmp-vs-/private/tmp
        // mismatches don't break the prefix match), but keep the original file
        // name. Resolving the whole path would silently rename symlinked files
        // to their target's name (link.png → real.png).
        let rootPath = target.sourceRoot.resolvingSymlinksInPath().path
        let resolvedDir = target.url.resolvingSymlinksInPath().deletingLastPathComponent().path
        var relativeDir = ""
        if resolvedDir.hasPrefix(rootPath + "/") {
            relativeDir = String(resolvedDir.dropFirst(rootPath.count + 1))
        }

        var outputURL: URL
        if relativeDir.isEmpty {
            outputURL = watermarkedRoot.appendingPathComponent(target.url.lastPathComponent)
        } else {
            outputURL = watermarkedRoot.appendingPathComponent(relativeDir).appendingPathComponent(target.url.lastPathComponent)
        }

        // Convert HEIC to PNG for better compatibility with watermarks
        if target.url.pathExtension.lowercased() == "heic" {
            outputURL = outputURL.deletingPathExtension().appendingPathExtension("png")
        }

        // Replace spaces in the file name with underscores so the output
        // file name never contains spaces; consecutive spaces collapse into a
        // single underscore ("a  b.png" → "a_b.png"). Directory names are left
        // untouched to keep the mirrored structure intact.
        let outputDir = outputURL.deletingLastPathComponent()
        let cleanName = outputURL.lastPathComponent.replacingOccurrences(of: " +", with: "_", options: .regularExpression)
        outputURL = outputDir.appendingPathComponent(cleanName)

        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            print("✘ Failed to create output directory: \(error)")
            return nil
        }
        return outputURL
    }

    /// Appends "_2", "_3" … (space-free, matching the space → underscore rule)
    /// when the natural output path would collide with a file already written
    /// earlier in this run.
    static func uniquifyOutputURL(_ outputURL: URL) -> URL {
        var candidate = outputURL
        var counter = 2
        while writtenOutputPaths.contains(candidate.path) {
            let base = outputURL.deletingPathExtension().path
            let ext = outputURL.pathExtension
            let newPath = ext.isEmpty ? "\(base)_\(counter)" : "\(base)_\(counter).\(ext)"
            candidate = URL(fileURLWithPath: newPath)
            counter += 1
        }
        writtenOutputPaths.insert(candidate.path)
        return candidate
    }

    // MARK: - Core Algorithms
    /// Calculates the required font size to fit the text within a target pixel length.
    private static func calculateFontSize(text: String, targetLength: CGFloat, font: NSFont) -> CGFloat {
        let baseSize: CGFloat = 100.0
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let baseWidth = text.size(withAttributes: attrs).width
        guard baseWidth > 0 else { return baseSize }
        return baseSize * (targetLength / baseWidth)
    }

    /// Sizes the watermark font so that the whole multi-line block fits the image:
    /// the block (longest line + total ink height) rotated by 45° has an
    /// axis-aligned bounding box of (lineWidth + blockHeight)/√2, which must not
    /// exceed `minDimension`. Sizing only by the longest line (as the plain
    /// `calculateFontSize` does) leaves multi-line blocks taller than the image
    /// and clips the top/bottom lines on wide pages.
    private static func fitWatermarkFontSize(config: WatermarkConfig, settings: WatermarkStyleSettings,
                                             targetLength: CGFloat, minDimension: CGFloat) -> CGFloat {
        let base = calculateFontSize(text: config.maxLineText, targetLength: targetLength, font: config.font)
        let lineWidth100 = config.maxLineText.size(withAttributes: [.font: config.font]).width
        guard lineWidth100 > 0 else { return base }
        let u = lineWidth100 / 100.0                      // line width per 1pt of font size
        // Ink height of the whole block at the base size: the lines are placed
        // `lineHeightMultiplier` apart, and the ink band (ascent + descent)
        // extends beyond the slot on the first and last line.
        let inkEm = lineInkHeightEm(config: config)
        let blockHeight = (CGFloat(config.lines.count) - 1) * settings.lineHeightMultiplier * base + inkEm * base
        let blockBBox = (u * base + blockHeight) / sqrt(2) // rotated 45° bounding box
        if blockBBox > minDimension {
            return base * (minDimension / blockBBox)
        }
        return base
    }

    /// (ascent + descent) of the max line's font, in ems (units of font size).
    private static func lineInkHeightEm(config: WatermarkConfig) -> CGFloat {
        let attrStr = NSAttributedString(string: config.maxLineText, attributes: [.font: config.font])
        let line = CTLineCreateWithAttributedString(attrStr)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return (ascent + descent) / 100.0
    }

    /// Decodes the first image from a source with EXIF orientation applied, so
    /// the returned pixels are always in display orientation (row 0 = top).
    /// Works on every macOS version; `CGImageSourceCreateImageAtIndex` alone
    /// ignores EXIF orientation, which would misplace watermarks on rotated
    /// photos (e.g. portrait shots from a phone).
    static func loadOrientedCGImage(from source: CGImageSource) -> CGImage? {
        guard let raw = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let num = props[kCGImagePropertyOrientation] as? NSNumber,
              let orientation = CGImagePropertyOrientation(rawValue: num.uint32Value),
              orientation != .up else {
            return raw
        }
        return applyManualOrientation(orientation, to: raw)
    }

    /// Applies an EXIF orientation to raw image pixels (full-image decode path).
    static func applyManualOrientation(_ orientation: CGImagePropertyOrientation, to image: CGImage) -> CGImage? {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let swapsDimensions: Set<CGImagePropertyOrientation> = [.left, .right, .leftMirrored, .rightMirrored]
        let outWidth = swapsDimensions.contains(orientation) ? image.height : image.width
        let outHeight = swapsDimensions.contains(orientation) ? image.width : image.height

        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let ctx = CGContext(data: nil, width: outWidth, height: outHeight,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else { return nil }
        // The context's backing memory is not guaranteed to be zeroed; clear it
        // so pixels where the source image is transparent stay transparent
        // instead of blending with garbage from the uninitialized allocation.
        ctx.clear(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        // NOTE: `rotated(by:)`/`translatedBy(x:y:)`/`scaledBy(x:y:)` PREMULTIPLY
        // (applied first), which is the opposite of `concatenating` — so the
        // whole table is written with explicit `concatenating` in the verified
        // order: reflection · rotation · translation.
        let transform: CGAffineTransform
        switch orientation {
        case .up:              transform = .identity
        case .upMirrored:      transform = CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: w, y: 0))
        case .down:            transform = CGAffineTransform(rotationAngle: .pi).concatenating(CGAffineTransform(translationX: w, y: h))
        case .downMirrored:    transform = CGAffineTransform(scaleX: 1, y: -1).concatenating(CGAffineTransform(translationX: 0, y: h))
        case .leftMirrored:    transform = CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(rotationAngle: .pi / 2)).concatenating(CGAffineTransform(translationX: h, y: w))
        case .right:           transform = CGAffineTransform(rotationAngle: -.pi / 2).concatenating(CGAffineTransform(translationX: 0, y: w))
        case .rightMirrored:   transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0) // swap x/y
        case .left:            transform = CGAffineTransform(rotationAngle: .pi / 2).concatenating(CGAffineTransform(translationX: h, y: 0))
        }
        ctx.concatenate(transform)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Draws multi-line watermark text centered at `center`, rotated by `rotationAngle`.
    private static func drawWatermarkLines(_ lines: [String], font: NSFont, color: NSColor,
                                           lineHeightMultiplier: CGFloat, in ctx: CGContext,
                                           center: CGPoint, rotationAngle: CGFloat) {
        let lineHeight = font.pointSize * lineHeightMultiplier
        let totalHeight = CGFloat(lines.count) * lineHeight
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]

        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: rotationAngle)

        var currentY = -totalHeight / 2 + lineHeight / 2
        for line in lines {
            let attrStr = NSAttributedString(string: line, attributes: attrs)
            let textLine = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let strWidth = CTLineGetTypographicBounds(textLine, &ascent, &descent, &leading)

            ctx.saveGState()
            // CTLineDraw advances the context's textPosition/textMatrix to the
            // END of the drawn line, and that state is NOT part of the graphics
            // state — saveGState/restoreGState won't reset it. Without resetting
            // it before every draw, each line after the first starts one
            // line-width too far to the right (usually off-image), so multi-line
            // watermarks lose/misplace all but the first line.
            ctx.textPosition = .zero
            ctx.textMatrix = .identity
            // Baseline sits (ascent-descent)/2 below the line-slot center so the
            // glyph block is visually centered on currentY. (Baseline at
            // currentY - textHeight/2 would drag every line's block toward the
            // image corner by descent+leading/2.)
            ctx.translateBy(x: -strWidth / 2, y: currentY - (ascent - descent) / 2)
            CTLineDraw(textLine, ctx)
            ctx.restoreGState()

            currentY += lineHeight
        }
        ctx.restoreGState()
    }

    /// Draws the base image and the watermark text into the given context.
    private static func drawWatermark(in ctx: CGContext, cgImage: CGImage,
                                      config: WatermarkConfig, settings: WatermarkStyleSettings) {
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let minDimension = min(size.width, size.height)
        let targetLen = minDimension * sqrt(2) * settings.diagonalRatio
        let fontSize = fitWatermarkFontSize(config: config, settings: settings,
                                            targetLength: targetLen, minDimension: minDimension)
        let drawFont = NSFont(descriptor: config.font.fontDescriptor, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)

        // 1. Draw the source image. CG's y-up context with `draw` places row 0
        // at the top of the rect, which matches makeImage's row order — so no
        // flip is needed (a flip here would render the output upside down).
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(origin: .zero, size: size))
        ctx.restoreGState()

        // 2. Draw the watermark text.
        let finalColor: NSColor
        let blendMode: CGBlendMode
        if cgImage.alphaInfo.hasAlpha {
            finalColor = config.color.withAlphaComponent(settings.imageWatermarkOpacity)
            blendMode = .normal
        } else {
            finalColor = (settings.opaqueImageForceColor ?? config.color).withAlphaComponent(settings.imageWatermarkOpacity)
            blendMode = .multiply
        }
        ctx.setBlendMode(blendMode)
        drawWatermarkLines(config.lines, font: drawFont, color: finalColor,
                           lineHeightMultiplier: settings.lineHeightMultiplier,
                           in: ctx, center: CGPoint(x: size.width / 2, y: size.height / 2),
                           rotationAngle: .pi / 4)
    }

    /// Copies metadata (EXIF, GPS, IPTC, …) from the source image so it survives
    /// re-encoding. Orientation is normalized to 1 because the pixels are
    /// already rotated into display orientation.
    private static func metadataProperties(from source: CGImageSource, outputType: CFString) -> [CFString: Any] {
        guard let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var props: [CFString: Any] = [:]
        let isPNG = outputType == (UTType.png.identifier as CFString)
        for (key, value) in sourceProps {
            if key == kCGImagePropertyOrientation { continue }
            // Drop source-format-specific dictionaries that don't apply to the target format.
            if isPNG {
                if key == kCGImagePropertyJFIFDictionary || key == kCGImagePropertyTIFFDictionary || key == kCGImagePropertyHEICSDictionary { continue }
            } else {
                if key == kCGImagePropertyPNGDictionary || key == kCGImagePropertyHEICSDictionary { continue }
            }
            props[key] = value
        }
        props[kCGImagePropertyOrientation] = 1
        return props
    }

    /// Displays the output path relative to the source root (e.g. "watermarked/sub/img.png")
    /// so progress lines reflect the actual mirrored destination.
    private static func displayOutputPath(_ finalURL: URL, sourceRoot: URL) -> String {
        let root = sourceRoot.resolvingSymlinksInPath().path
        // Resolve the output path too: it is built from the (possibly symlinked)
        // sourceRoot, so without resolution the prefix match against the resolved
        // root fails and the display degrades to a bare file name.
        var rel = finalURL.resolvingSymlinksInPath().path
        if rel.hasPrefix(root + "/") {
            rel = String(rel.dropFirst(root.count + 1))
        } else {
            rel = finalURL.lastPathComponent
        }
        return rel
    }

    /// Processes a single image file (PNG, JPG, HEIC). Returns true on success.
    @discardableResult
    static func processImage(target: TargetFile, config: WatermarkConfig, settings: WatermarkStyleSettings) -> Bool {
        let url = target.url
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = loadOrientedCGImage(from: imageSource) else {
            print("⚠️ Skipped (invalid, corrupted, or unsupported image format): \(url.lastPathComponent)")
            return false
        }
        guard cgImage.width > 0, cgImage.height > 0 else {
            print("⚠️ Skipped (image size is zero): \(url.lastPathComponent)")
            return false
        }

        // Render into a context that keeps the source color space, so wide-gamut
        // photos are not shifted into deviceRGB.
        let colorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        guard let ctx = CGContext(data: nil,
                                  width: cgImage.width,
                                  height: cgImage.height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else {
            print("⚠️ Skipped (failed to create bitmap context): \(url.lastPathComponent)")
            return false
        }
        // Clear first: the backing memory is not guaranteed to be zeroed, and a
        // transparent source pixel would otherwise source-over garbage from the
        // uninitialized allocation (visible junk in the alpha channel).
        ctx.clear(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        drawWatermark(in: ctx, cgImage: cgImage, config: config, settings: settings)

        guard let rendered = ctx.makeImage() else {
            print("✘ Failed to render watermark: \(url.lastPathComponent)")
            return false
        }

        guard let outputURL = getOutputURL(for: target) else { return false }
        let finalURL = uniquifyOutputURL(outputURL)
        if finalURL.path != outputURL.path {
            print("⚠️ Name collision, writing to \(finalURL.lastPathComponent) instead.")
        }

        let outputExt = finalURL.pathExtension.lowercased()
        let type: CFString = (outputExt == "png") ? (UTType.png.identifier as CFString) : (UTType.jpeg.identifier as CFString)

        var props = metadataProperties(from: imageSource, outputType: type)
        if outputExt != "png" {
            props[kCGImageDestinationLossyCompressionQuality] = settings.jpegCompressionQuality
        }

        func write(with props: [CFString: Any]) -> Bool {
            guard let dest = CGImageDestinationCreateWithURL(finalURL as CFURL, type, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, rendered, props as CFDictionary)
            return CGImageDestinationFinalize(dest)
        }

        if !write(with: props) {
            // Some source metadata may be incompatible with the target format;
            // retry with minimal properties rather than failing.
            var minimal: [CFString: Any] = [kCGImagePropertyOrientation: 1]
            if outputExt != "png" {
                minimal[kCGImageDestinationLossyCompressionQuality] = settings.jpegCompressionQuality
            }
            guard write(with: minimal) else {
                // A failed Finalize can leave a truncated/corrupt file behind;
                // remove it so the user never sees a broken output.
                try? FileManager.default.removeItem(at: finalURL)
                print("✘ Failed to generate image data: \(url.lastPathComponent)")
                return false
            }
        }

        let hasAlpha = cgImage.alphaInfo.hasAlpha
        print("✔︎ [Image] \(url.lastPathComponent) -> \(displayOutputPath(finalURL, sourceRoot: target.sourceRoot)) (\(hasAlpha ? "Alpha+SourceOver" : "Opaque+Multiply"))")
        return true
    }

    /// Extracts metadata from a PDFDocument using high-level attributes, avoiding raw CGPDFString encoding issues.
    /// Only attributes that actually exist in the source are copied — nothing synthetic is injected.
    /// Note: Producer and Creation/Modification dates cannot be preserved — Quartz
    /// always stamps its own Producer and re-stamps both dates on the output.
    private static func extractMetadata(from doc: PDFDocument) -> [CFString: Any] {
        var auxDict: [CFString: Any] = [:]
        let keyMap: [(PDFDocumentAttribute, CFString)] = [
            (.titleAttribute, kCGPDFContextTitle),
            (.authorAttribute, kCGPDFContextAuthor),
            (.subjectAttribute, kCGPDFContextSubject),
            (.creatorAttribute, kCGPDFContextCreator),
            (.keywordsAttribute, kCGPDFContextKeywords)
        ]
        if let docAttrs = doc.documentAttributes {
            for (docKey, ctxKey) in keyMap {
                if let value = docAttrs[docKey] as? String, !value.isEmpty {
                    auxDict[ctxKey] = value as CFString
                }
            }
        }
        return auxDict
    }

    /// Draws the watermark text onto a PDF page within the given CGContext.
    private static func drawWatermark(on page: PDFPage, in ctx: CGContext,
                                      config: WatermarkConfig, settings: WatermarkStyleSettings) {
        // Use the crop box: it reflects what is actually visible, so the
        // watermark is centered on (and sized for) the visible area.
        let bounds = page.bounds(for: .cropBox)
        let rotation = page.rotation
        // Rotated (90/270) pages are written into a swapped-size media box so
        // the output keeps the source's visual orientation (see processPDF).
        // The watermark must then be centered on, and angled to, that output
        // box — a plain 45° on the output page — instead of using the
        // page-space -rotation + 45° formula.
        let rotated = (rotation == 90 || rotation == 270)
        let visualWidth = rotated ? bounds.height : bounds.width
        let visualHeight = rotated ? bounds.width : bounds.height

        let targetLen = min(visualWidth, visualHeight) * sqrt(2) * settings.diagonalRatio
        let fontSize = fitWatermarkFontSize(config: config, settings: settings,
                                            targetLength: targetLen, minDimension: min(visualWidth, visualHeight))
        let drawFont = NSFont(descriptor: config.font.fontDescriptor, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)

        ctx.saveGState()
        ctx.setAlpha(settings.pdfWatermarkOpacity)
        drawWatermarkLines(config.lines, font: drawFont, color: config.color,
                           lineHeightMultiplier: settings.lineHeightMultiplier,
                           in: ctx,
                           center: CGPoint(x: visualWidth / 2, y: visualHeight / 2),
                           rotationAngle: .pi / 4)
        ctx.restoreGState()
    }

    /// Processes a single PDF file. Returns true on success.
    @discardableResult
    static func processPDF(target: TargetFile, config: WatermarkConfig, settings: WatermarkStyleSettings) -> Bool {
        let url = target.url
        guard let doc = PDFDocument(url: url) else {
            print("⚠️ Skipped (cannot read PDF): \(url.lastPathComponent)")
            return false
        }

        guard doc.pageCount > 0 else {
            print("⚠️ Skipped (PDF has 0 pages): \(url.lastPathComponent)")
            return false
        }

        guard let outputURL = getOutputURL(for: target) else { return false }
        let finalURL = uniquifyOutputURL(outputURL)
        if finalURL.path != outputURL.path {
            print("⚠️ Name collision, writing to \(finalURL.lastPathComponent) instead.")
        }
        let tempURL = pdfTempBaseDir.appendingPathComponent(UUID().uuidString + ".pdf")
        // Normally created by run(); create defensively so the engine is
        // self-sufficient when called directly.
        do {
            try FileManager.default.createDirectory(at: pdfTempBaseDir, withIntermediateDirectories: true)
        } catch {
            print("✘ Failed to create temp directory: \(error)")
            return false
        }

        let auxDict = extractMetadata(from: doc)

        guard let consumer = CGDataConsumer(url: tempURL as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, auxDict as CFDictionary) else {
            print("✘ PDF context creation failed: \(url.lastPathComponent)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .cropBox)
            let rotation = page.rotation
            // Pages rotated 90/270 are stored in a swapped-size media box so the
            // output page keeps the source's visual orientation: PDFKit's
            // page.draw(with:) pre-rotates the content, and a 612×792 page with
            // /Rotate 90 must come out as a 792×612 landscape page (otherwise
            // the output would display rotated 90° from the original).
            var mediaBox = CGRect(origin: .zero, size: bounds.size)
            if rotation == 90 || rotation == 270 {
                mediaBox = CGRect(origin: .zero, size: CGSize(width: bounds.height, height: bounds.width))
            }

            ctx.beginPage(mediaBox: &mediaBox)
            page.draw(with: .cropBox, to: ctx)
            drawWatermark(on: page, in: ctx, config: config, settings: settings)
            ctx.endPage()
        }
        ctx.closePDF()

        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            // copy + remove instead of move: works across volumes (the temp dir
            // may live on a different file system than the source/output).
            try FileManager.default.copyItem(at: tempURL, to: finalURL)
            try? FileManager.default.removeItem(at: tempURL)
            print("✔︎ [PDF] \(url.lastPathComponent) -> \(displayOutputPath(finalURL, sourceRoot: target.sourceRoot)) (\(doc.pageCount) pages)")
            return true
        } catch {
            print("✘ PDF write failed: \(url.lastPathComponent) - \(error)")
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}

// ================= Main Execution Flow =================

/// Resolves raw string paths (files or directories) into valid target files,
/// remembering each file's root so output folders mirror the source structure.
func resolveTargetFiles(from rawPaths: [String]) -> [TargetFile] {
    var targets: [TargetFile] = []
    for pathString in rawPaths {
        let expandedPath = (pathString as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        var isDir: ObjCBool = false

        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                // Recursively find files if a directory is dropped
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator {
                        // Only regular files (and symlinks pointing at them) are
                        // candidates. A directory whose name ends in an image
                        // extension (e.g. "2023.jpg/") must be skipped rather
                        // than fed to the image decoder — but a symlink must
                        // NOT be skipped (its resource reports isRegularFile=false).
                        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        let isFile = values?.isRegularFile ?? false
                        let isLink = values?.isSymbolicLink ?? false
                        guard isFile || isLink else { continue }
                        if supportedFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                            targets.append(TargetFile(url: fileURL, sourceRoot: url))
                        }
                    }
                }
            } else {
                if supportedFileExtensions.contains(url.pathExtension.lowercased()) {
                    targets.append(TargetFile(url: url, sourceRoot: url.deletingLastPathComponent()))
                }
            }
        } else {
            print("⚠️ Path does not exist, skipped: \(pathString)")
        }
    }
    return targets
}

/// Cleans up temporary files created during PDF processing.
func cleanUpTempFiles() {
    try? FileManager.default.removeItem(at: pdfTempBaseDir)
}

/// SIGINT (Ctrl+C) handling. Declared at file scope and resumed eagerly so it
/// outlives `run()`; a local dispatch source would be deallocated the moment
/// `run()` returns, silently disabling Ctrl+C cleanup.
private let sigintSource: DispatchSourceSignal = {
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler {
        cleanUpTempFiles()
        print("\n🛑 Processing cancelled by user.")
        exit(130)
    }
    source.resume()
    return source
}()

/// Main program entry point.
func run() {
    // Force-initialize the file-scope SIGINT source. Top-level `let` globals
    // are lazily initialized, and without a reference here the handler would
    // never be installed — Ctrl+C cleanup would silently do nothing.
    _ = sigintSource

    // Setup temp directory
    do {
        try FileManager.default.createDirectory(at: pdfTempBaseDir, withIntermediateDirectories: true)
    } catch {
        print("✘ Failed to create temp directory: \(error)")
        cleanUpTempFiles()
        exit(1)
    }

    // Load standalone configuration block
    let styleSettings = WatermarkStyleSettings.default
    WatermarkEngine.writtenOutputPaths.removeAll()

    NSApplication.shared.setActivationPolicy(.accessory)

    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let settingsPath = (osVersion.majorVersion >= 13) ? "System Settings > Privacy & Security" : "System Preferences > Security & Privacy"

    print("💡 Tip: If the dialog doesn't appear, please grant 'Accessibility' permission to your Terminal in \(settingsPath).\n")
    print("⏳ Invoking system input dialog...")

    // 1. Get text input
    guard let inputText = TerminalUI.showInputDialog() else {
        print("✘ Input cancelled.")
        cleanUpTempFiles()
        exit(0)
    }

    let lines = inputText.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        print("✘ Watermark text cannot be empty.")
        cleanUpTempFiles()
        exit(1)
    }

    // 2. Get style preferences (pass configuration to UI layer)
    guard let colorResult = TerminalUI.selectColorInTerminal(settings: styleSettings) else {
        cleanUpTempFiles()
        exit(1)
    }
    guard let fontResult = TerminalUI.selectFontInTerminal() else {
        cleanUpTempFiles()
        exit(1)
    }

    // Determine the longest line for dynamic font sizing
    let fontAttrs: [NSAttributedString.Key: Any] = [.font: fontResult.font]
    let maxLineText = lines.max(by: { $0.size(withAttributes: fontAttrs).width < $1.size(withAttributes: fontAttrs).width }) ?? ""

    let config = WatermarkConfig(lines: lines,
                                 maxLineText: maxLineText,
                                 color: colorResult.color,
                                 font: fontResult.font,
                                 colorChoiceName: colorResult.name,
                                 fontChoiceName: fontResult.name)

    // Print confirmation
    print("\n📝 Watermark text confirmation:")
    for line in lines {
        print(" | \(line)")
    }
    print("🎨 Watermark color: \(config.colorChoiceName)")
    print("🔔 Watermark font: \(config.fontChoiceName)")

    // 3. Get target files
    print("\nPlease drag and drop the files or folders to be processed here")
    guard let inputLine = readLine(), !inputLine.isEmpty else {
        print("✘ No file path entered.")
        cleanUpTempFiles()
        exit(0)
    }

    let rawPaths = WatermarkEngine.parseInputPaths(input: inputLine)
    let targetFiles = resolveTargetFiles(from: rawPaths)

    guard !targetFiles.isEmpty else {
        print("✘ No supported files found.")
        cleanUpTempFiles()
        exit(1)
    }

    // 4. Execute batch processing
    print("\n🔍 Found \(targetFiles.count) files.\n🚀 Starting batch processing...\n")

    let pdfFiles = targetFiles.filter { $0.url.pathExtension.lowercased() == "pdf" }
    let imageFiles = targetFiles.filter { $0.url.pathExtension.lowercased() != "pdf" }

    var failedCount = 0

    for (index, file) in pdfFiles.enumerated() {
        print("[\(index + 1)/\(pdfFiles.count)] ", terminator: "")
        if !WatermarkEngine.processPDF(target: file, config: config, settings: styleSettings) {
            failedCount += 1
        }
    }

    for (index, file) in imageFiles.enumerated() {
        print("[\(index + 1)/\(imageFiles.count)] ", terminator: "")
        if !WatermarkEngine.processImage(target: file, config: config, settings: styleSettings) {
            failedCount += 1
        }
    }

    let succeeded = targetFiles.count - failedCount
    if failedCount > 0 {
        print("\n⚠️ Processing completed: \(succeeded) succeeded, \(failedCount) failed (out of \(targetFiles.count)).")
    } else {
        print("\n✔︎ All \(targetFiles.count) files processed successfully!")
    }
    cleanUpTempFiles()
}

run()
