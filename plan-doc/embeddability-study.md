# P0 · Sirius 作为 Doris 计算运行时库的可嵌入性调研

> 日期：2026-09-01 · 状态：**P0 完成，结论见 §0**
> 代码基线：Sirius `dev` @ `84ea4ab5`；Doris `wt-gpu` @ `df36be5a86d`
> 实测基线：真实二进制 —— `apache/doris:be-4.1.3`（linux/arm64，本机 Docker 镜像）与 Sirius CI 产物
> `sirius-v1.5.5-extension-linux_arm64-cuda13`（Distribution workflow run `33406987495`，`dev` 分支 2026-08-31 push）
> 实验脚本与结果摘要：[`experiments/p0.4-symbol-isolation/`](experiments/p0.4-symbol-isolation/)

回答 `tasklist.md` P0.1–P0.7 的七个子问题。每一节先给结论，再给证据（带文件:行号或实验输出），最后给代码量量级。

---

## 0. TL;DR

**结论：进程内嵌入在依赖/链接层面是可行的，而且比 handoff 里估计的要近得多 —— 但「可行」有明确的前提条件，前提不满足时是实测会崩的。**

1. **三个「阻断性缺口」的真实大小都不大**（合计 Sirius 侧 ≈ 1.3–1.6k 行生产代码 + ≈ 0.6k 行测试，见 §8.1）：
   - `push_arrow`：≈ 150 行 FFI 胶水，**不需要动 cuCascade**，`cudf::from_arrow_host` 已在依赖闭包里但未被使用（§4）。
   - C ABI：≈ 800 行纯 shim，**不需要改任何内部实现**（现有接口已是 PIMPL）（§3）。
   - 可分发 libsirius：CI **今天已经在产出一个单文件、依赖全静态的 DSO**（`sirius.duckdb_extension`，vcpkg 构建，520 MB），缺的是链接约束、头文件、版本化和发布渠道，≈ 150–250 行 CMake/YAML（§2）。
2. **依赖闭包冲突的真实形态和 handoff 猜的不一样**（§5）：
   - protobuf / abseil / arrow **都不是问题**：Sirius 把 protobuf 3.19.4 源码 vendor 进扩展并隐藏可见性；abseil 有 `lts_YYYYMMDD` inline namespace，跨版本符号名本来就不同；Sirius 闭包里根本没有 Arrow C++（cudf 用 nanoarrow）。真实产物预加载进真实 BE：**这三者绑定到 BE 的符号数为 0**。
   - **真正的冲突面是 libstdc++**：Doris BE 用 `ENABLE_EXPORTS`（= `-rdynamic`）导出了 **475,722 个符号**，其中 50,662 个是它静态链接的 libstdc++。Sirius 产物动态依赖 `libstdc++.so.6`，它的 259 个带版本的 `GLIBCXX_*` 引用在 BE 里**全部绑到了 BE 私有的那份 libstdc++**（实测 549 个 libstdc++ + 22 个 `__cxa_*` + 10 个 operator new/delete 绑到 `doris_be`，系统 `libstdc++.so.6` 只用了 1 个符号）。今天这能工作，是因为 Doris 的 libstdc++ 恰好比 Sirius 需要的新且 ABI 兼容 —— 这是**靠运气**，不是靠设计。
   - 合成矩阵实测：conda/pixi 风格（动态依赖）的插件进 `-rdynamic` 宿主 **直接 abort**；`RTLD_DEEPBIND` 能救活但把 malloc 也劈成两套；C++ 异常跨界在两套运行时下**必崩**。全静态 + 隐藏可见性 + 静态 libstdc++ 的插件对宿主导出什么**完全免疫**。
3. **所以 libsirius 的交付形态必须满足四条链接约束**（§5.5），这是提给 Sirius 的核心诉求之一，比 C ABI 本身更重要。
4. **A/B 建议**（§8.3）：MVP-1/2 走进程内（B），生产硬化切边车；边车方案 Doris 侧**已有现成先例**（Python UDF 走 Arrow Flight 的 fork 子进程 + 健康检查），worker 侧可以复用 Sirius 已有的 Rust 外壳。两条路线共享同一个 libsirius 产物和同一个 `push_arrow`，投入不浪费。
5. **本机能验证的已经验证完了**（ELF 层、加载器层、符号隔离矩阵、接口设计）；**CUDA 运行时层面的一切**（初始化、显存/pinned 内存独占、线程、信号、io_uring）**只能在 GPU 机器上验**（§8.5）。

---

## 1. 证据来源

| 证据 | 来自哪里 | 怎么拿到的 |
|---|---|---|
| Sirius 构建/接口现状 | `CMakeLists.txt`、`cmake/CMakePresets.json`、`src/include/sirius_ffi.hpp`、`src/sirius_ffi.cpp`、`rust/crates/sirius-sys/`、`.github/workflows/distribution.yml`、`vcpkg.json`、`vcpkg_triplets/` | 读代码 |
| Sirius 流输入路径 | `src/exec/stream_session.*`、`src/op/sirius_physical_streaming_source.cpp`、`src/exec/batch_stream.cpp`、cuCascade `data_batch.hpp`/`representation_converter_builtins.cpp`、`src/op/sirius_physical_gpu_values.cpp` | 初始化了 `cucascade`、`substrait` 两个 submodule 后读代码 |
| Sirius 社区已知计划 | issues #1590 / #1303 / #840 / #1276 / #839 | `gh issue view` |
| Doris BE 链接与加载机制 | `be/CMakeLists.txt`、`be/src/service/CMakeLists.txt`、`be/src/util/dynamic_util.cpp`、`be/src/common/phdr_cache.*`、`be/src/runtime/memory/jemalloc_hook.cpp`、`be/src/glibc-compatibility/`、`be/src/udf/python/` | 读代码 |
| **真实 Doris BE 二进制** | `apache/doris:be-4.1.3`（arm64）里的 `doris_be`（2.1 GB） | `readelf`（`experiments/.../analyze_doris_be.sh`） |
| **真实 Sirius 产物** | CI artifact `sirius.duckdb_extension`（520 MB） | `gh run download` + `readelf`（`analyze_sirius_artifact.sh`） |
| **实验 A：真实产物 × 真实 BE** | 上两者 | 桩 CUDA 库满足 DT_NEEDED 后 `LD_PRELOAD` 进 `doris_be`，`LD_DEBUG=bindings` 记录每个符号绑到哪（`gen_stubs.sh` + `run_preload.sh`） |
| **实验 B：合成矩阵** | Ubuntu 24.04 arm64 容器 | 2 种宿主 × 5 种插件 × 3 种 dlopen flag × 3 种测试 = 90 例（`synthetic-matrix/`） |

本机没有 GPU，所有实验都不需要 GPU：动态链接的行为是 ld.so 的属性，不是 CUDA 的属性。

---

## 2. P0.1 · 产物现状盘点

### 2.1 今天 libsirius 是什么

**没有叫 libsirius 的 target。** `CMakeLists.txt:508-509` 用 DuckDB 的两个宏产出两个东西：

```cmake
build_static_extension(sirius ${EXTENSION_SOURCES} ${CUDA_SOURCES})     # → libsirius_extension.a（给 duckdb shell 静态链）
build_loadable_extension(sirius CPP ${EXTENSION_SOURCES} ${CUDA_SOURCES}) # → sirius.duckdb_extension（一个 .so）
```

- `install()` 只有一处（`:659`），把 `sirius_extension` 等静态库塞进 **DuckDB 的 export set** —— 服务于 duckdb 自己的构建，不是给外部项目用的。没有头文件 install，没有版本号，没有 SONAME。
- `sirius_ffi.hpp` 的符号靠 `SIRIUS_FFI_EXPORT`（`__attribute__((visibility("default")))`）从 loadable extension 的 `-fvisibility=hidden` 里「漏」出来（`sirius_ffi.hpp:23-26` 自己写明了这是过渡状态）。
- DuckDB 对 Linux loadable extension 的链接规则（duckdb v1.5.5 `extension/extension_build_tools.cmake`）：`CXX_VISIBILITY_PRESET hidden` + `-Wl,--gc-sections -Wl,--exclude-libs,ALL`。Sirius 额外强制 `LINKER_TYPE BFD`（`:522`），原因是 mold 会把 RMM 的 `STB_GNU_UNIQUE` 注册表符号藏掉。

### 2.2 现有嵌入方 sirius-sys 的前提

`rust/crates/sirius-sys/build.rs` 的逻辑：在 `$SIRIUS_BUILD_DIR/extension/sirius/` 里找 `libsirius.so`；找不到就**把 `sirius.duckdb_extension` 软链成 `libsirius.so`**（`resolve_lib_dir`），然后 `-lsirius` + 把 `$CONDA_PREFIX/lib` 加进搜索路径（因为默认构建的扩展 `DT_NEEDED` 一堆 conda 的 .so）。`static` feature 声称链 `libsirius.a`「fully static vcpkg build」，**但 CMake 里没有任何地方产出 `libsirius.a`**，这个 feature 今天不可用。

前提总结：**同一个构建树 + 同一套 conda 工具链 + cxx.rs 共编**。而且 cxx 桥（`sirius-sys/src/lib.rs`）只绑了 `Context`（3 个函数），`Fragment` 整个类都没绑。

### 2.3 两种构建口味

| | pixi/conda 默认（`make`） | vcpkg（`ci-release`，`distribution.yml`） |
|---|---|---|
| 依赖 | conda 的 `libcudf.so` / `libcuvs.so` / `libabsl_*.so` / `libspdlog.so` / `libcurl` / `libssl` / `liburing` … 全部动态 | `VCPKG_LIBRARY_LINKAGE static`，cudart 静态（`CMAKE_CUDA_RUNTIME_LIBRARY Static`），`CMAKE_SKIP_RPATH ON` |
| 用途 | 开发、测试、`sirius-sys` | 发行 |
| 产物 | 带 conda RPATH 的 .so，离开 conda 环境不可用 | **单文件 .so**，上传为 GitHub Actions artifact（4 个变体：amd64/arm64 × cuda12/13），仅保留 90 天，无 Release/tag |
| 是否能被 Doris 用 | ❌（依赖闭包 + RPATH） | ✅ 接近可用（见下） |

（conda 口味的依赖闭包是从 CMake 推断的，本机没法编；vcpkg 口味是实测。）

### 2.4 真实 vcpkg 产物解剖（linux_arm64 · cuda13）

| 项 | 值 |
|---|---|
| 大小 | 519,749,318 B（artifact zip 327 MB）；`.nv_fatbin` **302 MB**（8 个 arch 的 fatbin）、`.text` 85 MB、`.rodata` 23 MB、`.symtab` 10.6 MB，未 strip |
| `DT_NEEDED`（19 个） | **libstdc++.so.6、libgcc_s.so.1**、libgomp.so.1、libcuda.so.1、libnvidia-ml.so.1、libcublas.so.13、libcublasLt.so.13、libcusolver.so.12、libcusparse.so.12、libcurand.so.10、libnvrtc.so.13、libnvJitLink.so.13、libc/libm/libdl/libpthread/librt/libutil、ld-linux |
| **不在** DT_NEEDED（已静态） | cudart、cudf、rmm、cuCascade、nvcomp、kvikio、nanoarrow、abseil（`lts_20250814`）、protobuf（vendor 3.19.4）、openssl、curl、liburing、numa、spdlog、yaml-cpp、DuckDB 本体 |
| glibc / libstdc++ 要求 | `GLIBC_2.28`、`GLIBCXX_3.4.22`、`CXXABI_1.3.11` 为最高需求 |
| 导出符号（1,626） | `sirius::ffi` 29、DuckDB 入口 3、`sirius::` 其它 122、`cudf::` 165、`rmm::` 4、protobuf 14、**libstdc++ 模板实例 767**、`GNU_UNIQUE` 58（thrust/raft/cuda::mr/std::regex 的静态局部变量）、TLS 2 |
| 导入符号（772） | `@GLIBC_` 374、**`@GLIBCXX_` 259、`@CXXABI_` 43、`@GCC_` 14**、CUDA 库 68 |

三个要点：

1. 「全静态」不是全静态：**libstdc++/libgcc 是动态的**，5 个 CUDA 数学库（来自 cuvs/raft，服务于 VSS/ANN 特性 #1205）+ nvrtc/nvJitLink（JIT）+ libgomp 也是动态的。后者是 C ABI，不与 Doris 冲突，但**部署时必须在 BE 机器上提供**（CUDA toolkit 运行库 ≈ 1 GB+）。libgomp 虽在 DT_NEEDED 里但**一个 GOMP/omp 符号都没导入**（桩库 0 符号也能 `LD_BIND_NOW` 加载成功），是 raft/cuvs 链接接口带进来的死依赖。
2. 导出面泄漏了 ~1,600 个非接口符号。`RTLD_LOCAL` 下别人看不见它们，但 58 个 `GNU_UNIQUE` 是进程全局唯一的，且会让 DSO 不可 `dlclose`。需要 version script 收口。
3. **导入面才是危险的**：259 个带版本的 libstdc++ 引用 + 43 个 CXXABI + 14 个 GCC unwinder 引用，在一个导出了自己静态 libstdc++ 的宿主里会被宿主截获（§5.3 实测）。

### 2.5 从「build tree 共编」到「可分发 .so + headers」缺什么

| # | 缺的步骤 | 量级 | 备注 |
|---|---|---|---|
| 1 | 一个 `libsirius` shared target：复用 loadable extension 的同一组 object，只换链接参数 | ~40 行 CMake | 不能直接复用 `sirius.duckdb_extension`：它必须与 duckdb 宿主共享 libstdc++（异常跨界），而 libsirius 恰恰要**静态** libstdc++ |
| 2 | 链接约束：`-static-libstdc++ -static-libgcc`、静态 libgomp（或去掉 OpenMP）、`-Wl,--exclude-libs,ALL`、version script 只导出 `sirius_*`、`SONAME libsirius.so.<major>` | ~30 行 | §5.5 的四条约束 |
| 3 | C 头文件 `include/sirius/sirius_c.h`（§3） | 见 §3 | |
| 4 | `install(TARGETS libsirius)` + `install(FILES sirius_c.h)` + CPack/tar 打包 + `sirius_version()`/`sirius_abi_version()` | ~60 行 | |
| 5 | CI：在现有 `distribution.yml` 的 vcpkg job 里多产出一个 artifact，并在 tag 时发 GitHub Release（今天无 Release） | ~60 行 YAML | 现有 vcpkg 构建跑在 **无 GPU 的 CPU runner** 上 → libsirius 的构建可在 CI 验证，不需要 GPU |
| 6 | （可选）裁剪 fatbin arch、把 cuvs/raft 做成可选以砍掉 5 个 CUDA 数学库依赖 | 视情况 | 对 Doris 场景 VSS 不是必需 |

**估算：≈ 150–250 行 CMake/YAML，1–3 天，风险低。** 这一项没有技术难点，只有「Sirius 社区是否愿意承诺一个稳定产物」的问题。

---

## 3. P0.2 · C ABI 改造面

### 3.1 现有接口面盘点（`sirius_ffi.hpp`，188 行）

| 类/函数 | 方法数 | 跨界的 std 类型 | 会抛异常 |
|---|---|---|---|
| `Context` | 构造 ×2、析构、`execute_substrait` | `const std::string&` ×2、`std::uintptr_t` | 构造（GPU bring-up）、`execute_substrait` |
| `Fragment` | 析构 + 12 个方法 | `const std::string&`（`declare_input_column` ×2、`build`）、`std::unique_ptr<std::vector<std::string>>`（`output_types`）、`Fragment&`（`relay_from`） | **全部 12 个**（`@throws` 注释） |
| 自由函数 | `make_context`、`make_context_from_config`、`make_fragment`、`stream_view_name` | 返回 `std::unique_ptr<...>`，入参 `const std::string&` | `make_context*` |

合计 **19 个入口**。抛出的异常类型：`sirius::invalid_input_exception`（`src/include/sirius/exception.hpp:47`，继承 `std::runtime_error`）、DuckDB 的 `duckdb::Exception` 系（Substrait 降级/绑定失败）、cudf 的 `cudf::logic_error`/`cudf::cuda_error`、`std::runtime_error`（`SiriusContext::initialize`）。**数据面已经是 C ABI**（`ArrowArrayStream*` 以地址传递）。

### 3.2 为什么 C ABI 是必需的而不是「好看」——实验证据

合成矩阵（§5.4）test2：插件抛 `std::runtime_error`，宿主 `catch (const std::exception&)`：

| 宿主 | 插件 | 结果 |
|---|---|---|
| 静态 libstdc++，不导出 | conda libstdc++（动态） | **abort**（两套运行时，unwinder 找不到 handler） |
| 静态 libstdc++，`-rdynamic` | conda 插件，默认可见性 | 能 catch —— 因为插件所有 std 引用都绑到了宿主那一份，实际是「一套运行时」（但同一形态下 protobuf 大版本不同时 test0 段错误） |
| 静态 libstdc++，`-rdynamic` | conda 插件，`-fvisibility=hidden` | **abort** |
| 静态 libstdc++，`-rdynamic` | 静态隐藏 protobuf + 动态 libstdc++（= 今天真实产物形态） | 能 catch —— 同样是寄生在宿主 libstdc++ 上 |
| 静态 libstdc++，`-rdynamic` | 全静态隐藏（含静态 libstdc++，= 推荐形态） | **abort** |
| 任意 | 任意 + `RTLD_DEEPBIND` | **abort** |

也就是说异常跨界只在「插件寄生在宿主 libstdc++ 上」这一种偶然形态下能工作。Doris BE 今天恰好是这种形态（§5.3），但 libsirius 一旦按 §5.5 改成静态 libstdc++（为了不再依赖这个偶然），异常就必须在边界内捕获。**结论：C ABI 与「静态 libstdc++」是一对，缺一不可。**

### 3.3 设计

原则：不透明句柄 + 整数错误码 + 出参 + 线程局部/对象携带的错误信息；每个入口 `noexcept`，`catch (...)` 转错误码；std 类型不跨界；Arrow C 结构体按指针传；ABI 版本握手。

```c
/* include/sirius/sirius_c.h — 全部 extern "C"，无 C++ 类型 */
#define SIRIUS_C_ABI_VERSION 1
typedef struct sirius_context_t sirius_context_t;
typedef struct sirius_fragment_t sirius_fragment_t;
typedef struct sirius_error_t   sirius_error_t;          /* 携带 code + message + 可选 detail */
typedef enum { SIRIUS_OK = 0, SIRIUS_ERR_INVALID_INPUT, SIRIUS_ERR_PLAN, SIRIUS_ERR_EXEC,
               SIRIUS_ERR_GPU, SIRIUS_ERR_OOM, SIRIUS_ERR_STATE, SIRIUS_ERR_INTERNAL } sirius_status_t;

uint32_t      sirius_abi_version(void);                    /* dlopen 后第一件事 */
const char*   sirius_version(void);                        /* semver + git sha */
const char*   sirius_capabilities_json(void);              /* 方言版本 / 函数 / 关系 / 类型（§6.3 of design.md） */

sirius_status_t sirius_context_create(const char* yaml_path /*nullable*/, sirius_context_t** out, sirius_error_t** err);
void            sirius_context_destroy(sirius_context_t*);
sirius_status_t sirius_context_execute_substrait(sirius_context_t*, const uint8_t* plan, size_t len,
                                                 struct ArrowArrayStream* out, sirius_error_t** err);

sirius_status_t sirius_fragment_create(sirius_context_t*, sirius_fragment_t** out, sirius_error_t** err);
void            sirius_fragment_destroy(sirius_fragment_t*);
sirius_status_t sirius_fragment_declare_input_column(sirius_fragment_t*, uint64_t stream, const char* name, const char* duckdb_type, sirius_error_t**);
sirius_status_t sirius_fragment_declare_input_sender(sirius_fragment_t*, uint64_t stream, uint32_t sender, sirius_error_t**);
sirius_status_t sirius_fragment_declare_output(sirius_fragment_t*, uint64_t stream, sirius_error_t**);
sirius_status_t sirius_fragment_declare_output_broadcast(sirius_fragment_t*, sirius_error_t**);
sirius_status_t sirius_fragment_declare_output_hash_key(sirius_fragment_t*, uint32_t column, sirius_error_t**);
sirius_status_t sirius_fragment_build(sirius_fragment_t*, const uint8_t* plan, size_t len, sirius_error_t**);
sirius_status_t sirius_fragment_push_arrow(sirius_fragment_t*, uint64_t stream, uint32_t sender,
                                           const struct ArrowSchema*, const struct ArrowArray*, sirius_error_t**);  /* §4 */
sirius_status_t sirius_fragment_close_input(sirius_fragment_t*, uint64_t stream, uint32_t sender, sirius_error_t**);
sirius_status_t sirius_fragment_relay_from(sirius_fragment_t* dst, sirius_fragment_t* src, uint64_t src_stream, uint64_t dst_stream, uint32_t sender, size_t* moved, sirius_error_t**);
sirius_status_t sirius_fragment_run(sirius_fragment_t*, sirius_error_t**);                 /* 阻塞；#1590 落地后加 start/join */
sirius_status_t sirius_fragment_result_to_arrow(sirius_fragment_t*, struct ArrowArrayStream* out, sirius_error_t**);
sirius_status_t sirius_fragment_output_types(sirius_fragment_t*, char*** types, size_t* n, sirius_error_t**);  /* sirius_free_strings 释放 */
size_t          sirius_fragment_output_batch_count(sirius_fragment_t*, uint64_t stream);
const char*     sirius_stream_view_name(uint64_t stream, char* buf, size_t cap);

sirius_status_t sirius_error_code(const sirius_error_t*);
const char*     sirius_error_message(const sirius_error_t*);
void            sirius_error_free(sirius_error_t*);
void            sirius_free_strings(char** v, size_t n);
```

约定必须写进头文件：一个进程一个 `sirius_context_t`（`SiriusContext::initialize` 二次调用抛错，`sirius_context.cpp:637`；且引擎按 query 串行）；`push_arrow` 线程安全、可与 `run()` 并发；`run()` 阻塞；所有 Sirius 分配的内存由 `sirius_*_free` 释放（jemalloc 互操作不是契约的一部分，见 §5.3）。

### 3.4 估算

| 文件 | 行数 | 说明 |
|---|---|---|
| `src/include/sirius/sirius_c.h` | ~250 | 含文档注释 |
| `src/sirius_c.cpp` | ~450 | 19 个入口的 shim + `push_arrow`；每个入口 = 参数校验 + `try { ... } catch (invalid_input_exception) / (duckdb::Exception) / (cudf::*) / (std::exception) / (...)` 映射 |
| 错误对象 / capabilities JSON / 版本 | ~100 | capabilities 从 `function_id.cpp` / `aggregate_id.cpp` / 物理计划生成器的拒绝表生成 |
| `test/cpp/ffi/test_sirius_c.cpp` | ~300 | 每个入口正/负例；异常→错误码；`[isolated_context]`（需 GPU） |
| 文档 | ~50 | |
| **合计** | **≈ 1,150（≈ 800 生产）** | **不触碰任何内部实现**：`sirius_ffi.cpp` 已经是 PIMPL，shim 只包一层 |

Doris 侧对应：`runtime/inproc_transport.cpp` 里 dlopen + 一张 `dlsym` 函数表 + ABI 版本握手 ≈ 150 行（走 `dynamic_open()` 而不是裸 `dlopen`，理由见 §5.1）。

---

## 4. P0.3 · 输入口 `push_arrow`

### 4.1 现状（代码出处）

- `stream_session::push(stream_id_t, std::shared_ptr<cucascade::data_batch>)`（`src/include/exec/stream_session.hpp:77`）→ `sirius_physical_streaming_source::push`（`src/op/sirius_physical_streaming_source.cpp:71-74`）→ `batch_stream::push`（`src/exec/batch_stream.cpp:41-53`）：加锁、`repo->add_data_batch()`、`notify_all`、锁外触发 `on_data` 把 source pipeline 自荐进 task creator。**线程安全（S1 不变式），不需要 DuckDB 事务。**
- **source 算子对 tier 无要求**：`get_next_task_input_data()` 只是弹出并包装（`:99-113`，注释 "Pass-through"）；tier 升级在通用层 `pipelineable_operator_data::prepare_for_processing` → `lock_or_prepare_batch` → `convert_to<gpu_table_representation>`（`src/include/pipeline/batch_lock_utils.hpp:126-151`）。`docs/super-sirius/streaming-sessions.md:42-45`："batches cross the boundary natively… in whatever tier they currently sit"。**所以 `push_arrow` 可以推 GPU tier 也可以推 HOST tier 的 batch。**
- `data_batch` 只有一个工厂：`data_batch::make(batch_id, unique_ptr<idata_representation>, probe)`（`cucascade/include/cucascade/data/data_batch.hpp:88-91`）。GPU 表示 `gpu_table_representation(unique_ptr<cudf::table>, memory_space&, writer_stream)`（`cucascade/include/cucascade/cudf/gpu_data_representation.hpp:67-69`，STREAM-LINEAGE 契约 `:53-59`），Sirius 包装为 `sirius::make_data_batch(...)`（`src/include/data/data_batch_utils.hpp:151-164`）。
- **今天没有任何 Arrow / host 指针输入的工厂**：`grep -rn "nanoarrow|to_arrow|from_arrow|ArrowDeviceArray|cudf/interop" src/ cucascade/` = 0 命中。最接近的先例是 DuckDB `DataChunk` → `cudf::table` 的转换器 `src/op/sirius_physical_gpu_values.cpp`（~200 行：按列 staging + `cudaMemcpyAsync` pageable H2D + `cudf::make_strings_column`，`:141-197`），以及 native decoder 的 pinned 批量 H2D（`src/op/scan/duckdb_native_decoder.cpp:684-720, 795-806`，`cudaMemcpyBatchAsync`）。
- **cudf 26.06 的 Arrow interop 已经在闭包里但未使用**：vcpkg port 里 cudf 依赖 `nanoarrow 0.7.0`（`vcpkg_ports/nanoarrow/vcpkg.json`），`libcudf.a` 已含 interop 代码；`cudf/interop.hpp` 前向声明 `ArrowSchema/ArrowArray/ArrowDeviceArray`，调用方不需要 nanoarrow 头。签名（cudf 26.08 文档核对）：

  ```cpp
  std::unique_ptr<table> from_arrow_host(ArrowSchema const*, ArrowDeviceArray const*,
                                         rmm::cuda_stream_view, rmm::device_async_resource_ref);
  unique_device_array_t  to_arrow_host(cudf::table_view const&, rmm::cuda_stream_view, rmm::device_async_resource_ref);
  ```
  注意入参是 `ArrowDeviceArray const*`（`device_type = ARROW_DEVICE_CPU`），不是裸 `ArrowArray*`，FFI 里要包一层。

### 4.2 转换做在哪一层

**FFI 胶水层，不新增 cuCascade representation。** 路径：`ArrowSchema*/ArrowArray*` →（`cudf::from_arrow_host`）→ `unique_ptr<cudf::table>` →（`sirius::make_data_batch`）→ `session().push()`。`relay_from`（`src/sirius_ffi.cpp:685-749`）就是模板：校验 → 循环 push → `close_input`。

不做 `arrow_host_representation` 的理由：HOST tier 是**按 cuCascade 自有块内偏移寻址**的（`column_metadata.hpp:49-52` 的 `data_offset`/`null_mask_offset`，`host_table_allocation` 持有 FSMR 块），host→GPU 转换器只读这些块（`representation_converter_builtins.cpp:1220-1226`），spill 假设自己拥有内存（`host_table.hpp:81` `clone` 在目标 space 重新分配）。要让一个外部指针参与这套体系，得复制 `convert_host_fast_to_gpu`（~60 行）+ `clone()` + 磁盘 tier 转换器，≈ +500 行在 submodule 里，换不到任何 FFI 方案没有的能力。

### 4.3 内存所有权：零拷贝 pin 不可行，H2D 拷贝是必须的

五个独立理由：① HOST tier 偏移寻址（上）；② 转换器只读自有块；③ spill 需要 clone 自有内存；④ **无背压**（§4.5）意味着 batch 可能在队列里躺整个查询周期并被 GPU→host→disk 反复搬，pin 外部内存等于要求 Doris 承诺永不释放；⑤ `cudaHostRegister` 任意 pageable 内存的代价与拷贝同量级。

拷贝本身可优化：`from_arrow_host` 对 pageable 内存是「driver 内部 bounce buffer + 一次 memcpy」（2 跳）；吞吐敏感时先 staging 进 cuCascade pinned 块再 `cudaMemcpyBatchAsync`（native decoder 的做法），或让 Doris 侧用 `cudaHostAlloc` 内存做 Block 的 backing —— 后者对 Doris 侵入太大，MVP 不做。

**一个重要的正面推论**：因为 `push_arrow` 在返回前 `stream.synchronize()`，Doris 侧的 Arrow `release` 回调在**Doris 自己的线程**上、在 `push_arrow` 返回后被调用；Sirius 的线程永远不会回调进 Doris。这直接消掉了 §5.1 里「Sirius 线程没有 ThreadContext，调用 `thread_context()` 会 throw」的一整类风险。

### 4.4 类型对账（`push_arrow` 必须处理的差异）

`sirius::get_cudf_type`（`src/include/cudf/cudf_utils.hpp:158-217`）vs Arrow C：

| 类型 | 差异 | 处置 |
|---|---|---|
| BOOLEAN | Arrow 1 bit/值 vs cudf `BOOL8` 1 byte/值 | `from_arrow_host` 自动展开 |
| VARCHAR | Arrow `utf8` int32 offsets；**cudf 26.06 字符串 offsets 已改为 INT64**（`representation_converter_builtins.cpp:1746`） | `from_arrow_host` 产出 canonical 布局；`large_utf8`/`string_view` 显式处理或拒绝 |
| DECIMAL | Arrow scale 为正、固定 decimal128；cudf scale 为负（`cudf_utils.hpp:198-211`），且**按 precision 选 DECIMAL32/64/128** —— 声明 `DECIMAL(15,2)` 的流期望 DECIMAL64 | 导入后 `cudf::cast` 到声明宽度，否则 schema 校验（`relay_from` 同款）会拒 |
| HUGEINT | 映射 INT64 且静默截断（`:165-175` FIXME） | 拒绝 int128 形状的列（Doris 侧 gate 也拒 LARGEINT） |
| TIMESTAMP 带 tz | Sirius 无对应类型 | 拒绝 |
| LIST | cudf LIST offsets 必须保持 INT32（`:1113-1116`） | 拒绝 `large_list` |
| DICTIONARY | 无 Sirius `logical_type` 对应 | 拒绝或强制解码 |
| NULL | 两边都是 LSB bitmap、1=valid（`sirius_physical_gpu_values.cpp:77-80` 可证） | 规整 `null_count=-1` 与「无 validity buffer」两种情况 |
| 切片 | Arrow 数组可带非零 `offset` | `from_arrow_host` 处理；手写导入常漏 |

### 4.5 背压与内存计费

- `push()` 不需要 reservation（batch 的 representation 自带 `memory_space&`）；**构造**需要：照 result collector 的模式 `make_reservation_or_null(size)`，失败降级到无 reservation 的重载（`sirius_physical_result_collector.cpp:168-192`，`memory-management.md:87-89` 认可的写法）。FFI 线程没有 task reservation → 分配只对 space 容量计费，不归属任何 task。
- **没有背压是设计决定，不是遗漏**：issue #1276（2026-07-23 streaming design review）明确「移除有界 channel 背压，靠 downgrade executor 泄压，等真实负载出现再重新设计」。队列里的 batch 是 downgrade 的候选（`memory-management.md:117`），外部 producer 快过 GPU 的后果是灌满 host 再灌 disk，不会 OOM，但也没有任何东西让它慢下来。**Doris 侧必须自建 in-flight 限流**（`design.md` §4.2(b) 的判断是对的，而且不应指望 Sirius 侧提供）。

### 4.6 估算

| 文件 | 行数 |
|---|---|
| `src/include/sirius_ffi.hpp`：声明 + 文档 | +18 |
| `src/sirius_ffi.cpp`：`pick_gpu_space` / `arrow_payload_bytes` / `reconcile_to_declared`（§4.4 的表）/ `Fragment::push_arrow` | +130 |
| `stream_session` / `streaming_source` / cuCascade | **0** |
| `test/cpp/exec/test_sirius_ffi_push_arrow.cpp`：`cudf::to_arrow_host` 造输入 → push → run → 比对；全类型、空 batch、decimal 宽度、两个 sender、与 `run()` 并发、EOS 后 push、未知 stream | +230 |
| 文档（sessions/fragments） | +30 |
| **合计** | **≈ 410（≈ 150 生产）** |
| 顺手项：结果路径用 `cudf::to_arrow_host` 把 **4 次拷贝**（D2H → DataChunk → ColumnDataCollection → Arrow）压成 1 次 | ~120 生产 + ~80 测试，可选 |
| 若必须接受 STRUCT/LIST | +80（递归对账） |

**这一项是三个缺口里最便宜的，且 Sirius 侧已有对应 issue（#1590 的 push/pull FFI、#839 stream session）**。#1590 的 scope 里还有 `start()/join()` 拆分与 `export_packed/push_packed/StagingArena` 跨进程传输 —— 后者正是边车方案需要的。

---

## 5. P0.4 · 依赖闭包与符号冲突（实测）⚠️

### 5.1 Doris BE 侧的事实（真实二进制 + 源码）

| 事实 | 证据 |
|---|---|
| BE **导出全部符号**：dynsym 定义 **475,722** 个（导入仅 607 个，全部 `@GLIBC_2.17`） | `readelf --dyn-syms doris_be`；来源是 `be/src/service/CMakeLists.txt:68` `set_target_properties(doris_be PROPERTIES ENABLE_EXPORTS 1)`（= `-rdynamic`），目的是让 **native UDF** 的 .so 能回绑 BE 的符号（`:78-81` 注释） |
| 导出里含：protobuf 21.11 **13,213**、abseil `lts_20250512` **1,290**、arrow 24.0.0 **15,571**、**静态 libstdc++ 50,662**、`__cxa_*`/unwind 26、malloc 族 9、operator new/delete 13、jemalloc 31、`GNU_UNIQUE` 0（clang 编译） | 同上 |
| **Doris 自己已经被这个机制咬过一次**：fluss scanner 的 `librocksdbjni.so` 自带 2,576 个 RocksDB 符号，绑到了 BE 导出的 RocksDB 上，"runs half on ours"，`std::bad_alloc` 逃出 JNI 帧、BE abort。修法：`-Wl,--exclude-libs,librocksdb.a`，**明确不取消 `ENABLE_EXPORTS`** | `be/src/service/CMakeLists.txt:70-92` |
| `-static-libstdc++ -static-libgcc`；`BUILD_SHARED_LIBS OFF`；无 RPATH（`CMAKE_SKIP_RPATH TRUE`）；无 `-fvisibility` | `be/CMakeLists.txt:830-831, 944, 251` |
| `DT_NEEDED` 只有 `libjvm.so` + glibc 家族；libjvm 是**链接时**依赖（`add_library(jvm SHARED IMPORTED)`），运行时靠 `start_be.sh` 设 `LD_LIBRARY_PATH` | `be/CMakeLists.txt:646-650`；`bin/start_be.sh:163-177` |
| malloc 族通过**别名**在链接期替换成 jemalloc（`je_` 前缀，`--disable-cxx`，所以 operator new 走静态 libstdc++ 再进 jemalloc） | `be/src/runtime/memory/jemalloc_hook.cpp:73-84`；`thirdparty/build-thirdparty.sh:1799-1801` |
| 内存追踪不在 malloc hook 里，只在 Doris 自己的 `Allocator<>` 里；外部库的分配**进 jemalloc 但对 MemTracker 不可见**，只被 RSS 级的进程限额看到 | `be/src/core/allocator.cpp:255-265`；`global_memory_arbitrator.h:39-43` |
| 无 ThreadContext 的线程：RELEASE 下记到 Orphan tracker（误归属，不崩）；DEBUG/ASAN 下 DCHECK 失败；但任何路径调到 `thread_context()` 会 **throw** | `be/src/runtime/thread_context.h:274-277, 384-405`；`thread_mem_tracker_mgr.h:177-182` |
| 现有 dlopen 都是 `RTLD_NOW`/`RTLD_LAZY` + 默认 `RTLD_LOCAL`，**从不 `RTLD_GLOBAL`**；dlopen 之后必须 `updatePHDRCache()` + `SymbolIndex::reload()`，否则栈回溯/patched libunwind 看不到新 DSO 的 FDE（有单测证明这个失败模式） | `be/src/util/dynamic_util.cpp:43-58`；`be/test/common/phdr_cache_test.cpp:90-95` |
| **不要指望 `dlclose`**：ADBC driver 注册表明确永不卸载（"drivers carry global state and background threads"） | `be/src/util/adbc_driver_registry.h:33-37` |
| 信号：`SIGSEGV/SIGILL/SIGFPE/SIGABRT/SIGBUS/SIGTERM` + `SIGINT/SIGTERM` + `SIGRTMIN+6`，全部 `sigaction(..., nullptr)`，**不保存不链式调用旧 handler**，无 `SA_ONSTACK`/`sigaltstack`；JVM 之后再装 handler 的顺序问题已有注释 | `be/src/common/signal_handler.h:69-72, 454-465`；`doris_main.cpp:112-135, 590-592` |
| `glibc-compatibility` 从可执行文件里插入 musl 版 libc 函数（`memcpy`、`*_chk`、`getrandom`、`clock_gettime`、`epoll_*`、数学函数），以及 **no-op 的 `pthread_setname_np`/`pthread_getname_np`**，`.symver` 把 `pthread_sigmask` 等降到 `GLIBC_2.17` | `be/src/glibc-compatibility/glibc-compatibility.c:38-181`；`glibc-compat-2.32.h:41-50` |
| Arrow C Data Interface 已是 Doris 与外部引擎交换数据的既定边界（ADBC reader、paimon-cpp reader），并有「第三方 driver 的 bug 不得 abort BE」的防御式先例 | `be/src/format_v2/table/adbc_reader.h:20,47-53`；`be/src/format/table/paimon_cpp_reader.cpp:26,157` |
| 部署：`vm.max_map_count ≥ 2000000`、`ulimit -n ≥ 60000`、关 swap；容器化用 `seccomp:unconfined` | `bin/start_be.sh:194-215`；`docker/runtime/doris-compose/cluster.py:537` |

### 5.2 Sirius 产物侧的事实

见 §2.4。要点：protobuf 是 vendor 进来的 3.19.4 源码（`substrait/third_party/google/protobuf`，`PROTOBUF_VERSION 3019004`），随扩展一起 `-fvisibility=hidden` 编译；abseil `lts_20250814` 静态且隐藏；**没有 Arrow C++**；libstdc++/libgcc 动态。

### 5.3 实验 A：真实 Sirius 产物 × 真实 doris_be

方法：为 9 个 CUDA/NVML 库生成导出同名桩函数的 `.so`（含版本节点），`LD_LIBRARY_PATH` 指过去；`LD_BIND_NOW=1 LD_PRELOAD=sirius.duckdb_extension LD_DEBUG=bindings doris_be --version`。`LD_PRELOAD` 与 `dlopen(RTLD_LOCAL)` 的符号搜索顺序对本问题等价（可执行文件永远最先）。

结果：`doris_be --version` **正常打印版本、exit 0**（加载、重定位、静态构造全部完成）。产物的符号绑定去向：

| 绑到 | 个数 | 内容 |
|---|---|---|
| 自身 | 1,103 | |
| **`doris_be`** | **687** | **libstdc++ 549**（`std::string`、`std::__format::*`、`std::regex` 内部静态、`basic_*stream` VTT…）、**`__cxa_*`/`__dynamic_cast`/`__gxx_personality_v0` 22**、**operator new/delete 10**、**malloc 族 14**（→ jemalloc）、glibc-compat 插入的 libc 11（`clock_gettime`、`epoll_*`、`explicit_bzero`、`getentropy`…）、musl 数学 `pow/log/exp/log2`、`sched_getcpu`、`timerfd_*`、`eventfd`、`accept4`、`fallocate`… |
| libc / libm / libgcc_s | 336 / 27 / 14 | |
| 桩 CUDA 库 | 68 | |
| **系统 `libstdc++.so.6`** | **1**（`__cxa_thread_atexit`） | |
| protobuf / abseil / openssl / curl / zstd / zlib → `doris_be` | **0** | 静态 + 隐藏确实免疫 |
| 别人绑进产物 | 0 | |

解读：

1. **进程内加载在动态链接层面是通的** —— 这是本次调研最重要的正面结论。
2. **但产物实际跑在 Doris 的 libstdc++ 上**，不是自己的。带版本的引用（`@GLIBCXX_3.4.21` 等）之所以能被可执行文件里**无版本**的静态副本满足，是 ld.so 的规则：定义方没有版本信息时忽略版本要求。今天能工作是因为 Doris 的 libstdc++（GCC 13 世代，有 `std::__format`）比 Sirius 需要的（≤ `GLIBCXX_3.4.22`）新且同一 ABI。任何一方换工具链（Doris 若在 Linux 上开 `USE_LIBCPP`、或 Sirius 用更新的 libstdc++ 内部符号）都可能翻车，而且翻车形态是 §5.4 里那种 abort。
3. **malloc 走 jemalloc**：Sirius 的 host 端分配（DuckDB 目录、计划、cuDF host 端、spdlog…）都进 Doris 的 jemalloc，RSS 级限额看得见，MemTracker 看不见。pinned host 内存（`cudaMallocHost`）不经 malloc，两边都看不见，只有 RSS 看得见。
4. 加载层通 ≠ 运行层通：CUDA 初始化、线程、信号、显存独占都还没验证（§8.5）。

### 5.4 实验 B：合成矩阵（Ubuntu 24.04 arm64 容器）

宿主模仿 Doris：静态 libstdc++/libgcc（系统 GCC 13.3）、静态 protobuf 3.21.12（PIC 自编）、静态 jemalloc，自己注册 `substrait/plan.proto`；两种形态：`host_noexport`（dynsym 仅 9 个）和 `host_rdynamic`（8,733 个：protobuf 3,821、libstdc++ 2,453、`GNU_UNIQUE` 111 —— 即 Doris 形态）。插件模仿 libsirius，导出 6 个 `extern "C"` 入口，内部解析同名 proto、用 std::regex/std::format/iostream/std::thread、抛异常：

| 插件 | 工具链 | 依赖 | 可见性 | 导出符号数 | DT_NEEDED |
|---|---|---|---|---|---|
| `conda_dyn` | conda GCC 15.3 | conda `libprotobuf.so` + 41 个 `libabsl_*.so` + conda `libstdc++.so.6` | hidden | 344 | 45 个 |
| `conda_dyn_leaky` | 同上 | 同上 | default | 553 | 45 个 |
| `static_hidden` | 系统 GCC 13 | 静态 protobuf + zlib | hidden + `--exclude-libs,ALL` + version script | **7** | libstdc++.so.6 等 5 个 |
| `static_leaky` | 同上 | 同上 | default | 6,339 | 同上 |
| `fullstatic_hidden` | 同上 | 同上 + **静态 libstdc++/libgcc** | 同 `static_hidden` | **7** | **仅 libc/libm/ld-linux** |

测试：test0 = 解析 proto + 描述符池 + std 探针 + 比对 `&typeid(std::runtime_error)`/`&malloc`/`&std::cout`/`generated_pool()` 是否与宿主同址；test1 = 插件内抛/接；test2 = 异常逃逸到宿主。子进程隔离，崩溃记信号。

**结果矩阵**（`experiments/.../synthetic-matrix/`，`summarize.sh` 输出）：

| 宿主 | 插件 | `RTLD_LOCAL` | `RTLD_DEEPBIND` | `RTLD_GLOBAL` | 读法 |
|---|---|---|---|---|---|
| noexport | conda_dyn | ✅ OK（两套 protobuf、两套 libstdc++ 各自独立；malloc 同为 jemalloc） · test2 **abort** | ✅ OK（但 malloc 分裂：插件用 glibc） · test2 abort | 同 LOCAL | 宿主不导出时一切靠 `RTLD_LOCAL` 天然隔离；异常跨界永远不行 |
| noexport | conda_dyn_leaky | ✅ · test2 abort | ✅（malloc 分裂）· test2 abort | ✅ · test2 abort | 同上 |
| **rdynamic** | **conda_dyn** | **❌ abort（test0/1/2 全崩）** | ✅ OK（malloc 分裂）· test2 abort | ❌ abort | **Doris 形态 × conda/pixi 风格产物 = 崩**：插件自己的代码隐藏了，但它的 `libprotobuf.so`/`libabsl_*.so`/conda GCC 15 头文件里内联的 std 代码，引用的 libstdc++ 出线函数绑到了宿主 GCC 13 的静态副本 → 头/库版本错配 |
| rdynamic | conda_dyn_leaky | **❌ test0 SIGSEGV**；test1 OK；test2 **能 catch** | ✅（malloc 分裂）· test2 abort | ❌ SIGSEGV | 「寄生」形态：插件默认可见性，它的 protobuf 7.36 引用有一部分绑到了宿主的 protobuf 3.21 → 半新半旧 → 段错误；异常反而能过，因为异常机制整个是宿主那一份。**这就是 Doris 注释里 `librocksdbjni.so` "runs half on ours" 的复现** |
| rdynamic | static_hidden | ✅ OK（same_pool=0 —— protobuf 免疫；same_typeinfo/same_cout=1 —— libstdc++ 是宿主的）· test2 **能 catch** | ✅ 全隔离 · test2 abort | 同 LOCAL | **今天真实 Sirius 产物的形态**（§5.3）：静态隐藏的依赖完全免疫；libstdc++ 寄生在宿主上，所以此刻能工作、连异常都能过 —— 但这依赖宿主的 libstdc++ 更新且 ABI 相同 |
| rdynamic | static_leaky | ✅ OK（same_pool=1：两份**相同版本**的 protobuf 合并成一份，同名 `.proto` 因描述符字节相同被去重，没有触发 "File already exists"）· test2 能 catch | ✅ · test2 abort | 同 LOCAL | 同版本才侥幸；上一行说明版本不同时的下场 |
| rdynamic | **fullstatic_hidden** | ✅ OK，**四个「同址」全为 0（malloc 除外）** · test2 abort | ✅ · test2 abort | 同 LOCAL | **推荐形态**：对宿主导出什么完全无感；只共享 libc/malloc；异常必须在边界内捕获（= C ABI） |
| noexport | 三种静态插件 | ✅ OK（全隔离；malloc 仍是 jemalloc —— 宿主不 `-rdynamic` 时 `malloc/free` 也会因 libc 的引用被自动导出）· test2 abort | ✅（malloc 分裂）· test2 abort | 同 LOCAL | 宿主不导出时一切靠 `RTLD_LOCAL` 隔离 |

> 第一轮矩阵里 conda 环境碰巧解析到了与宿主相同的 protobuf 3.21.12，「不同大版本」这一维没被激发，`conda_dyn_leaky × rdynamic` 当时是 OK 的；表中为第二轮（conda 钉 `libprotobuf>=5`，实际解析到 7.36.1）的结果。完整输出：`experiments/.../synthetic-matrix/matrix-summary.txt`。

三条硬结论：

1. **宿主导出静态 libstdc++ + 插件动态依赖 libstdc++ = 版本错配的定时炸弹**。Doris 不会为此取消 `ENABLE_EXPORTS`（native UDF 需要，且 `--exclude-libs,libstdc++.a` 会让 UDF 自己掉进同一个坑），所以**解法在 Sirius 侧：libsirius 静态链接 libstdc++/libgcc 并隐藏**。
2. **`RTLD_DEEPBIND` 不是答案**：它把 malloc 也隔离了（插件走 glibc malloc、宿主走 jemalloc），跨界释放即崩，Doris 的 RSS 记账也乱；还有 libgomp 13.x + DEEPBIND 段错误等已知问题（conda-forge/ctng-compilers-feedstock#114），以及 CUDA 库 dlopen 链路上未验证的行为。
3. **C++ 异常在任何「两套运行时」形态下都不能跨界** → C ABI 是必需品（§3.2）。

### 5.5 结论与代价

**进程内方案在依赖层面可行**，代价是下面 6 条约束：

**Sirius 侧（libsirius 的交付标准，4 条）**
1. 依赖全静态（vcpkg 口味已做到）+ `-fvisibility=hidden` + `-Wl,--exclude-libs,ALL`（已做到）；
2. **`-static-libstdc++ -static-libgcc`**（新增；`sirius.duckdb_extension` 不能这么做，libsirius 必须）；
3. version script 只导出 `sirius_*`，顺带收掉 767 个 std 模板实例和 58 个 `GNU_UNIQUE`（新增）；
4. libgomp 静态或移除（它现在是死依赖），cuvs/raft 可选化以砍掉 5 个 CUDA 数学库（建议）。

**Doris 侧（加载约束，2 条）**
5. 通过 `dynamic_open()`（`RTLD_NOW|RTLD_LOCAL` + `updatePHDRCache` + `SymbolIndex::reload`）加载，永不 `dlclose`；
6. 从 Sirius 线程回调进 Doris 的路径必须为零（`push_arrow` 的同步拷贝语义已保证数据面如此；控制面的错误回调/取消回调设计时同样遵守）。

**运行时闭包（部署约束）**：NVIDIA 驱动（`libcuda.so.1`/`libnvidia-ml.so.1`）+ CUDA 13 运行库（cublas/cublasLt/cusolver/cusparse/curand/nvrtc/nvJitLink，≈ 1 GB+）+ glibc ≥ 2.28（Doris 官方镜像 Ubuntu 22.04 = 2.35 ✅；CentOS 7 = 2.17 ❌，dlopen 失败应降级为「GPU 不可用」）+ `io_uring`（Docker 默认 seccomp 自 moby#46762 起**屏蔽** `io_uring_*`，Doris compose 已用 `seccomp:unconfined`，K8s 需自定义 profile）。

### 5.6 本节没验证的（需要 GPU 机器）

- CUDA context / RMM pool / `cudaMallocHost` 在 BE 进程内初始化，与 jemalloc `percpu_arena` 和 Doris 90% `mem_limit` 的共存；
- Sirius 启动的线程池（task_creator 1 + pipeline 4 + downgrade 1 + scan_manager「剩余核数」+ uring reactor 1 + REST reactor 2）与 Doris 线程模型的相互影响；
- Doris 信号 handler 与 CUDA 运行时的关系（我的理解是 CUDA 用户态运行时不装信号 handler，UVM 缺页在内核驱动里处理；需在 GPU 机器上用 `/proc/<pid>/status` SigCgt 前后对比核实）；
- `glibc-compatibility` 的 no-op `pthread_setname_np` 对 CUDA/NVML 无影响的假设；
- `RTLD_LOCAL` 下 cudart 静态运行时内部 `dlopen("libcuda.so.1")` 的行为（应无问题，未测）。

---

## 6. P0.5 · 打包与分发

### 6.1 产物

`libsirius-<semver>-linux_<amd64|arm64>-cuda<12|13>.tar.gz`：`lib/libsirius.so.<major>`（+ `libsirius.so` 软链）、`include/sirius/sirius_c.h`、`share/sirius/sirius.yaml.example`、`LICENSE`、`THIRD_PARTY_NOTICES`、`sha256sum`。大小 ≈ 330 MB（压缩后；`.nv_fatbin` 302 MB 是大头，按需裁 arch 可减半）。

发布：GitHub Release（现有 `distribution.yml` 已在 CPU runner 上做 vcpkg 构建，加一个 tag 触发的 upload step 即可）；conda 包留作后续。版本策略：semver；`sirius_abi_version()` 单调递增，C 头文件里 `#define SIRIUS_C_ABI_VERSION`；Doris 在 dlopen 后先握手，不匹配 → 禁用 GPU 并打日志。

### 6.2 Doris 侧怎么拿到 headers

**vendor 一个文件**：`be/src/exec/gpu_offload/third_party/sirius_c.h`（≈ 250 行）+ `arrow_c_abi.h`（Arrow 的两个 struct，Doris 已有 `<arrow/c/abi.h>`，可直接 include）。编译期对 libsirius **零依赖**，`-DWITH_GPU_OFFLOAD=ON` 时也只多编几个 .cpp。不走 submodule、不走 thirdparty 构建。

运行时：BE config `sirius_library_path`（默认空 = 关闭）；也支持放在 `be/lib/sirius/`（Doris 已经在 `be/lib/` 里带 `java_extensions` 1.2 GB、`cdc_client` 148 MB、`hadoop_hdfs` 99 MB，一个 330 MB 的可选组件不出格）。CUDA 运行库通过 `start_be.sh` 的 `LD_LIBRARY_PATH`（与 `libjvm`、`hadoop_hdfs/native` 同一套做法）或系统 CUDA toolkit。

### 6.3 兼容性矩阵（Doris 文档里要写的）

| 维度 | 要求 |
|---|---|
| NVIDIA 驱动 | cuda13 变体 ≥ 580.65.06；cuda12 变体 ≥ 525 |
| GPU | 计算能力 7.5+（Turing 起） |
| glibc | ≥ 2.28 |
| libsirius ABI | `sirius_abi_version()` == 编译进 BE 的常量 |
| 容器 | seccomp 允许 `io_uring_*`；`--gpus`；`vm.max_map_count` 同现有要求 |

---

## 7. P0.6 · 边车方案对照估算

### 7.1 Doris 已经有一个边车

`be/src/udf/python/`（3,551 行）：`PythonServerManager::fork()` 拉起 Python 进程池，`PythonClient` 用 **Arrow Flight `DoExchange`** 收发 batch，后台健康检查线程重建死进程（`python_server.h:35-173`，`python_client.cpp:52-64`）。Arrow Flight C++ 客户端已经链在 BE 里（`thirdparty.cmake:116-117`）。**边车的 Doris 侧不是从零写，是照这个模式再实例化一次。**

### 7.2 worker 定位与实现

「libsirius as a service」：协议 = Substrait 进、Arrow 出，与 Doris 无关。两种实现路线：

| | Rust worker（推荐） | C++ worker |
|---|---|---|
| 复用 | `rust/crates/sirius` + `sirius-sys`（cxx 共编，**不需要 C ABI**）、`experimental/starrocks/src/engine.rs` 的引擎线程模型（397 行，可直接搬）、`tonic` + `arrow-flight` crate | Arrow C++ Flight —— 但 Arrow C++ 不在 Sirius 闭包里，要新增依赖 |
| 需要 Sirius 新增 | `push_arrow`（§4）+ `Fragment` 的 cxx 绑定（~55 行，今天只绑了 `Context`） | `push_arrow` + C ABI |
| 构建 | 在 Sirius 仓库内、随 libsirius 一起发 | 同左 |

协议（Flight `DoExchange`）：descriptor.cmd = `{substrait bytes, 输入流声明, sender 数}`；客户端流式写入输入 batch（Arrow IPC over gRPC），服务端流式返回结果 batch；`close_input` 用 app_metadata 帧；取消 = 断流（worker 侧 `close_input` 全部输入让 fragment 收敛 —— 与进程内一样受限于 Sirius 没有 `cancel()`）。数据面更省的替代：UDS + `memfd` 共享内存（SCM_RIGHTS 传 fd，worker `mmap` 后 `cudaHostRegister`）—— 少一次序列化，多一套自定义协议，MVP 不值得。

### 7.3 工作量

| 部分 | 行数 | 说明 |
|---|---|---|
| worker（Rust）：Flight 服务、会话/fragment 生命周期、输入流路由到 `push_arrow`、结果流、健康/就绪探针、配置、日志 | 2,500–3,500 | 对照：StarRocks CN 的协议外壳 4,600 行是因为要伪装 thrift/BRPC；Flight 现成 |
| Doris `runtime/sidecar_transport.{h,cpp}`：进程管理（照抄 `PythonServerManager`）、Flight 客户端、重启/健康、超时 | 1,000–1,500 | |
| Sirius 侧前置 | `push_arrow` + Fragment cxx 绑定 ≈ 200 | C ABI 可省 |
| **合计** | **≈ 3.5–5k 行**（vs 进程内 Doris 侧 ≈ 0.7k + Sirius 侧 C ABI 0.8k） | |

### 7.4 数据面多一次拷贝的代价

以 SF100 `lineitem`（≈ 6 亿行，Doris Block 导出后约 60–80 GB 未压缩）为尺度，单机估算（按公开带宽数量级，未实测）：

| 路径 | 每字节要经过 | 带宽量级 | 60 GB 耗时量级 |
|---|---|---|---|
| 进程内 | Block → Arrow（零拷贝）→ `from_arrow_host` pageable H2D（driver bounce） | PCIe 4.0 x16 pinned ≈ 20–25 GB/s，pageable ≈ 8–12 GB/s | 5–8 s |
| 边车 Flight | + IPC 序列化到 gRPC 帧 + 内核 socket 拷贝 + worker 侧解帧（近零拷贝）| localhost gRPC 单流 ≈ 1–3 GB/s，多流可叠加到 memcpy 上限 | +20–60 s（单流）/ +6–15 s（8 流） |
| 边车 shm | + 一次 memcpy 进 memfd | ≈ 5–10 GB/s/核 | +6–12 s |

也就是说 **MVP-1/2（数据经 Doris 喂）阶段边车会把传输时间放大 1.5–3×**，而传输本来就是这两期的瓶颈（`design.md` §3.3 已承认）；**MVP-3（GPU 直读 parquet）之后边车的数据面代价归零** —— 数据根本不经过 Doris。所以边车的相对成本随路线图推进而下降。

### 7.5 边车拿到什么

崩溃隔离（CUDA/cuDF/DuckDB 任何 abort 只丢当前查询）、显存泄漏可通过重启 worker 回收、内存独占（95% 显存 / 90% pinned）不再与 BE 进程共处一个 cgroup 视角、Sirius 的十几个线程和 io_uring 不进 BE、**§5 的全部链接约束消失**（worker 用 conda 口味构建也行）。代价除了拷贝还有：一套进程生命周期运维、两个进程的日志/指标关联、以及 §5.5 里 Doris 侧的 2 条约束换成「fd 数/端口/权限」类的运维约束。

---

## 8. P0.7 · 汇总与建议

### 8.1 代码量总表

**Sirius 侧（通用能力，对任何嵌入方一视同仁）**

| 项 | 生产 | 测试 | 依赖 | 备注 |
|---|---|---|---|---|
| ① `push_arrow`（§4） | ~150 | ~230 | 无 | 最便宜、最阻断；#1590/#839 已在路线图 |
| ② C ABI `sirius_c.h` + shim（§3） | ~800 | ~300 | ① | 不动内部；边车路线可省 |
| ③ libsirius target + 4 条链接约束 + install + Release（§2.5） | ~150–250 CMake/YAML | CI | — | CPU runner 即可验证构建 |
| ④ `capabilities()` | ~100 | ~50 | — | 消除白名单双写 |
| ⑤（可选）结果路径 `to_arrow_host` 4→1 拷贝 | ~120 | ~80 | — | |
| ⑥（可选）`Fragment` cxx 绑定（边车/Rust 用） | ~55 + ~70 | — | ① | |
| **合计（①–④）** | **≈ 1.2–1.3k** | **≈ 0.6k** | | 约 2–3 工程周 + review |

**Doris 侧（仅嵌入运行时；translator / gate / operator / bridge 是 MVP-0/1 的工作，不在 P0 内）**

| 项 | 行数 |
|---|---|
| `runtime/inproc_transport.{h,cpp}`：`dynamic_open` 加载、`dlsym` 表、ABI 握手、Context 生命周期、config（library path、YAML path、内存上限） | ~300 |
| in-flight 限流 + 槽位准入（Sirius 串行） | ~200 |
| Sirius 线程 / 内存归属包装（`SCOPED_INIT_THREAD_CONTEXT`、RSS 预留）| ~100 |
| vendor `sirius_c.h`、`start_be.sh`/config/文档 | ~50 + vendored |
| **合计** | **≈ 0.7k**（边车路线 ≈ 1–1.5k） |

### 8.2 风险表

| 风险 | 等级 | 实测状态 | 缓解 |
|---|---|---|---|
| libstdc++ 版本错配（宿主导出静态副本 × 产物动态依赖） | 🔴 | **已复现**（矩阵 `rdynamic × conda_dyn` abort；真实产物今天靠 Doris 副本更新才工作） | Sirius：`-static-libstdc++ -static-libgcc` + hidden；Doris：不改 |
| C++ 异常跨界 | 🔴 | 已复现（test2 abort） | C ABI，边界内 `catch (...)` |
| 内存独占默认值（GPU 95%、pinned 每 NUMA 90%）撞 Doris `mem_limit` 90% | 🔴 | 未测（需 GPU） | libsirius 拒绝无显式上限的配置；Doris 侧 config 必填；RSS 预留 |
| Sirius host 端内存对 MemTracker 不可见、pinned 内存对 malloc 也不可见 | 🟡 | 机制已确认 | 进程级预留 + profile 里单列 |
| 引擎串行、无 cancel、无背压 | 🟡 | 已确认（#1303 / #1276 设计决定） | 准入 + in-flight 限流 + `close_input` 收敛；推动 #1590 |
| 崩溃带走 BE | 🔴 | — | 默认关闭 + 测试集群；生产切边车 |
| CUDA 运行库 1 GB+ 的分发与驱动版本耦合 | 🟡 | 已确认（19 个 DT_NEEDED） | 文档化兼容矩阵；建议 Sirius 把 cuvs/raft 可选化 |
| `GNU_UNIQUE` 泄漏使 DSO 不可卸载 | 🟢 | 已确认 58 个 | 永不 dlclose（Doris 惯例）；version script |
| io_uring 被容器默认 seccomp 屏蔽 | 🟡 | 文献 | 部署文档；Doris compose 已 unconfined |
| glibc ≥ 2.28 | 🟢 | 已确认 | dlopen 失败 → 优雅降级 |

### 8.3 A/B 建议（用于 ADR-006 / ADR-009）

**推荐：MVP-1/2 走进程内（B），前提是 libsirius 满足 §5.5 的 4 条 Sirius 侧约束；生产硬化前切边车。** 理由：

1. 依赖冲突不是「典型爆炸场景」而是一个**已定位、可在 Sirius 侧用几行链接参数消除**的问题；真正的冲突面只有 libstdc++，且实验证明 fullstatic+hidden 形态对宿主完全免疫。
2. 三个缺口合计 ≈ 1.3k 行，且 ①③ 是 Sirius 路线图上已有的方向（#1590、`sirius_ffi.hpp` 的注释），提案阻力小。
3. 进程内的 Doris 侧代码（0.7k）几乎全是边车也需要的（限流、准入、生命周期），切换时只换传输层，与 `design.md` §3.4 的判断一致。
4. 边车在 MVP-1/2 会把本来就是瓶颈的传输放大 1.5–3×，会让 MVP-1 的 benchmark 更难看；到 MVP-3 它的数据面代价归零 —— **那正是该切边车的时点**。
5. Doris 已有边车范式（Python UDF），到时不是探索性工作。

**不推荐**：`RTLD_DEEPBIND` 作为隔离手段（malloc 分裂 + 已知 bug）；conda/pixi 口味的产物进 BE（实测崩）；`dlmopen` 新命名空间（CUDA 驱动在第二命名空间里的行为不可控）。

### 8.4 对 Sirius 的诉求清单（英文提案素材，按优先级）

1. **`Fragment::push_arrow(stream, sender, ArrowSchema*, ArrowArray*)`** — 外部 Arrow 输入口；实现路径与估算见 §4，与 #1590 / #839 的 push/pull FFI 合并提出。附带：`to_arrow_host` 收敛结果路径的 4 次拷贝。
2. **libsirius 交付标准**（§5.5 的 4 条）：同一组 object 的第二个 link target；`-static-libstdc++ -static-libgcc`；version script 只导出 `sirius_*`；libgomp 静态/移除、cuvs 可选。附上 §5.3/§5.4 的实验数据说明为什么 `sirius.duckdb_extension` 本身不能直接当 libsirius 用。
3. **C ABI**（§3.3 的头文件草案）+ `sirius_abi_version()` + `capabilities_json()`。
4. **发布**：tag → GitHub Release（4 个变体的 tarball + sha256），`sirius_ffi.hpp` 注释里承诺的「dedicated libsirius」落地。
5. **配置安全阀**：`Context` 构造时若未显式设置 GPU/host 容量则要求调用方确认（默认 95%/90% 对宿主进程不友好）；`SIRIUS_LOG_DIR` 等环境变量改为可编程 API（宿主进程不该靠 env 传参）。
6. 原有诉求下调：并发（#1303）、`cancel()`、非阻塞 `run()`（#1590）、背压（#1276 已决定不做，接受）。

以上 1–4 不是「为 Doris 做的」，是让 Sirius 成为可嵌入引擎的通用能力；Rust/Go/JNI/任何独立构建的 C++ 宿主都需要同样的东西。

### 8.5 本机能验证 / 不能验证

| 已在本机验证 ✅ | 只能在 GPU 机器验证 ⛔ |
|---|---|
| 两个真实二进制的 ELF 级依赖/导出/导入清单 | libsirius 的**构建**本身（需 CUDA 工具链；但 Sirius CI 的 CPU runner 可以） |
| 真实产物加载进真实 BE 的加载器级兼容性（重定位、构造、符号绑定去向） | `Context` 初始化：CUDA context、RMM pool、pinned pool、NUMA 探测在 BE 进程内的行为 |
| 五种产物形态 × 三种 dlopen flag 的隔离效果与失效模式 | `push_arrow` 的正确性（类型对账）、H2D 吞吐、pinned staging 收益 |
| C 异常跨界必崩、`RTLD_DEEPBIND` 的副作用 | Sirius 线程池与 Doris 线程/内存记账的相互影响；信号 handler 共存 |
| C ABI / `push_arrow` / 打包 / 边车的设计与估算（读代码 + 社区 issue） | io_uring / seccomp、显存独占与多租户、cancel 收敛超时 |
| Doris 侧加载、内存 hook、phdr cache、信号、glibc-compat 的机制与先例 | 端到端（M0.8 起） |

> 顺带修正 handoff/reference 里的三处判断：① 「没有可分发的 libsirius 产物」→ 有单文件 CI 产物，缺的是链接约束/头文件/版本化/发布；② 「两份 protobuf + 两份 abseil 是典型爆炸场景」→ 对 Sirius 不成立（vendor + hidden；abseil inline namespace），真正的爆点是 libstdc++；③ 「arrow 重叠」→ Sirius 闭包里没有 Arrow C++。

---

## 9. 补充：Sirius 侧的并行工作与 Doris 先例（2026-09-01 晚）

为提案对齐 #1590 时核实的事实，影响 §8.4 诉求的措辞和 PR 时序。

### 9.1 #1590 的现状

- 2026-08-17 由 aocsa 开、自任 assignee、P2；**没有第三方讨论**，唯一评论是作者 2026-08-18 记录的状态。
  scope 四项：`run()` 拆 `start()/join()`；`Fragment` 暴露 `push/pull/wait/drained`（含 Rust 绑定 #1598）；
  放开「build 与 run 之间只能有一个 fragment」；移植 `export_packed/push_packed/StagingArena` 跨进程传输。
- 已合并：#1481（阻塞式 `streaming_fragment` + `Fragment` FFI）。draft：#1598（Rust `Fragment` 绑定，
  基于 `stream/15-fragment` 栈）、**#1644「Stream fragment execution」（+17,580/−1,029，2026-08-27）**。
- #1644 实现的是 scope 第 4 项：`Context::staging_lease/release/base/capacity` + 线程安全的 `StagingArena`
  句柄（`cudaMalloc` 或 fabric-handle 的设备内存池，`SIRIUS_EXCHANGE_STAGING_BYTES` 配置）、
  `Fragment::export_packed`（`cudf::chunked_pack` 进 lease）、`Fragment::push_packed(stream, metadata_addr,
  metadata_len, offset, length)`（`cudf::unpack` + 深拷贝进 pool + `session().push()`）。StarRocks CN 侧用
  NIXL（UCX/RDMA）搬 lease 里的字节。拆分计划：T1→T3→T2→T5(a: arena, b: FFI)→T7→T8→T4→T6。
- **仍未做**：非阻塞 `run()`；`push/pull/wait`；`push_packed` 的契约是「build() 与 run() 之间合法，和
  `relay_from` 同一位置」，且 #1644 明文 "the `Context` is single-threaded by contract"。

### 9.2 与本方案的关系

| 维度 | 关系 | 处置 |
|---|---|---|
| 输入口 | `push_packed`（设备内存 + cudf pack 元数据，GPU↔GPU）与 `push_arrow`（host Arrow，CPU→GPU）是同一调用位置的两种入口；CPU 宿主既没有设备指针也产不出 pack 元数据，所以不能复用 `push_packed` | 提案里把 `push_arrow` 定位为 `push_packed` 的 host 对应物，实现路径平行 |
| **线程契约** | `Context` 单线程、`push_packed` 仅在 run() 之前 → store-and-forward；本方案假设边 `run()` 边多线程 push（§4.1 的底层能力支持，FFI 契约不支持） | **提案中的头号对齐问题**；退路 = MVP-1 先 store-and-forward（整段输入先物化，靠 spill 兜底） |
| 代码时序 | `sirius_ffi.{hpp,cpp}` 正被 T5b 大改 | `push_arrow` PR 排在 T5b 之后或基于 `stream/*` 栈 |
| 依赖闭包 | #1644 核心侧只用 CUDA driver API（`cuMem*`/`cudaMalloc`），NIXL/UCX 留在 `experimental/starrocks` | 诉求 2 加一句「NIXL/UCX 留在 libsirius 之外」 |
| 配置 | 又一个 env 参数（`SIRIUS_EXCHANGE_STAGING_BYTES`/`_ARENA`） | 并入诉求 4 |
| 并发 | #1364–#1372、#1583 在推进多查询并发（#1303） | 诉求 5 只提一句「看到了」 |

### 9.3 `origin/doris`：Sirius 已经做过一次 Doris

- 作者 mbrobbel（Sirius 维护者），67 个提交，2026-03-30～06-03，此后无动作；exchange-design（PR #914）
  称之为 prior art，并说 StarRocks 的流式模型「替代」了它的 materialize-then-shuffle。
- 形态 = `design.md` §2.1 的方案 A（伪 BE）：`doris/crates/sirius-doris-be`（Rust）向 FE 注册成 BE，
  `doris-rpc`（≈7k 行：gRPC `exec_plan_fragment`、Thrift 心跳、bRPC PBlock 收发、Arrow Flight 结果、
  NIXL 交换）、`plan-translator`（≈10.5k 行，Doris **4.0.3-rc03** thrift → Substrait/SQL，109 个测试）、
  `pblock_decoder.rs`/`arrow_to_pblock.rs`（Doris 的 PBlock 线格式）、`sirius_exchange_c_api.hpp`
  （`extern "C"` + 不透明句柄 + `last_error()`，把 cudf pack 后的交换产物暴露给 Rust）。
- 数据只来自 `local()` TVF 读 parquet；**没有内表**。FINDINGS.md（2026-02-26）：GPU 路径在 Docker CDI 下
  `cudaMemcpyBatchAsync` 失败，用 `--force-cpu`（DuckDB `from_substrait`）绕过；OVERVIEW 称 Q1/Q2/Q4/Q5/
  Q6/Q12/Q14 在 GPU 上验证到 SF1000；"Checkpoint Doris 22/22 baseline"（04-13）是 GPU/CPU/SQL 三条路径的混合。
- **对本项目的价值**：① 提案必须主动说明我们是不同方向（真实 BE、内表、复用 Doris 扫描/shuffle），否则
  维护者会问「为什么不复活 `doris/`」；② 它的翻译器测试用例和类型映射是 M0.3–M0.6 的参考（语言不同，
  逻辑可借）；③ FINDINGS 里 DuckDB Substrait 消费端的 bug 与我们同一条路径（`SubstraitToDuckDB`），
  已记入 `reference/semantics-gaps.md` G-25～G-29；④ `sirius_exchange_c_api.hpp` 证明维护者接受
  `extern "C"` 形态。

## 附录 A · 关键数字速查

| | Doris BE 4.1.3（arm64） | Sirius 产物（arm64 · cuda13） |
|---|---|---|
| 文件大小 | 2,213,948,768 B | 519,749,318 B |
| dynsym 定义 / 导入 | 475,722 / 607 | 1,626 / 772 |
| libstdc++ 导出 / 导入 | 50,662 / 0（静态） | 767（模板实例）/ **259 `@GLIBCXX` + 43 `@CXXABI`** |
| protobuf | 21.11 静态，13,213 导出 | 3.19.4 vendor，隐藏，14 导出、0 导入 |
| abseil | `lts_20250512`，1,290 导出 | `lts_20250814`，0 导出 0 导入 |
| Arrow C++ | 24.0.0 静态，15,571 导出 | 无（nanoarrow 0.7.0 在 cudf 里） |
| glibc 需求 | 2.17 | 2.28 |
| DT_NEEDED | 8（libjvm + glibc 家族） | 19（CUDA 12 个 + libstdc++/libgcc/libgomp + glibc） |
| 预加载后绑到对方 | — | **687 → doris_be**，1 → 系统 libstdc++.so.6 |

## 附录 B · 复现

```bash
# 需要 Docker；全部不需要 GPU
cd plan-doc/experiments/p0.4-symbol-isolation
# 1. 合成矩阵（约 8 分钟，含从源码编 PIC protobuf 3.21.12 与 micromamba 环境）
docker build -t sirius-embed-exp synthetic-matrix && docker run --rm -v $PWD/synthetic-matrix:/exp sirius-embed-exp bash /exp/build_and_run.sh > matrix.log && bash synthetic-matrix/summarize.sh
# 2. 真实二进制：doris_be 来自 apache/doris:be-4.1.3；Sirius 产物用 gh run download <run-id> -n sirius-v1.5.5-extension-linux_arm64-cuda13
#    分析脚本 real-binaries/analyze_*.sh 在任何带 binutils 的容器里跑；预加载实验先 gen_stubs.sh（实验镜像里）再 run_preload.sh（doris 镜像里，--entrypoint bash）
```
