#!/bin/bash
# ELF analysis of the real CI-built sirius.duckdb_extension (vcpkg static build, linux_arm64, cuda13)
set -u
B=$(ls /w/*.duckdb_extension | head -1)
echo "== file =="; ls -la $B; file $B
echo "== DT_NEEDED / RUNPATH =="; readelf -d $B | grep -E 'NEEDED|RUNPATH|RPATH|SONAME|FLAGS'
echo "== version needs (glibc / libstdc++ / others) =="; readelf -V -W $B | grep -E 'Name:|Version:' | grep -oE '(GLIBC|GLIBCXX|CXXABI|GCC|libcuda|libnvidia)[A-Za-z0-9_.]*' | sort -u | sort -V | tr '\n' ' '; echo
echo "== max glibc version needed =="; readelf -V -W $B | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1
readelf --dyn-syms -W $B > /w/dynsym.txt
def() { grep -v ' UND ' /w/dynsym.txt | grep -E ' (FUNC|OBJECT|IFUNC|TLS) ' | grep -E ' (GLOBAL|WEAK|UNIQUE) '; }
echo "== dynsym: defined+exported=$(def | wc -l) ; undefined(imports)=$(grep -c ' UND ' /w/dynsym.txt)"
echo "== exported by category =="
echo "  sirius::ffi      : $(def | grep -c '_ZN6sirius3ffi')"
echo "  duckdb entry     : $(def | grep -cE 'sirius_(init|version|duckdb_cpp_init)|duckdb_cpp_init|_init$')"
echo "  duckdb::         : $(def | grep -c '_ZN6duckdb')"
echo "  sirius:: (other) : $(def | grep -c '_ZN6sirius' )"
echo "  cudf::           : $(def | grep -c '_ZN4cudf')"
echo "  rmm::            : $(def | grep -c '_ZN3rmm')"
echo "  cucascade::      : $(def | grep -c '_ZN9cucascade')"
echo "  protobuf         : $(def | grep -c 'google8protobuf')"
echo "  absl             : $(def | grep -c '_ZN4absl')"
echo "  libstdc++        : $(def | grep -c '_ZSt\|_ZNSt\|_ZTVSt\|_ZTISt\|_ZNKSt')"
echo "  __cxa/unwind     : $(def | grep -c '__cxa_\|_Unwind_')"
echo "  malloc-family    : $(def | grep -wE 'malloc|free|calloc|realloc|posix_memalign|aligned_alloc' | wc -l)"
echo "  operator new/del : $(def | grep -c '_Znwm\|_Znam\|_ZdlPv\|_ZdaPv')"
echo "  openssl/curl     : $(def | grep -cE ' (SSL_|EVP_|CRYPTO_|curl_)')"
echo "  cuda*            : $(def | grep -cE ' (cuda|cu[A-Z]|nvml|__cudaRegister)')"
echo "  GNU_UNIQUE       : $(def | grep -c ' UNIQUE ')"
echo "  TLS              : $(def | grep -c ' TLS ')"
echo "== exported names (non-sirius/duckdb sample, first 60) =="; def | awk '{print $4, $5, $8}' | grep -v '_ZN6sirius\|_ZN6duckdb' | head -60
echo "== GNU_UNIQUE exported sample =="; def | grep ' UNIQUE ' | awk '{print $8}' | head -20
echo "== imports (UND) grouped: libc/libm/pthread vs others; sample of non-versioned imports =="
grep ' UND ' /w/dynsym.txt | awk '{print $8}' | grep -v '@GLIBC\|@GLIBCXX\|@CXXABI\|@GCC' | head -60
echo "== imports count by version tag =="; grep ' UND ' /w/dynsym.txt | grep -oE '@[A-Za-z_]+' | sort | uniq -c | sort -rn | head
echo "== strings: protobuf/cudf/rmm/nanoarrow version fingerprints =="
strings -n 6 $B | grep -E 'This program (requires|was compiled)' | head -2
strings -n 6 $B | grep -oE 'nanoarrow[ _-]?[0-9.]+|libcudf [0-9.]+|cudf [0-9]{2}\.[0-9]{2}|RAPIDS_VERSION[^ ]*' | sort -u | head
strings -n 8 $B | grep -oE 'lts_20[0-9]{6}' | sort -u | head -3
echo "== io_uring / numa / dlopen targets =="; strings -n 6 $B | grep -E '^lib(cuda|nvidia-ml|numa|uring|cudart|nvrtc|nvJitLink|cufile)[a-z0-9_-]*\.so' | sort -u | head
echo "== sections (size) =="; readelf -SW $B | grep -E '\.text|\.rodata|\.data\b|\.bss|nv_fatbin|\.dynsym|\.dynstr|\.symtab|\.debug_info' | awk '{printf "%s %s\n", $2, $6}'
