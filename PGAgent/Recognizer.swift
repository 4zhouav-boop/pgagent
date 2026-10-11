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

    /// ⭐⭐ **OCR 放大倍数**（对齐电脑端 `ks_io.py` 第 49 行 `SCALE = 2`）
    ///
    /// ## 为什么必须放大（§2253 对齐电脑端水平）
    /// 电脑端原文（`ks_io.py::words` 第 169 行）：
    /// ```python
    /// big = c.resize((w * SCALE, h * SCALE), Image.LANCZOS)   # ⭐ 放大后再 OCR
    /// res, _e = _ocr_engine()(np.array(big))
    /// xs = [p[0] / SCALE for p in pts]                        # 坐标再除回去
    /// ```
    /// ⇒ **小字放大后才认得出**。我原来直接喂原尺寸 ⇒ 明显弱于电脑端。
    static let ocrScale: CGFloat = 2.0

    /// 对整帧做一次 OCR ⇒ 返回 (文字, **基准像素** bbox, 置信度)
    ///
    /// ⚠️ **坐标是基准像素（451×977 尺度），⛔ 不是归一化 0..1**（§2253 改了契约）。
    ///    理由：全项目（ROI / 模板 / 点击坐标）都用基准像素 ⇒ 统一一种尺度，
    ///    ⛔ 免得每处都要 `× size`（那正是 §2241 尺度 bug 的温床）。
    ///
    /// ⭐ 本函数**总是整屏 OCR**。要「只在某块区域找」（电脑端的**先裁再 OCR**）
    ///   请用 `findWords(..., roi:)` —— 它会**真的裁图**再调 `ocrRegion`，
    ///   ⛔ 不是"整屏 OCR 完再按 roi 过滤"（那样慢 10 倍，电脑端 §1512 实测）。
    func ocr(_ img: UIImage, minConfidence: Double = 0.5) -> [(String, CGRect, Double)] {
        ocrRegion(img, rect: nil, minConfidence: minConfidence)
    }

    /// ⭐⭐ **先裁再 OCR**（对齐电脑端 `words(img, box)`）
    ///
    /// - Parameter rect: **基准像素**下的裁剪框；`nil` = 整屏
    /// - Returns: `(文字, **基准像素** bbox, 置信度)` —— ⚠️ 与 `ocr()` 不同，
    ///   这里返回的是**绝对像素坐标**（已加回裁剪偏移），调用方不用再换算。
    ///
    /// ## 两个关键做法（都照电脑端抄）
    /// ① **先裁**：`c = img.crop(box)` 后再 OCR ⇒ 快（电脑端实测 20~100ms vs 整屏 2329ms）
    /// ② **放大 `ocrScale` 倍**再 OCR，坐标**除回去** ⇒ 小字才认得出
    func ocrRegion(_ img: UIImage,
                   rect: CGRect?,
                   minConfidence: Double = 0.5) -> [(String, CGRect, Double)] {
        let base = norm(img)                    // ① 归一到 451×977（§2241）
        let baseW = base.size.width, baseH = base.size.height

        // ② 决定裁剪框（基准像素，夹在图像内）
        var crop = CGRect(x: 0, y: 0, width: baseW, height: baseH)
        if let r = rect {
            crop = r.intersection(crop)
            if crop.width < 2 || crop.height < 2 { return [] }
        }
        guard let cgAll = base.cgImage else { return [] }
        // 基准 451×977 与 cg 像素的比（norm 已强制 scale=1 ⇒ 通常 1:1）
        let px = CGFloat(cgAll.width) / max(baseW, 1)
        let cropPx = CGRect(x: crop.minX * px, y: crop.minY * px,
                            width: crop.width * px, height: crop.height * px)
        guard let cgCrop = cgAll.cropping(to: cropPx) else { return [] }

        // ③ ⭐ 放大 ocrScale 倍（照电脑端 LANCZOS 语义；CoreGraphics 高质量插值）
        let outW = Int(cropPx.width * Self.ocrScale)
        let outH = Int(cropPx.height * Self.ocrScale)
        guard outW > 2, outH > 2 else { return [] }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(cgCrop, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        guard let bigCG = ctx.makeImage() else { return [] }

        // ④ Vision
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        req.usesLanguageCorrection = false      // ⚠️ Vision 对中文不支持 language correction
        req.minimumTextHeight = 0.0
        let handler = VNImageRequestHandler(cgImage: bigCG, options: [:])
        do { try handler.perform([req]) } catch { return [] }
        guard let obs = req.results else { return [] }

        // ⑤ 坐标换算：Vision 归一化(左下原点) → 放大图像素 → 除回放大 → 加裁剪偏移
        let sc = Self.ocrScale
        var out: [(String, CGRect, Double)] = []
        for o in obs {
            guard let top = o.topCandidates(1).first else { continue }
            if Double(top.confidence) < minConfidence { continue }
            let bb = o.boundingBox                     // 归一化，原点**左下**
            let w = CGFloat(outW), h = CGFloat(outH)
            // 放大图里的左上原点像素框
            let x = bb.minX * w
            let y = (1.0 - bb.maxY) * h
            let bw = bb.width * w
            let bh = bb.height * h
            // ⭐ 除回放大倍数 + 加裁剪偏移 ⇒ **基准像素绝对坐标**
            let r = CGRect(x: crop.minX + x / sc,
                           y: crop.minY + y / sc,
                           width: bw / sc,
                           height: bh / sc)
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
        // ⭐⭐ **先裁再 OCR**（对齐电脑端 `ks_io.py::words(img, box)`）
        //
        // 电脑端原文（第 151 行）：
        //   「⛔⛔ 为什么必须**先裁**（§1512 实测，用户 10-04 质问"用我一半 CPU"）：
        //      旧写法是"**先整屏 OCR、再按 box 过滤**"⇒ 每次查一条细带都要付一次**整屏**的钱。
        //      真机实测：整屏 1137~3487ms（均 2329ms），而"细带"居然也是 509~881ms
        //      ⇒ 生产脚本 `txt()` 是**先裁再 OCR**（实测 **20~100ms**）。」
        // ⇒ 我原来就是"整屏 OCR 再过滤" ⇒ 慢 10 倍。现在改成**真的裁图**。
        //
        // ⚠️ 但保留**兜底**：若带 roi 裁完**一个词都没命中**，再跑一次整屏。
        //    理由：窄条 OCR（电脑端也记了这坑）偶尔会漏；宁可慢一点也别漏检。
        var all: [(String, CGRect, Double)] = []
        if let r = roi {
            all = ocrRegion(img, rect: r, minConfidence: minConfidence)
            if all.isEmpty {
                // 兜底：整屏一次（roi 之外也可能有这个词，交给下层按 roi 过滤）
                all = ocrRegion(img, rect: nil, minConfidence: minConfidence)
            }
        } else {
            all = ocrRegion(img, rect: nil, minConfidence: minConfidence)
        }

        // ⚠️ `ocrRegion` 已返回**基准像素绝对坐标** ⇒ 这里不用再乘 size
        var perWord: [String: CGRect] = [:]     // ⭐ 每个词**各自**的命中框（去重）
        var matched: [(String, CGRect)] = []
        for (txt, px, _c) in all {
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

    /// ⭐ 模板**质量闸**（照电脑端 `_1765_match.py:40` `MIN_TPL_STD = 6.0`）
    ///
    /// 电脑端原文：
    /// > `MIN_TPL_STD = 6.0`  # ⭐ 模板质量闸（§1762b；实测最平在用模板 11.91）
    ///
    /// ⇒ 方差太低的模板（一片纯色）匹配结果**不可信** ⇒ 直接判为不可用。
    static let minTplStd: Double = 6.0

    /// 单模板匹配（灰度 + 可选 ink 掩码）⇒ 返回最佳位置的**基准像素**框 或 nil
    ///
    /// 📏 算法与 `_1765_match.py` 一致：
    ///   ① 转灰度  ② 只看模板"有墨"的像素（ink mask **带 pad 膨胀**，照 MaaFW 语义）
    ///   ③ 在 ROI 内滑窗算 NCC  ④ 取最高分，低于阈值 ⇒ nil  ⑤ **模板质量闸**
    func matchTemplate(_ img: UIImage, tplName: String, roi: CGRect?,
                       threshold: Double, mask: String?) -> (CGRect, Double)? {
        guard let t = tpl(tplName) else { return nil }
        // ⭐⭐ 归一到基准（§2241）—— 否则模板(基准尺度)与帧(1353宽)尺度差 3×，
        //    且 ROI 会按基准值裁在原始帧的最左边 ⇒ **永远匹配不上**
        let img = norm(img)
        guard let g = gray(img), let tg = gray(t) else { return nil }

        let W = g.w, H = g.h, TW = tg.w, TH = tg.h
        guard TW > 2, TH > 2, TW <= W, TH <= H else { return nil }

        // ⭐ **模板质量闸**（照电脑端 `MIN_TPL_STD`）：太"平"的模板不可信
        //   —— 先在**全模板**上算方差（与掩码无关）
        do {
            var s = 0.0, s2 = 0.0
            let n = TW * TH
            for k in 0..<n { let v = Double(tg.p[k]); s += v; s2 += v * v }
            let mean = s / Double(n)
            let std = max(0, s2 / Double(n) - mean * mean).squareRoot()
            if std < Self.minTplStd {
                NSLog("PGAgent 模板闸: %@ 太平面（std=%.2f < %.2f）⇒ 弃用",
                      tplName, std, Self.minTplStd)
                return nil
            }
        }

        let search = roi ?? CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))
        let x0 = max(0, Int(search.minX)), y0 = max(0, Int(search.minY))
        let x1 = min(W - TW, Int(search.maxX)), y1 = min(H - TH, Int(search.maxY))
        guard x1 >= x0, y1 >= y0 else { return nil }

        // 掩码：只用模板里"有墨"的像素（⭐ **带 pad 膨胀**，照 MaaFW `green_mask` 语义）
        //
        // 电脑端原文（`_1765_match.py:79 ink_mask`）：
        //   「墨迹 + pad 邻域参与匹配，其余置 0 ⇒ 效果同 MaaFW 的"只留主体 + 紧邻边缘"」
        //   ⚠️ 「应仅遮盖干扰区域，避免过度涂抹导致**主体边缘特征丢失**」⇒ pad=2（保住抗锯齿边缘）
        var maskIdx: [Int] = []
        if mask == "ink" {
            let pad = 2
            // 先标"有墨"，再对每个墨点把 pad 邻域也算进来（等价 dilate）
            var isInk = [Bool](repeating: false, count: TW * TH)
            for j in 0..<TH {
                for i in 0..<TW where tg.p[j * TW + i] < 128 { isInk[j * TW + i] = true }
            }
            var dil = isInk
            for j in 0..<TH {
                for i in 0..<TW where isInk[j * TW + i] {
                    for dj in -pad...pad {
                        let nj = j + dj
                        guard nj >= 0, nj < TH else { continue }
                        for di in -pad...pad {
                            let ni = i + di
                            guard ni >= 0, ni < TW else { continue }
                            dil[nj * TW + ni] = true
                        }
                    }
                }
            }
            for k in 0..<(TW * TH) where dil[k] { maskIdx.append(k) }
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
