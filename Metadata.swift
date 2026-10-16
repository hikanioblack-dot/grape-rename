import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

struct MetadataField: Identifiable, Sendable {
    var id: String { key }
    let key: String
    let value: String
}
struct MetadataSection: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let fields: [MetadataField]
}
struct MetadataSnapshot: Sendable {
    var captureDate: Date?
    var captureRaw: String?
    var captureOffset: String?
    var sections: [MetadataSection] = []
}

enum ShotFormat: String, Codable, CaseIterable, Identifiable {
    case dateTime, date, compact
    var id: String { rawValue }
    var pattern: String {
        switch self { case .dateTime: return "yyyy-MM-dd_HH-mm-ss"; case .date: return "yyyy-MM-dd"; case .compact: return "yyyyMMdd_HHmmss" }
    }
    var example: String {
        switch self { case .dateTime: return "2026-06-15_08-09-10"; case .date: return "2026-06-15"; case .compact: return "20260615_080910" }
    }
    func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

enum MetadataReader {
    static func label(_ key: String) -> String {
        let labels: [String: String] = [
            "ColorModel": L("Цветовая модель", "Color model"), "Depth": L("Глубина цвета", "Bit depth"),
            "PixelWidth": L("Ширина, px", "Width, px"), "PixelHeight": L("Высота, px", "Height, px"),
            "ProfileName": L("Цветовой профиль", "Color profile"), "DateTimeOriginal": L("Дата съёмки", "Date taken"),
            "ExposureTime": L("Выдержка, с", "Exposure, s"), "FNumber": L("Диафрагма", "Aperture"),
            "ISOSpeedRatings": "ISO", "OffsetTimeOriginal": L("Смещение UTC", "UTC offset"),
            "PixelXDimension": L("Ширина EXIF, px", "EXIF width, px"), "PixelYDimension": L("Высота EXIF, px", "EXIF height, px"),
            "Make": L("Производитель", "Manufacturer"), "Model": L("Модель камеры", "Camera model"),
            "LensModel": L("Объектив", "Lens"), "FocalLength": L("Фокусное расстояние", "Focal length"),
            "Title": L("Название", "Title"), "Author": L("Автор", "Author"), "Subject": L("Тема", "Subject"),
            "Keywords": L("Ключевые слова", "Keywords"), "Creator": L("Приложение-создатель", "Creator"),
            "Producer": L("Создатель PDF", "PDF producer"), "CreationDate": L("Дата создания PDF", "PDF creation date"),
            "ModDate": L("Дата изменения PDF", "PDF modification date")
        ]
        return labels[key] ?? key
    }
    static func parseCapture(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"; formatter.isLenient = false
        return formatter.date(from: raw)
    }
    static func read(_ url: URL) -> MetadataSnapshot {
        var result = MetadataSnapshot()
        let type = UTType(filenameExtension: url.pathExtension)
        // Launch Services may return a dynamic UTI even for JPEGs. ImageIO
        // identifies the actual file data; don't lose EXIF in that case.
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "bmp", "webp", "dng", "arw", "cr2", "cr3", "nef", "orf", "rw2", "avif", "psd", "jxl", "jp2", "ico", "icns"]
        guard type?.conforms(to: .image) == true || imageExtensions.contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return result }
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            if let raw = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String, let date = parseCapture(raw) {
                result.captureRaw = raw; result.captureDate = date
                result.captureOffset = exif["OffsetTimeOriginal"] as? String
            }
        }
        func fields(_ dictionary: [String: Any]) -> [MetadataField] {
            dictionary.keys.sorted().map { key in MetadataField(key: key, value: readable(dictionary[key]!)) }
        }
        let scalar = properties.filter { !($0.value is [String: Any]) }
        if !scalar.isEmpty { result.sections.append(MetadataSection(title: L("Изображение", "Image"), fields: fields(scalar))) }
        for key in properties.keys.sorted() {
            if let dictionary = properties[key] as? [String: Any] {
                result.sections.append(MetadataSection(title: key.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: ""), fields: fields(dictionary)))
            }
        }
        return result
    }
    static func readable(_ value: Any) -> String {
        if let data = value as? Data { return L("Двоичные данные: \(data.count) байт", "Binary data: \(data.count) bytes") }
        if let array = value as? [Any] { return array.map { readable($0) }.joined(separator: ", ") }
        if let dictionary = value as? [String: Any] { return dictionary.keys.sorted().map { "\($0): \(readable(dictionary[$0]!))" }.joined(separator: " · ") }
        return String(describing: value)
    }
    static func general(_ row: FileRow) -> MetadataSection {
        var fields = [
            MetadataField(key: L("Имя", "Name"), value: row.url.lastPathComponent),
            MetadataField(key: L("Расположение", "Location"), value: row.url.path),
            MetadataField(key: L("Тип", "Type"), value: UTType(filenameExtension: row.url.pathExtension)?.localizedDescription ?? row.url.pathExtension),
            MetadataField(key: L("Размер", "Size"), value: "\(row.stamp.size) " + L("байт", "bytes")),
            MetadataField(key: L("Создан", "Created"), value: Language.date(row.stamp.created)),
            MetadataField(key: L("Изменён", "Modified"), value: Language.date(row.stamp.modified))
        ]
        if let raw = row.metadata.captureRaw { fields.append(MetadataField(key: L("Дата съёмки", "Date taken"), value: raw + (row.metadata.captureOffset.map { " \($0)" } ?? ""))) }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: row.url.path), let mode = attributes[.posixPermissions] as? NSNumber {
            fields.append(MetadataField(key: L("Права доступа", "Permissions"), value: String(format: "%03o", mode.intValue)))
        }
        if row.url.pathExtension.lowercased() == "pdf", let document = CGPDFDocument(row.url as CFURL) {
            fields.append(MetadataField(key: L("Страниц", "Pages"), value: String(document.numberOfPages)))
            if let info = document.info {
                for key in ["Title", "Author", "Subject", "Keywords", "Creator", "Producer", "CreationDate", "ModDate"] {
                    var value: CGPDFStringRef?
                    if CGPDFDictionaryGetString(info, key, &value), let value, let text = CGPDFStringCopyTextString(value) { fields.append(MetadataField(key: key, value: text as String)) }
                }
            }
        }
        return MetadataSection(title: L("Файл", "File"), fields: fields)
    }
    static func inspectorFields(_ row: FileRow) -> [MetadataField] {
        var result = general(row).fields.filter { ![L("Имя", "Name"), L("Тип", "Type"), L("Расположение", "Location")].contains($0.key) }
        let imageFields = row.metadata.sections.flatMap(\.fields)
        func value(_ key: String) -> String? { imageFields.first(where: { $0.key == key })?.value }
        if let width = value("PixelWidth"), let height = value("PixelHeight") { result.append(MetadataField(key: L("Размеры", "Dimensions"), value: "\(width) × \(height)")) }
        for key in ["ColorModel", "ProfileName"] { if let value = value(key) { result.append(MetadataField(key: key, value: value)) } }
        let camera = [value("Make"), value("Model")].compactMap { $0 }.joined(separator: " ")
        if !camera.isEmpty { result.append(MetadataField(key: L("Камера", "Camera"), value: camera)) }
        return result
    }
}
