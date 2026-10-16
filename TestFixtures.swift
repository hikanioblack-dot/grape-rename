import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum TestFixtures {
    static func createReviewSamples(at root: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw RenameError.message(L("Тестовая папка уже существует.", "The test folder already exists.")) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        try fm.createDirectory(at: originals, withIntermediateDirectories: true)
        try create(at: originals.appendingPathComponent("01 Rename and Preview"))
        try createDuplicateSamples(at: originals.appendingPathComponent("02 Duplicates and Similar"))
        let text = originals.appendingPathComponent("03 Text Search")
        try createTextSamples(at: text)
        try Data("Synthetic unreadable image".utf8).write(to: text.appendingPathComponent("Broken.png"))
        let nested = text.appendingPathComponent("Nested", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try textImage(nested.appendingPathComponent("Nested phrase.png"), lines: ["NESTED GRAPE", "Вложенный пример"])
        // Multi-frame ImageIO input: OCR intentionally examines the first frame.
        guard let first = CGImageSourceCreateWithURL(text.appendingPathComponent("Small sign.png") as CFURL, nil),
              let last = CGImageSourceCreateWithURL(text.appendingPathComponent("Chat screenshot.png") as CFURL, nil),
              let a = CGImageSourceCreateImageAtIndex(first, 0, nil),
              let b = CGImageSourceCreateImageAtIndex(last, 0, nil),
              let gif = CGImageDestinationCreateWithURL(text.appendingPathComponent("First frame only.gif") as CFURL, UTType.gif.identifier as CFString, 2, nil)
        else { throw RenameError.message("Review GIF setup failed") }
        CGImageDestinationAddImage(gif, a, nil); CGImageDestinationAddImage(gif, b, nil)
        guard CGImageDestinationFinalize(gif) else { throw RenameError.message("Review GIF export failed") }
        let conflict = originals.appendingPathComponent("04 Conflicts and Changes")
        try fm.createDirectory(at: conflict, withIntermediateDirectories: true)
        for (name, contents) in ["Source.txt": "SOURCE — synthetic file\n", "Occupied_0001.txt": "DESTINATION — must not be overwritten\n", "Same size A.bin": "ABCD", "Same size B.bin": "WXYZ", "Empty A.txt": "", "Empty B.txt": ""] {
            try Data(contents.utf8).write(to: conflict.appendingPathComponent(name))
        }
        let unicode = originals.appendingPathComponent("05 Unicode and Order")
        try fm.createDirectory(at: unicode, withIntermediateDirectories: true)
        for name in ["Фото 2.txt", "Фото 10.txt", "Photo 1.TXT", "Имя с пробелами и эмодзи 🍇.txt", String(repeating: "Длинное имя ", count: 8) + ".txt"] {
            try Data((name + "\n").utf8).write(to: unicode.appendingPathComponent(name))
        }
        try fm.copyItem(at: originals, to: root.appendingPathComponent("Working", isDirectory: true))
        try fm.createDirectory(at: root.appendingPathComponent("Export", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Verification", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("App State", isDirectory: true), withIntermediateDirectories: true)
    }

    static func image(_ url: URL, type: UTType, color: (CGFloat, CGFloat, CGFloat), date: String? = nil) throws {
        let width = 640, height = 420
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.75)); context.fillEllipse(in: CGRect(x: 380, y: 255, width: 110, height: 110))
        context.setFillColor(CGColor(red: color.0 * 0.4, green: color.1 * 0.5, blue: color.2 * 0.6, alpha: 1))
        context.move(to: CGPoint(x: 0, y: 0)); context.addLine(to: CGPoint(x: 190, y: 240)); context.addLine(to: CGPoint(x: 390, y: 0)); context.closePath(); context.fillPath()
        context.move(to: CGPoint(x: 230, y: 0)); context.addLine(to: CGPoint(x: 450, y: 190)); context.addLine(to: CGPoint(x: 640, y: 0)); context.closePath(); context.fillPath()
        guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw RenameError.message("Fixture image creation failed") }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.86]
        if let date {
            properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: date, "OffsetTimeOriginal" as CFString: "+03:00", kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 0.004, kCGImagePropertyExifISOSpeedRatings: [200]] as [CFString: Any]
            properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFMake: "Grape", kCGImagePropertyTIFFModel: "Test Camera"]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenameError.message("Fixture image export failed") }
    }
    static func createDuplicateSamples(at root: URL) throws {
        try create(at: root)
        let fm = FileManager.default
        let original = root.appendingPathComponent("IMG_0102.jpg")
        try fm.copyItem(at: original, to: root.appendingPathComponent("Exact photo copy.jpeg"))
        try fm.copyItem(at: root.appendingPathComponent("Заметки.md"), to: root.appendingPathComponent("Notes copy.txt"))
        let resized = root.appendingPathComponent("Resized photo.jpg")
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 300
              ] as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(resized as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw RenameError.message("Duplicate demo image setup failed") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.45] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RenameError.message("Duplicate demo image export failed") }
        try Data("""
        Grape Rename — Duplicate Samples

        Exact matches:
        IMG_0102.jpg = Exact photo copy.jpeg (same bytes, different name and extension).
        Заметки.md = Notes copy.txt.

        Similar images:
        Resized photo.jpg is a smaller, recompressed IMG_0102.jpg.
        The other colored landscapes have similar composition; wider matching can group them too.

        Инструменты → Найти и изменить медиафайлы → Точные дубликаты / Похожие фотографии.
        Все файлы искусственные и предназначены для проверки.
        """.utf8).write(to: root.appendingPathComponent("Duplicate Demo.txt"))
        for name in ["Exact photo copy.jpeg", "Notes copy.txt", "Resized photo.jpg", "Duplicate Demo.txt"] {
            try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_720_000_000)], ofItemAtPath: root.appendingPathComponent(name).path)
        }
    }
    static func create(at root: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw RenameError.message(L("Тестовая папка уже существует.", "The test folder already exists.")) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try image(root.appendingPathComponent("IMG_0102.jpg"), type: .jpeg, color: (0.25, 0.47, 0.80), date: "2024:06:15 08:09:10")
        try image(root.appendingPathComponent("IMG_0007.jpg"), type: .jpeg, color: (0.82, 0.36, 0.32), date: "2023:12:31 23:59:58")
        try image(root.appendingPathComponent("No EXIF.png"), type: .png, color: (0.48, 0.28, 0.70))
        try image(root.appendingPathComponent("Forest.tiff"), type: .tiff, color: (0.20, 0.56, 0.35))
        let documents: [String: String] = [
            "README.txt": "Grape Rename — Test Files\n\nTwo JPG images have EXIF capture dates. PNG and TIFF have none.\nTry grid/list, Space, metadata, presets, find IMG → Photo, EXIF naming, rename and restart to undo.\nФайлы созданы специально для проверки.\n",
            "Заметки.md": "# Grape Rename\n\nТестовый документ.\n" + String(repeating: "Проверка даты изменения и содержимого.\n", count: 80),
            "Sales.csv": "date,item,total\n2026-10-01,Grape,25\n2026-10-02,Apple,42\n",
            "config.json": "{\"application\":\"Grape Rename\",\"test\":true,\"items\":[1,2,3]}\n",
            "Purple.svg": "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"400\" height=\"280\"><rect width=\"400\" height=\"280\" fill=\"#6c3bb3\"/><circle cx=\"200\" cy=\"140\" r=\"80\" fill=\"#e7d5ff\"/></svg>",
            "Page.html": "<!doctype html><meta charset=\"utf-8\"><title>Grape</title><h1>Grape Rename</h1><p>Preview test / Проверка просмотра</p>"
        ]
        for (name, text) in documents { try Data(text.utf8).write(to: root.appendingPathComponent(name)) }
        let pdf = root.appendingPathComponent("Two pages.pdf")
        var page = CGRect(x: 0, y: 0, width: 420, height: 595)
        guard let context = CGContext(pdf as CFURL, mediaBox: &page, [kCGPDFContextTitle: "Grape Test", kCGPDFContextAuthor: "Grape Rename"] as CFDictionary) else { throw RenameError.message("PDF fixture creation failed") }
        for i in 0..<2 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: i == 0 ? 0.46 : 0.20, green: 0.3, blue: 0.7, alpha: 1)); context.fill(CGRect(x: 40, y: 380, width: 340, height: 140))
            context.setFillColor(CGColor(gray: 0.86, alpha: 1))
            for line in 0..<10 { context.fill(CGRect(x: 40, y: 330 - line * 20, width: 250 + (line % 3) * 20, height: 6)) }
            context.endPDFPage()
        }
        context.closePDF()
        var audio = Data()
        func ascii(_ string: String) { audio.append(Data(string.utf8)) }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { audio.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { audio.append(contentsOf: $0) } }
        let samples = 8000
        ascii("RIFF"); u32(UInt32(36 + samples * 2)); ascii("WAVEfmt "); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16); ascii("data"); u32(UInt32(samples * 2))
        for i in 0..<samples { u16(UInt16(bitPattern: Int16(sin(Double(i) * 2 * .pi * 440 / 8000) * 2500))) }
        try audio.write(to: root.appendingPathComponent("Tone.wav"))
        try Data(repeating: 0x47, count: 32769).write(to: root.appendingPathComponent("Sample.bin"))
        let urls = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        for (i, url) in urls.enumerated() { try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(i) * 86400)], ofItemAtPath: url.path) }
    }
}
