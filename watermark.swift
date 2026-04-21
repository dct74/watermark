import Foundation
import AppKit
import PDFKit
import CoreText
import CoreGraphics
import Darwin
import ImageIO

// MARK: - Hex to RGBA Color Extension
extension NSColor {
    /// Initializes an NSColor from a hex string (e.g., "#FF0000" or "FF0000").
    convenience init(hex: String, alpha: CGFloat = 1.0) {
        var hexFormatted = hex.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        if hexFormatted.hasPrefix("#") {
            hexFormatted = String(hexFormatted.dropFirst())
        }
        
        var rgbValue: UInt64 = 0
        Scanner(string: hexFormatted).scanHexInt64(&rgbValue)
        
        // Extract and convert RGB components to 0.0~1.0 range
        let r = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let g = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let b = CGFloat(rgbValue & 0x0000FF) / 255.0
        
        self.init(calibratedRed: r, green: g, blue: b, alpha: alpha)
    }
}

// Initialize AppKit (keep CLI tool characteristics)
NSApplication.shared.setActivationPolicy(.accessory)

// ================= 🎨 Standalone Visual Settings Center =================
struct WatermarkStyleSettings {
    
    // MARK: - 1. User Color Pool (UI Layer)
    struct ColorChoice {
        let name: String
        let color: NSColor
    }
    /// Color options displayed to the user in the terminal list.
    let availableColors: [ColorChoice]
    /// Default selected color index when user presses Enter directly (0-based).
    let defaultColorIndex: Int
    
    // MARK: - 2. Transparent Image Rendering (PNG / HEIC)
    /// Watermark opacity on transparent images (0.0 ~ 1.0).
    let imageWatermarkOpacity: CGFloat
    
    // MARK: - 3. Opaque Image Rendering (JPG / JPEG)
    /// Forced background color for JPG using Multiply blend mode.
    /// Set to nil to use the user-selected color directly (Warning: may cause the image to look dark/dirty).
    /// Set to NSColor(white: 0.96, alpha: 1.0) to ensure a clean image look.
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
        opaqueImageForceColor: NSColor(white: 0.96, alpha: 1.0),
        pdfWatermarkOpacity: 0.3,
        diagonalRatio: 0.8,
        lineHeightMultiplier: 1.2,
        jpegCompressionQuality: 0.95
    )
}

// ================= Global Constants & Temp Management =================
private let supportedFileExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "pdf"]
let pdfTempBaseDir = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftWatermark_\(getpid())")

private let fontMapping: [String: String] = [
    "PingFangSC-Regular": "PingFangSC-Regular",
    "STHeiti": "PingFangSC-Semibold",
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

// MARK: - Terminal UI & System Dialogs
enum TerminalUI {
    private static let knownTerminals = ["Terminal", "iTerm", "Warp", "Alacritty", "kitty"]
    
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
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let result = String(data: outData, encoding: .utf8)?.trimmingCharacters(in: CharacterSet(charactersIn: "\n")) ?? ""
                return result.isEmpty ? nil : result
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                if !errData.isEmpty, let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !errMsg.isEmpty {
                    // Ignore user cancellation errors (-128)
                    if !errMsg.contains("User canceled") && !errMsg.contains("-128") {
                        print("⚠️ Dialog error: \(errMsg)")
                    }
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
            set userResponse to display dialog "Please enter watermark text:\n(Use '|' for line breaks, e.g.: Line1|Line2)" default answer "" with title "Input Watermark" buttons {"Cancel", "OK"} default button "OK"
            return text returned of userResponse
        on error errMsg number errNum
            if errNum is equal to -128 then error number -128
            return "ERROR: " & errMsg
        end try
        """
        return runOsaScript(script)
    }
    
    /// Prompts the user in the terminal to select a font.
    static func selectFontInTerminal() -> (name: String, font: NSFont)? {
        let allFonts = ["System Default (PingFangSC-Bold)"] + fontMapping.keys.sorted()
        print("🔤 Please select watermark font (Press Enter for default):")
        for (index, fontName) in allFonts.enumerated() {
            print(" \(index + 1). \(fontName)\(index == 0 ? " (Default)" : "")")
        }
        print("Enter your choice (1-\(allFonts.count)): ", terminator: "")
        
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Handle default selection (direct Enter)
        if input == nil || input!.isEmpty {
            let defaultName = allFonts[0]
            let defaultFont = NSFont.systemFont(ofSize: 100.0, weight: .bold)
            return (defaultName, defaultFont)
        }
        
        guard let choice = Int(input!), (1...allFonts.count).contains(choice) else {
            print("❌ Invalid font choice.")
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
        
        let finalName = (selectedName == "STHeiti") ? "PingFangSC-Semibold" : selectedName
        return (finalName, nsFont)
    }
    
    /// Prompts the user in the terminal to select a color. Accepts external settings.
    static func selectColorInTerminal(settings: WatermarkStyleSettings) -> (name: String, color: NSColor)? {
        print("🎨 Please select watermark color (Press Enter for default):")
        for (index, option) in settings.availableColors.enumerated() {
            print(" \(index + 1). \(option.name)\(index == settings.defaultColorIndex ? " (Default)" : "")")
        }
        print("Enter your choice (1-\(settings.availableColors.count)): ", terminator: "")
        
        let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Apply default config index on direct Enter
        if input == nil || input!.isEmpty {
            let defaultOption = settings.availableColors[settings.defaultColorIndex]
            return (defaultOption.name, defaultOption.color)
        }
        
        guard let choice = Int(input!), (1...settings.availableColors.count).contains(choice) else {
            print("❌ Invalid color choice.")
            return nil
        }
        
        let selected = settings.availableColors[choice - 1]
        return (selected.name, selected.color)
    }
}

// MARK: - Core Watermark Processing Engine
enum WatermarkEngine {
    
    // MARK: - Path Utilities
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
        if !current.isEmpty { paths.append(current) }
        return paths
    }
    
    /// Generates the output URL, forcing HEIC to output as PNG.
    static func getOutputURL(for originalURL: URL) -> URL? {
        let outputDir = originalURL.deletingLastPathComponent().appendingPathComponent("watermarked")
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create output directory: \(error)")
            return nil
        }
        
        var fileName = originalURL.lastPathComponent
        // Convert HEIC to PNG for better compatibility with watermarks
        if originalURL.pathExtension.lowercased() == "heic" {
            fileName = (fileName as NSString).deletingPathExtension + ".png"
        }
        return outputDir.appendingPathComponent(fileName)
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
    
    /// Processes a single image file (PNG, JPG, HEIC).
    static func processImage(url: URL, config: WatermarkConfig, settings: WatermarkStyleSettings) {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("⚠️ Skipped (invalid, corrupted, or unsupported image format): \(url.lastPathComponent)")
            return
        }
        
        let size = NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        guard size.width > 0, size.height > 0 else {
            print("⚠️ Skipped (image size is zero): \(url.lastPathComponent)")
            return
        }
        
        // Determine if the image has an alpha channel to decide the rendering strategy
        let alphaInfo = cgImage.alphaInfo
        let hasAlpha = (alphaInfo != .none && alphaInfo != .noneSkipFirst && alphaInfo != .noneSkipLast)
        
        let minDimension = min(size.width, size.height)
        let targetLen = minDimension * sqrt(2) * settings.diagonalRatio
        let fontSize = calculateFontSize(text: config.maxLineText, targetLength: targetLen, font: config.font)
        let drawFont = NSFont(descriptor: config.font.fontDescriptor, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
        
        let lineHeight = fontSize * settings.lineHeightMultiplier
        let totalHeight = CGFloat(config.lines.count) * lineHeight
        
        // Create an 8-bit RGBA bitmap context
        guard let bitmapRep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                               pixelsWide: Int(size.width),
                                               pixelsHigh: Int(size.height),
                                               bitsPerSample: 8,
                                               samplesPerPixel: 4,
                                               hasAlpha: true,
                                               isPlanar: false,
                                               colorSpaceName: .deviceRGB,
                                               bytesPerRow: 0,
                                               bitsPerPixel: 0) else {
            print("⚠️ Skipped (failed to create bitmap context): \(url.lastPathComponent)")
            return
        }
        
        guard let nsContext = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            print("⚠️ Skipped (failed to create graphics context): \(url.lastPathComponent)")
            return
        }
        
        let ctx = nsContext.cgContext
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        
        // Draw the original image as the base layer
        let tempNSImage = NSImage(cgImage: cgImage, size: size)
        tempNSImage.draw(in: NSRect(origin: .zero, size: size),
                         from: NSRect(origin: .zero, size: size),
                         operation: .sourceOver,
                         fraction: 1.0)
        
        ctx.saveGState()
        
        // Apply centralized color and blend mode strategy
        let finalColor: NSColor
        if hasAlpha {
            // Transparent images (PNG): Use user color with configured opacity (SourceOver by default)
            finalColor = config.color.withAlphaComponent(settings.imageWatermarkOpacity)
        } else {
            // Opaque images (JPG): Use forced color to keep image clean, apply Multiply blend mode
            finalColor = settings.opaqueImageForceColor ?? config.color
            ctx.setBlendMode(.multiply)
        }
        
        let attrs: [NSAttributedString.Key: Any] = [.font: drawFont, .foregroundColor: finalColor]
        
        // Transform context to draw watermark diagonally at center
        ctx.translateBy(x: size.width / 2, y: size.height / 2)
        ctx.rotate(by: .pi / 4)
        
        // Draw each line of text
        var currentY = -totalHeight / 2 + lineHeight / 2
        for line in config.lines {
            let str = NSAttributedString(string: line, attributes: attrs)
            let lineSize = str.size()
            str.draw(at: NSPoint(x: -lineSize.width / 2, y: currentY - lineSize.height / 2))
            currentY += lineHeight
        }
        
        ctx.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        
        // Export processed image to disk
        guard let outputURL = getOutputURL(for: url) else { return }
        
        let outputExt = outputURL.pathExtension.lowercased()
        let fileData: Data?
        if outputExt == "png" {
            fileData = bitmapRep.representation(using: .png, properties: [:])
        } else {
            fileData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: settings.jpegCompressionQuality])
        }
        
        guard let data = fileData else {
            print("❌ Failed to generate image data: \(url.lastPathComponent)")
            return
        }
        
        do {
            try data.write(to: outputURL)
            print("✅ [Image] \(url.lastPathComponent) -> watermarked/ (\(hasAlpha ? "Alpha+SourceOver" : "Opaque+Multiply"))")
        } catch {
            print("❌ Write failed: \(url.lastPathComponent) - \(error)")
        }
    }
    
    /// Processes a single PDF file.
    static func processPDF(url: URL, config: WatermarkConfig, settings: WatermarkStyleSettings) {
        guard let doc = PDFDocument(url: url) else {
            print("⚠️ Skipped (cannot read PDF): \(url.lastPathComponent)")
            return
        }
        
        guard doc.pageCount > 0 else {
            print("⚠️ Skipped (PDF has 0 pages): \(url.lastPathComponent)")
            return
        }
        
        guard let outputURL = getOutputURL(for: url) else { return }
        let tempURL = pdfTempBaseDir.appendingPathComponent(UUID().uuidString + ".pdf")
        
        // Attempt to copy basic metadata (Title, Author, etc.) from the original PDF
        var auxDict: [CFString: Any] = [:]
        if let cgPDFDoc = CGPDFDocument(url as CFURL), let info = cgPDFDoc.info {
            let keysToRead: [(readKey: String, writeKey: CFString)] = [
                ("Title", kCGPDFContextTitle),
                ("Author", kCGPDFContextAuthor),
                ("Subject", kCGPDFContextSubject),
                ("Creator", kCGPDFContextCreator)
            ]
            for mapping in keysToRead {
                mapping.readKey.withCString { cKey in
                    var pdfStringRef: CGPDFStringRef?
                    if CGPDFDictionaryGetString(info, cKey, &pdfStringRef), let strRef = pdfStringRef {
                        let length = CGPDFStringGetLength(strRef)
                        if let bytes = CGPDFStringGetBytePtr(strRef) {
                            let swiftStr = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) ?? ""
                            auxDict[mapping.writeKey] = swiftStr as CFString
                        }
                    }
                }
            }
        }
        if auxDict[kCGPDFContextTitle] == nil {
            auxDict[kCGPDFContextTitle] = "Watermarked - \(url.lastPathComponent)" as CFString
        }
        
        // Create a low-level CG PDF context for direct page manipulation
        guard let consumer = CGDataConsumer(url: tempURL as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: nil, auxDict as CFDictionary) else {
            print("❌ PDF context creation failed: \(url.lastPathComponent)")
            return
        }
        
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let bounds = page.bounds(for: .mediaBox)
            var mediaBox = CGRect(origin: .zero, size: bounds.size)
            
            ctx.beginPage(mediaBox: &mediaBox)
            page.draw(with: .mediaBox, to: ctx)
            
            // Handle page rotation to ensure watermark aligns correctly
            let rotation = page.rotation
            var visualWidth = bounds.width
            var visualHeight = bounds.height
            if rotation == 90 || rotation == 270 {
                swap(&visualWidth, &visualHeight)
            }
            
            let targetLen = min(visualWidth, visualHeight) * sqrt(2) * settings.diagonalRatio
            let fontSize = calculateFontSize(text: config.maxLineText, targetLength: targetLen, font: config.font)
            let drawFont = NSFont(descriptor: config.font.fontDescriptor, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)
            
            let lineHeight = fontSize * settings.lineHeightMultiplier
            let totalHeight = CGFloat(config.lines.count) * lineHeight
            
            ctx.saveGState()
            // Apply configured opacity for PDF watermarks
            ctx.setAlpha(settings.pdfWatermarkOpacity)
            
            // Transform context to draw watermark diagonally at center, counteracting page rotation
            ctx.translateBy(x: bounds.width / 2, y: bounds.height / 2)
            ctx.rotate(by: -CGFloat(rotation) * .pi / 180.0)
            ctx.rotate(by: .pi / 4)
            
            // Use CoreText for precise PDF text rendering
            let attrs: [NSAttributedString.Key: Any] = [.font: drawFont, .foregroundColor: config.color]
            var currentY = -totalHeight / 2 + lineHeight / 2
            
            for line in config.lines {
                let attrStr = NSAttributedString(string: line, attributes: attrs)
                let textLine = CTLineCreateWithAttributedString(attrStr)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let strWidth = CTLineGetTypographicBounds(textLine, &ascent, &descent, &leading)
                let textHeight = ascent + descent + leading
                
                ctx.saveGState()
                ctx.translateBy(x: -strWidth / 2, y: currentY - textHeight / 2)
                CTLineDraw(textLine, ctx)
                ctx.restoreGState()
                
                currentY += lineHeight
            }
            ctx.restoreGState()
            ctx.endPage()
        }
        ctx.closePDF()
        
        // Move temp file to final destination
        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
            print("✅ [PDF] \(url.lastPathComponent) -> watermarked/ (\(doc.pageCount) pages)")
        } catch {
            print("❌ PDF write failed: \(url.lastPathComponent) - \(error)")
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}

// ================= Main Execution Flow =================

/// Resolves raw string paths (files or directories) into an array of valid file URLs.
func resolveTargetFiles(from rawPaths: [String]) -> [URL] {
    var targetFiles: [URL] = []
    for pathString in rawPaths {
        let expandedPath = (pathString as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        var isDir: ObjCBool = false
        
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
            if isDir.boolValue {
                // Recursively find files if a directory is dropped
                if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let fileURL as URL in enumerator {
                        if supportedFileExtensions.contains(fileURL.pathExtension.lowercased()) {
                            targetFiles.append(fileURL)
                        }
                    }
                }
            } else {
                if supportedFileExtensions.contains(url.pathExtension.lowercased()) {
                    targetFiles.append(url)
                }
            }
        } else {
            print("⚠️ Path does not exist, skipped: \(pathString)")
        }
    }
    return targetFiles
}

/// Cleans up temporary files created during PDF processing.
func cleanUpTempFiles() {
    try? FileManager.default.removeItem(at: pdfTempBaseDir)
}

/// Main program entry point.
func run() {
    // Setup temp directory and handle Ctrl+C gracefully
    do {
        try FileManager.default.createDirectory(at: pdfTempBaseDir, withIntermediateDirectories: true)
    } catch {
        print("❌ Failed to create temp directory: \(error)")
        exit(1)
    }
    
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler {
        cleanUpTempFiles()
        print("\n🛑 Processing cancelled by user.")
        exit(130)
    }
    sigintSource.resume()
    
    // Load standalone configuration block
    let styleSettings = WatermarkStyleSettings.default
    
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let settingsPath = (osVersion.majorVersion >= 13) ? "System Settings > Privacy & Security" : "System Preferences > Security & Privacy"
    
    print("💡 Tip: If the dialog doesn't appear, please grant 'Accessibility' permission to your Terminal in \(settingsPath).\n")
    print("⏳ Invoking system input dialog...")
    
    // 1. Get text input
    guard let inputText = TerminalUI.showInputDialog() else {
        print("❌ Input cancelled.")
        exit(0)
    }
    
    let lines = inputText.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else {
        print("❌ Watermark text cannot be empty.")
        exit(1)
    }
    
    // 2. Get style preferences (pass configuration to UI layer)
    guard let colorResult = TerminalUI.selectColorInTerminal(settings: styleSettings) else { exit(1) }
    guard let fontResult = TerminalUI.selectFontInTerminal() else { exit(1) }
    
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
    print("🔤 Watermark font: \(config.fontChoiceName)")
    
    // 3. Get target files
    print("\nPlease drag and drop the files or folders to be processed here")
    guard let inputLine = readLine(), !inputLine.isEmpty else {
        print("❌ No file path entered.")
        exit(0)
    }
    
    let rawPaths = WatermarkEngine.parseInputPaths(input: inputLine)
    let targetFiles = resolveTargetFiles(from: rawPaths)
    
    guard !targetFiles.isEmpty else {
        print("❌ No supported files found.")
        exit(1)
    }
    
    // 4. Execute batch processing
    print("\n🔍 Found \(targetFiles.count) files.\n🚀 Starting batch processing...\n")
    
    let pdfFiles = targetFiles.filter { $0.pathExtension.lowercased() == "pdf" }
    let imageFiles = targetFiles.filter { $0.pathExtension.lowercased() != "pdf" }
    
    for (index, file) in pdfFiles.enumerated() {
        print("[\(index + 1)/\(pdfFiles.count)] ", terminator: "")
        // Pass configuration to engine
        WatermarkEngine.processPDF(url: file, config: config, settings: styleSettings)
    }
    
    for (index, file) in imageFiles.enumerated() {
        print("[\(index + 1)/\(imageFiles.count)] ", terminator: "")
        // Pass configuration to engine
        WatermarkEngine.processImage(url: file, config: config, settings: styleSettings)
    }
    
    print("\n🎉 All processing completed!")
    cleanUpTempFiles()
}

run()
exit(0)
