// Turns an SVG into a single-page vector PDF, which an app bundle can load by
// name and tint as a template image. AppKit reads the SVG; nothing else needed.
//
//   swift Scripts/svg-to-pdf.swift in.svg out.pdf
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: svg-to-pdf.swift in.svg out.pdf\n".data(using: .utf8)!)
    exit(1)
}
var box = CGRect(origin: .zero, size: image.size)
let data = NSMutableData()
guard let consumer = CGDataConsumer(data: data as CFMutableData),
      let context = CGContext(consumer: consumer, mediaBox: &box, nil)
else { exit(1) }
context.beginPDFPage(nil)
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
image.draw(in: box)
context.endPDFPage()
context.closePDF()
data.write(toFile: args[2], atomically: true)
