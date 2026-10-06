// Fake "libsirius": owns a protobuf copy (whichever it was linked with), registers
// substrait/plan.proto in *its* generated pool, and exposes a pure C ABI.
#include "substrait/plan.pb.h"
#include <google/protobuf/descriptor.h>
#include <google/protobuf/stubs/common.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <typeinfo>
#ifdef WITH_ABSL
#include "absl/strings/str_cat.h"
#include "absl/container/flat_hash_map.h"
#endif
#define EXPORT extern "C" __attribute__((visibility("default")))

EXPORT int sirius_run(const char* buf, size_t len, char* out, size_t cap) {
  substrait::Plan plan;
  if (!plan.ParseFromArray(buf, (int)len)) { snprintf(out, cap, "PARSE_FAIL"); return 1; }
  const auto* fd = google::protobuf::DescriptorPool::generated_pool()->FindFileByName("substrait/plan.proto");
  std::string extra;
#ifdef WITH_ABSL
  absl::flat_hash_map<std::string,int> m; m["k"] = 7;
  extra = absl::StrCat(" absl=ok(", m["k"], ")");
#endif
  snprintf(out, cap, "pb=%d rels=%d pool_has_file=%d desc=%s pool_ptr=%p%s",
           (int)GOOGLE_PROTOBUF_VERSION, plan.relations_size(), fd != nullptr,
           std::string(substrait::Plan::descriptor()->full_name()).c_str(),  // string in pb 3.x, string_view in pb >= 22
           (const void*)google::protobuf::DescriptorPool::generated_pool(), extra.c_str());
  return 0;
}
EXPORT int sirius_throw(int escape) {
  try { throw std::runtime_error("boom-from-plugin"); }
  catch (const std::exception& e) { if (!escape) return 0; throw; }
  return 2;
}
EXPORT const void* sirius_typeinfo_runtime_error() { return &typeid(std::runtime_error); }
EXPORT const void* sirius_malloc_addr() { return (const void*)&malloc; }
EXPORT const void* sirius_cout_addr() { return (const void*)&std::cout; }
EXPORT const void* sirius_pool_addr() { return (const void*)google::protobuf::DescriptorPool::generated_pool(); }

// Exercise libstdc++ machinery that has internal state / newer symbols: regex (GNU_UNIQUE statics),
// std::format (GLIBCXX_3.4.32+), iostreams/locale, std::thread, std::stoi/to_string.
#include <format>
#include <regex>
#include <sstream>
#include <thread>
EXPORT int sirius_stdlib_probe(char* out, size_t cap) {
  try {
    std::regex re("([a-z]+)-(\\d+)");
    std::smatch m; std::string s = "sirius-42";
    bool ok = std::regex_match(s, m, re);
    int n = std::stoi(m[2].str());
    std::string f = std::format("{}:{:>4}:{:.2f}", m[1].str(), n, 3.14159);
    std::ostringstream os; os << f << "|" << std::to_string(n * 2);
    std::string r;
    std::thread t([&] { r = os.str(); }); t.join();
    snprintf(out, cap, "regex=%d format+stream+thread=%s", ok, r.c_str());
    return 0;
  } catch (const std::exception& e) { snprintf(out, cap, "STDLIB_PROBE_EXC:%s", e.what()); return 7; }
}
