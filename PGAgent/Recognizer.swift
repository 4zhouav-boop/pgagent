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
///
/// ═══════════════════════════════════════════════════════════════════════
/// ⭐⭐⭐⭐⭐ §2241 **本类内部统一做帧归一化**（这是「全部认成 unknown」的修复）
/// ═══════════════════════════════════════════════════════════════════════
/// ## 病根
/// 帧是 **1353×2925**，而所有 ROI / 模板 / 坐标都是按**基准 451×977** 量的 ⇒
/// ① OCR 的 px 落在 0~2925，与 ROI(62~140) **永不相交** ⇒ 全被 `continue` 丢掉
/// ② 模板尺度差 **3.0×** ⇒ NCC 永远匹配不上
/// ⇒ `pageHere` 全不命中 ⇒ **unknown ⇒ 退出**。
///
/// ## 为什么**在识别层**归一（而不是每个调用点）
/// 识别层是**唯一**同时用到「ROI」和「模板尺度」的地方 ⇒
/// 在这里归一，**所有**调用者（Navigator / Runner / APIRouter / FeatureEngine）
/// 自动都对了，⛔ 不用逐个改（也不怕将来漏一个）。
/// ✅ 与 PC 的 `normalize_frame`（§1627）**同一策略**：只改"看"的坐标系。
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

    /// ⭐ 诊断：最近一次识别用的帧尺寸（`/recogdiag` 回显，排查"尺度对不对"）
    private(set) var lastRawSize = CGSize.zero
    private(set) var lastNormSize = CGSize.zero
    /// ⭐ 把归一化日志转给上层（Runner 的日志窗）
    var onLog: ((String) -> Void)?

    init(templatesDir: URL) {
        self.tplDir = templatesDir
    }

    /// ⭐⭐ **所有识别入口都要先过这里**：把帧归一到基准 451×977
    ///
    /// ⚠️ 幂等：已经是基准 ⇒ 原样返回（`normalize` 内部判等，⛔ 不重绘）
    private func norm(_ img: UIImage) -> UIImage {
        lastRawSize = img.size
        let out = FrameNormalizer.normalizeOnce(img) { [weak self] s in
            self?.onLog?(s)
        }
        lastNormSize = out.size
        return out
    }

    // MARK: - OCR

    /// 对整帧做一次 OCR ⇒ 返回 (文字, 归一化 bbox, 置信度)
    /// ⚠️ Vision 的 bbox 原点在**左下**，这里**转成左上原点**的归一化坐标。
    func ocr(_ img: UIImage, minConfidence: Double = 0.5) -> [(String, CGRect, Double)] {
        // ⭐⭐ 先归一到基准（否则后面所有 ROI 都不相交）
        let img = norm(img)
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

    /// OCR 找词（支持 ROI 过滤 + 最少命中数 + **容错匹配**）
    /// `roi` 是**基准分辨率**下的像素框（451×977），返回坐标也是基准像素。
    ///
    /// ⭐ 容错匹配（§1821 实测必要）：Vision 对中文小字常认错形近字
    ///   实测例子：「259金**币**」被认成「259金**市**」、「**联**系信息」→「**眹**系信息」
    ///   ⇒ 精确 `contains` 会漏检 ⇒ 用**编辑距离 + 字符重合率**兜底
    ///
    /// ## ⭐⭐ `minHits` 的两种语义（§2247）
    /// 老实现只数「**命中的文字框总数**」——拿它做**形态判据**是错的：
    /// 想让「不允许」**和**「允许」都出现时，同一个框里出现两次
    /// （或两个词都落在同一个框）也会满足，**区分度不够**。
    ///
    /// ⇒ 现在按**意图**自动分：
    /// · `minHits <= 1`（默认）⇒ 任一词命中即可（**放过**语义，最常用）
    /// · `minHits >= 2`       ⇒ 要求命中 **`minHits` 个不同的词**
    ///   （= 「这些词**都要**出现」⇒ 用于**形态判据**，如系统弹窗的双按钮）
    func findWords(_ img: UIImage, words: [String], roi: CGRect?,
                   minHits: Int = 1, minConfidence: Double = 0.5) -> Hit? {
        // ⭐ 归一化后，`size` **就是** 451×977 ⇒ 下面的 px 换算自动落在基准尺度
        let norm = self.norm(img)
        let size = norm.size
        let all = ocr(norm, minConfidence: minConfidence)
        var perWord: [String: CGRect] = [:]     // ⭐ 每个词**各自**的命中框（去重）
        var matched: [(String, CGRect)] = []
        for (txt, nb, _c) in all {
            // 转成基准像素（⚠️ 必须用**归一化后**的 size，见 §2241）
            let px = CGRect(x: nb.minX * size.width, y: nb.minY * size.height,
                            width: nb.width * size.width, height: nb.height * size.height)
            if let r = roi, !r.intersects(px) { continue }
            for w in words where Self.fuzzyContains(txt, w) {
                matched.append((txt, px))
                // ⭐ 记录「这个词命中了」，并把它自己的框并起来
                if let p = perWord[w] { perWord[w] = p.union(px) } else { perWord[w] = px }
                break
            }
        }
        guard !matched.isEmpty else { return nil }

        if minHits >= 2 {
            // ⭐⭐ 形态判据：必须命中 **minHits 个不同的词**
            guard perWord.count >= minHits else { return nil }
            // 用**命中的这些词**的框并入（⛔ 不掺没命中的）
            var u = perWord.values.first!
            for r in perWord.values.dropFirst() { u = u.union(r) }
            return Hit(name: "ocr", rect: u, score: 1.0,
                       evidence: perWord.keys.sorted().joined(separator: "/")
                                 + " ⇒ " + matched.map { $0.0 }.joined(separator: "/"))
        }

        // 默认：任一词命中即可
        var u = matched[0].1
        for (_, r) in matched.dropFirst() { u = u.union(r) }
        return Hit(name: "ocr", rect: u, score: 1.0,
                   evidence: matched.map { $0.0 }.joined(separator: "/"))
    }

    /// ⭐ 容错包含：先精确，再编辑距离兜底
    /// 规则（保守，⛔ 不放松到误检）：
    ///   · 精确包含 ⇒ 直接过
    ///   · 关键词 ≥3 字时，允许**最多 1 个字的差异**（编辑距离 ≤1）
    ///   · 关键词 =2 字时，要求**逐字相同**（2 字容错太容易误检）
    static func fuzzyContains(_ hay: String, _ needle: String) -> Bool {
        if needle.isEmpty { return false }
        if hay.contains(needle) { return true }
        let n = Array(needle)
        guard n.count >= 3 else { return false }
        let h = Array(hay)
        guard h.count >= n.count else { return false }
        // 在 hay 上滑一个 n.count 长的窗，算最小编辑距离
        for start in 0...(h.count - n.count) {
            let win = Array(h[start..<(start + n.count)])
            if editDistance(win, n) <= 1 { return true }
        }
        return false
    }

    /// 标准 Levenshtein（短串，直接 DP）
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[b.count]
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
        // ⭐⭐ 归一到基准（§2241）—— 否则模板(基准尺度)与帧(1353宽)尺度差 3×，
        //    且 ROI 会按基准值裁在原始帧的最左边 ⇒ **永远匹配不上**
        let img = norm(img)
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
