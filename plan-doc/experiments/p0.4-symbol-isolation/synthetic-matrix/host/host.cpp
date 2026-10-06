// Fake "doris_be": static libstdc++/libgcc, static protobuf, static jemalloc, own copy of
// substrait/plan.proto registered in its generated pool. dlopen()s a plugin and calls its C ABI.
#include "substrait/plan.pb.h"
#include <google/protobuf/descriptor.h>
#include <google/protobuf/stubs/common.h>
#include <dlfcn.h>
#include <sys/wait.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <stdexcept>
#include <string>
#include <typeinfo>

typedef int (*run_fn)(const char*, size_t, char*, size_t);
typedef int (*throw_fn)(int);
typedef const void* (*addr_fn)();

static int child(const char* path, int flags, int test) {
  substrait::Plan plan; plan.set_version(1);
  for (int i = 0; i < 3; ++i) plan.add_relations()->set_name("rel" + std::to_string(i));
  (*plan.mutable_extensions())["dialect"] = "duckdb";
  std::string bytes; plan.SerializeToString(&bytes);
  const auto* fd = google::protobuf::DescriptorPool::generated_pool()->FindFileByName("substrait/plan.proto");
  printf("  host: pb=%d host_pool_has_file=%d host_pool=%p\n", (int)GOOGLE_PROTOBUF_VERSION, fd != nullptr,
         (const void*)google::protobuf::DescriptorPool::generated_pool());
  fflush(stdout);
  void* h = dlopen(path, flags);
  if (!h) { printf("  RESULT: DLOPEN_FAIL: %s\n", dlerror()); return 3; }
  auto run = (run_fn)dlsym(h, "sirius_run");
  auto thr = (throw_fn)dlsym(h, "sirius_throw");
  auto ti  = (addr_fn)dlsym(h, "sirius_typeinfo_runtime_error");
  auto ma  = (addr_fn)dlsym(h, "sirius_malloc_addr");
  auto co  = (addr_fn)dlsym(h, "sirius_cout_addr");
  auto po  = (addr_fn)dlsym(h, "sirius_pool_addr");
  if (!run || !thr || !ti || !ma || !co || !po) { printf("  RESULT: DLSYM_FAIL\n"); return 4; }
  if (test == 0) {
    char out[512]; int rc = run(bytes.data(), bytes.size(), out, sizeof out);
    printf("  plugin: %s\n", out);
    printf("  same_pool=%d same_typeinfo(runtime_error)=%d same_malloc=%d same_cout=%d\n",
           po() == (const void*)google::protobuf::DescriptorPool::generated_pool(),
           ti() == (const void*)&typeid(std::runtime_error),
           ma() == (const void*)&malloc, co() == (const void*)&std::cout);
    auto probe = (run_fn)dlsym(h, "sirius_stdlib_probe");
    char pout[256] = {0}; int prc = probe ? ((int (*)(char*, size_t))probe)(pout, sizeof pout) : -1;
    printf("  stdlib_probe: rc=%d %s\n", prc, pout);
    substrait::Plan p2; bool ok = p2.ParseFromString(bytes);  // host still works after plugin load?
    printf("  RESULT: %s (rc=%d probe_rc=%d host_reparse=%d)\n", rc == 0 && ok && prc == 0 ? "OK" : "FAIL", rc, prc, ok);
    return rc == 0 && ok && prc == 0 ? 0 : 5;
  }
  if (test == 1) {  // exception thrown inside plugin, caught inside plugin
    int rc = thr(0); printf("  RESULT: %s (internal throw/catch rc=%d)\n", rc == 0 ? "OK" : "FAIL", rc); return rc;
  }
  // test 2: exception escapes the C boundary into the host
  try { thr(1); printf("  RESULT: FAIL (no exception seen)\n"); return 6; }
  catch (const std::exception& e) { printf("  RESULT: CAUGHT_AS_STD_EXCEPTION what=%s\n", e.what()); return 0; }
  catch (...) { printf("  RESULT: CAUGHT_AS_ELLIPSIS_ONLY\n"); return 0; }
}

int main(int argc, char** argv) {
  if (argc < 4) { fprintf(stderr, "usage: host <plugin.so> <local|deepbind|global> <test 0|1|2>\n"); return 2; }
  int flags = RTLD_NOW;
  std::string f = argv[2];
  if (f == "local") flags |= RTLD_LOCAL; else if (f == "deepbind") flags |= RTLD_LOCAL | RTLD_DEEPBIND; else flags |= RTLD_GLOBAL;
  int test = atoi(argv[3]);
  pid_t pid = fork();
  if (pid == 0) { setvbuf(stdout, nullptr, _IONBF, 0); int rc = child(argv[1], flags, test); fflush(stdout); _exit(rc); }
  int st = 0; waitpid(pid, &st, 0);
  if (WIFSIGNALED(st)) printf("  RESULT: CRASH signal=%d (%s)\n", WTERMSIG(st), strsignal(WTERMSIG(st)));
  else if (WEXITSTATUS(st) != 0) printf("  (child exit=%d)\n", WEXITSTATUS(st));
  return 0;
}
