import Foundation
import Vision
import UIKit

/// ⭐ 识别层：**Vision OCR + 模板匹配**（配置驱动）。
///
/// 依据（`_note_1791` 的实测结论）：
///   · OCR 用 **Apple Vision `VNRecognizeTextRequest`** —— 零体积、返回 bounding box
///   · 图标用**模板匹配** —— UI 按钮固定不旋转 ⇒ 精度高、零训练
///   · ⚠️ Vision 的 `boundingBox` **原点在左下角** ⇒ 转 UIKit 要 `y = (1 - maxY) * H`
///
/// ⛔ 本类只做"找到没找到 + 在哪"，不做任何页面决策。
final class Recognizer {

    struct Hit {
        var name: String
        var rect: CGRect          // UIKit 坐标（左上原点，基准分辨率）
        var score: Double
        var evidence: String
        var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }

    private var tplCache: [String: UIImage] = [:]
    private let tplDir: URL

    init(templatesDir: URL) {
        self.tplDir = templatesDir
    }

    // MARK: - OCR

    /// 对整帧做一次 OCR ⇒ 返回 (文字, 归一化 bbox, 置信度)
    /// ⚠️ Vision 的 bbox 原点在**左下**，这里**转成左上原点**的归一化坐标。
    func ocr(_ img: UIImage, minConfidence: Double = 0.5) -> [(String, CGRect, Double)] {
        guard let cg = img.cgImage else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = false      // ⚠️ Vision 对中文不支持 language correction
        req.minimumTextHeight = 0.0

        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return []
        }
        guard let obs = req.results else { return [] }

        var out: [(String, CGRect, Double)] = []
        for o in obs {
            guard let top = o.topCandidates(1).first else { continue }
            if Double(top.confidence) < minConfidence { continue }
            let bb = o.boundingBox                     // 归一化，原点左下
            // ⭐ 关键转换：左下原点 → 左上原点
            let r = CGRect(x: bb.minX,
                           y: 1.0 - bb.maxY,
                           width: bb.width,
                           height: bb.height)
            out.append((top.string, r, Double(top.confidence)))
        }
        return out
    }

    /// OCR 找词（支持 ROI 过滤 + 最少命中数）
    /// `roi` 是**基准分辨率**下的像素框（451×977），返回坐标也是基准像素。
    func findWords(_ img: UIImage, words: [String], roi: CGRect?,
                   minHits: Int = 1, minConfidence: Double = 0.5) -> Hit? {
        let size = img.size
        let all = ocr(img, minConfidence: minConfidence)
        var matched: [(String, CGRect)] = []
        for (txt, nb, _c) in all {
            // 转成基准像素
            let px = CGRect(x: nb.minX * size.width, y: nb.minY * size.height,
                            width: nb.width * size.width, height: nb.height * size.height)
            if let r = roi, !r.intersects(px) { continue }
            for w in words where txt.contains(w) {
                matched.append((txt, px))
                break
            }
        }
        guard matched.count >= minHits else { return nil }
        // 把所有命中的框并起来
        var u = matched[0].1
        for (_, r) in matched.dropFirst() { u = u.union(r) }
        return Hit(name: "ocr", rect: u, score: 1.0,
                   evidence: matched.map { $0.0 }.joined(separator: "/"))
    }

    // MARK: - 模板匹配

    private func tpl(_ name: String) -> UIImage? {
        if let c = tplCache[name] { return c }
        let u = tplDir.appendingPathComponent(name)
        guard let d = try? Data(contentsOf: u), let im = UIImage(data: d) else { return nil }
        tplCache[name] = im
        return im
    }

    /// 单模板匹配（灰度 + 可选 ink 掩码）⇒ 返回最佳位置的**基准像素**框 或 nil
    ///
    /// 📏 算法与 `_1765_match.py` 一致：
    ///   ① 转灰度  ② 只看模板"有墨"的像素（ink mask，避开白底噪声）
    ///   ③ 在 ROI 内滑窗算 NCC  ④ 取最高分，低于阈值 ⇒ nil
    func matchTemplate(_ img: UIImage, tplName: String, roi: CGRect?,
                       threshold: Double, mask: String?) -> (CGRect, Double)? {
        guard let t = tpl(tplName) else { return nil }
        guard let g = gray(img), let tg = gray(t) else { return nil }

        let W = g.w, H = g.h, TW = tg.w, TH = tg.h
        guard TW > 2, TH > 2, TW <= W, TH <= H else { return nil }

        let search = roi ?? CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))
        let x0 = max(0, Int(search.minX)), y0 = max(0, Int(search.minY))
        let x1 = min(W - TW, Int(search.maxX)), y1 = min(H - TH, Int(search.maxY))
        guard x1 >= x0, y1 >= y0 else { return nil }

        // 掩码：只用模板里"有墨"的像素
        var maskIdx: [Int] = []
        if mask == "ink" {
            for j in 0..<TH {
                for i in 0..<TW where tg.p[j * TW + i] < 128 {
                    maskIdx.append(j * TW + i)
                }
            }
            if maskIdx.count < 30 { maskIdx = [] }   // 墨太少 ⇒ 不用掩码
        }

        var best = -2.0
        var bestX = x0, bestY = y0

        // 预计算模板的均值和方差（在掩码上）
        let useMask = !maskIdx.isEmpty
        var tSum = 0.0, tSum2 = 0.0
        let n = useMask ? maskIdx.count : TW * TH
        if useMask {
            for k in maskIdx { let v = Double(tg.p[k]); tSum += v; tSum2 += v * v }
        } else {
            for k in 0..<(TW * TH) { let v = Double(tg.p[k]); tSum += v; tSum2 += v * v }
        }
        let tMean = tSum / Double(n)
        let tVar = max(1e-6, tSum2 / Double(n) - tMean * tMean)
        let tStd = tVar.squareRoot()

        for y in y0...y1 {
            for x in x0...x1 {
                var sSum = 0.0, sSum2 = 0.0, cross = 0.0
                if useMask {
                    for k in maskIdx {
                        let ti = k
                        let si = (y + ti / TW) * W + (x + ti % TW)
                        let sv = Double(g.p[si]); let tv = Double(tg.p[ti])
                        sSum += sv; sSum2 += sv * sv; cross += sv * tv
                    }
                } else {
                    for j in 0..<TH {
                        let srow = (y + j) * W + x
                        let trow = j * TW
                        for i in 0..<TW {
                            let sv = Double(g.p[srow + i]); let tv = Double(tg.p[trow + i])
                            sSum += sv; sSum2 += sv * sv; cross += sv * tv
                        }
                    }
                }
                let sMean = sSum / Double(n)
                let sVar = max(1e-6, sSum2 / Double(n) - sMean * sMean)
                let sStd = sVar.squareRoot()
                let ncc = (cross / Double(n) - sMean * tMean) / (sStd * tStd)
                if ncc > best { best = ncc; bestX = x; bestY = y }
            }
        }

        guard best >= threshold else { return nil }
        return (CGRect(x: CGFloat(bestX), y: CGFloat(bestY),
                       width: CGFloat(TW), height: CGFloat(TH)), best)
    }

    /// 模板池匹配（多张模板取最优）—— ⭐ **多布局的答案**（`_note_1765` 的结论）
    func poolMatch(_ img: UIImage, tplNames: [String], roi: CGRect?,
                   threshold: Double, mask: String?) -> (CGRect, Double, String)? {
        var best: (CGRect, Double, String)?
        for n in tplNames {
            if let (r, s) = matchTemplate(img, tplName: n, roi: roi,
                                          threshold: threshold, mask: mask) {
                if best == nil || s > best!.1 { best = (r, s, n) }
            }
        }
        return best
    }

    // MARK: - 灰度

    struct Gray { var p: [UInt8]; var w: Int; var h: Int }

    func gray(_ img: UIImage) -> Gray? {
        guard let cg = img.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h)
        guard let cs = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        guard let ctx = CGContext(data: &buf, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return Gray(p: buf, w: w, h: h)
    }
}
