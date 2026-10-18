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
#include <ncnn/c_api.h>

#endif /* PGAgent_Bridging_Header_h */
