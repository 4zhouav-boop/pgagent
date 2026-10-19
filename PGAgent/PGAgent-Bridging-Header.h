//
//  PGAgent-Bridging-Header.h
//  PGAgent
//
//  ⭐⭐⭐ §3130 **ncnn 的 C 接口桥**
//
//  ## 为什么必须走 C 接口（⛔ 不是 C++ 头）
//  `ncnn.xcframework`（MIT，来自 https://github.com/xiaoshanlin000/NcnnXCFramework，
//  内含 ncnn-20221128）**没有 modulemap**，且主力头文件是 C++（`net.h`/`mat.h`）。
//  Swift **不能**直接跨 C++ 边界 ⇒ 两条路：
//    ① 写 `.mm` Objective-C++ 包装层（多一个文件、多一层内存管理）
//    ② **用 ncnn 官方的 `c_api.h`**（纯 C，函数签名都是 `int ncnn_net_load_param(...)`)
//  ✅ 选 ②：**零包装层**，Swift 直接调 C 函数，出错面最小、与 PC 的调用点一一对应。
//
//  ## 对应 PC 的哪段
//  `_1377_ad_loop.py::_x_net`（L1686）里那几行：
//  ```python
//  net = ncnn.Net()
//  net.opt.num_threads = AISJ_YOLO_THREADS      # 4
//  net.opt.use_vulkan_compute = False
//  net.load_param(p); net.load_model(b)
//  ```
//  ⇒ 在 Swift 里就是 `ncnn_net_create` + `ncnn_option_set_num_threads` +
//    `ncnn_net_load_param` + `ncnn_net_load_model`（见 `KGXNet.swift`）。
//

#ifndef PGAgent_Bridging_Header_h
#define PGAgent_Bridging_Header_h

// ncnn 官方 C API（纯 C；头文件只依赖 stddef.h / stdint.h）
//
// ⛔⛔⛔ §3176 **include 路径要带 `ncnn/` 前缀**（真机 CI 血案，2026-10-19）
//   `error: 'ncnn/c_api.h' file not found`（CI run 39147116476）
//
// 📏 结构实测（`ncnn.framework` 官方 20260526 包）：
// ```
//   ncnn.framework/Versions/A/Headers/ncnn/c_api.h      ← 头文件都在 **ncnn/ 子目录**下
//   ncnn.framework/Versions/A/ncnn                      ← 静态库
// ```
//   ⇒ 正确写法是 `<ncnn/c_api.h>`，**前提是 framework 的 `Headers` 目录进了头文件搜索路径**。
//   ⚠️ 我上一版用的是第三方 `ncnn.xcframework`，它的头文件**直接在 Headers 根**（`Headers/c_api.h`），
//      所以当时 `<ncnn/c_api.h>` 反而是错的 —— 换包必须同步换 include 路径。
// ✅ 现在这个就是对的；**同时**在 project.yml 里给 `HEADER_SEARCH_PATHS` 补
//    `$(SRCROOT)/ncnn.framework/Versions/A/Headers`（framework 类型不自动加 `-I`）。
#include <ncnn/c_api.h>

#endif /* PGAgent_Bridging_Header_h */
