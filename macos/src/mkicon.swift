import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    return CGColor(colorSpace: cs, components: [r/255, g/255, b/255, a])!
}

// ---- background squircle with dark gradient ----
let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
let bgPath = CGPath(roundedRect: bgRect.insetBy(dx: 8, dy: 8), cornerWidth: 230, cornerHeight: 230, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let bgGrad = CGGradient(colorsSpace: cs, colors: [rgb(13,26,19), rgb(5,9,7)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
ctx.restoreGState()

// subtle green border
ctx.addPath(bgPath)
ctx.setStrokeColor(rgb(74,222,128,0.35))
ctx.setLineWidth(6)
ctx.strokePath()

let cx: CGFloat = 512

// ---- shackle (drawn first, body overlaps its legs) ----
let arcCenterY: CGFloat = 690
let r: CGFloat = 165
let legBottom: CGFloat = 560
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: rgb(74,222,128,0.55))
ctx.setStrokeColor(rgb(74,222,128,1))
ctx.setLineWidth(84)
ctx.setLineCap(.round)
let shackle = CGMutablePath()
shackle.move(to: CGPoint(x: cx - r, y: legBottom))
shackle.addLine(to: CGPoint(x: cx - r, y: arcCenterY))
shackle.addArc(center: CGPoint(x: cx, y: arcCenterY), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
shackle.addLine(to: CGPoint(x: cx + r, y: legBottom))
ctx.addPath(shackle)
ctx.strokePath()
ctx.restoreGState()

// ---- lock body ----
let bodyW: CGFloat = 480
let bodyH: CGFloat = 380
let bodyRect = CGRect(x: cx - bodyW/2, y: 210, width: bodyW, height: bodyH)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 80, cornerHeight: 80, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 50, color: rgb(34,197,94,0.6))
ctx.addPath(bodyPath); ctx.clip()
let bodyGrad = CGGradient(colorsSpace: cs, colors: [rgb(74,222,128), rgb(21,163,74)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bodyGrad, start: CGPoint(x: 0, y: bodyRect.maxY), end: CGPoint(x: 0, y: bodyRect.minY), options: [])
ctx.restoreGState()

// glossy top highlight
ctx.saveGState()
ctx.addPath(bodyPath); ctx.clip()
ctx.setFillColor(rgb(255,255,255,0.10))
ctx.fill(CGRect(x: bodyRect.minX, y: bodyRect.midY + 40, width: bodyW, height: bodyH/2 - 40))
ctx.restoreGState()

// ---- keyhole ----
let holeCX = cx
let holeCY: CGFloat = 440
ctx.setFillColor(rgb(6,18,11,1))
ctx.fillEllipse(in: CGRect(x: holeCX - 52, y: holeCY - 52, width: 104, height: 104))
let slot = CGMutablePath()
slot.move(to: CGPoint(x: holeCX - 30, y: holeCY))
slot.addLine(to: CGPoint(x: holeCX + 30, y: holeCY))
slot.addLine(to: CGPoint(x: holeCX + 46, y: holeCY - 130))
slot.addLine(to: CGPoint(x: holeCX - 46, y: holeCY - 130))
slot.closeSubpath()
ctx.addPath(slot)
ctx.setFillColor(rgb(6,18,11,1))
ctx.fillPath()

img.unlockFocus()

// Relative on purpose: build.sh runs this from macos/.build and picks the file up
// from there. An absolute path here builds fine and then writes to somebody else's
// machine's idea of a temp directory.
let out = "icon_1024.png"
let tiff = img.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
