#!/bin/bash
# ELF analysis of the real doris_be (apache/doris:be-4.1.3, arm64)
set -u
B=/w/doris_be
echo "== file =="; file $B
echo "== DT_NEEDED =="; readelf -d $B | grep -E 'NEEDED|RUNPATH|RPATH|FLAGS'
echo "== program headers (interp / GNU_EH_FRAME) =="; readelf -lW $B | grep -E 'INTERP|GNU_EH_FRAME|TLS' ; readelf -pW .interp $B 2>/dev/null | tail -1
readelf --dyn-syms -W $B > /w/dynsym.txt
echo "== dynsym: total defined =$(grep -v ' UND ' /w/dynsym.txt | grep -c ' FUNC\| OBJECT') ; undefined(imports)=$(grep -c ' UND ' /w/dynsym.txt)"
echo "== defined+exported by category =="
def() { grep -v ' UND ' /w/dynsym.txt | grep -E ' (FUNC|OBJECT|IFUNC) ' | grep -E ' (GLOBAL|WEAK|UNIQUE) '; }
echo "  protobuf   : $(def | grep -c 'google8protobuf')"
echo "  absl       : $(def | grep -c '_ZN4absl')"
echo "  arrow      : $(def | grep -c '_ZN5arrow')"
echo "  libstdc++  : $(def | grep -c '_ZSt\|_ZNSt\|_ZTVSt\|_ZTISt')"
echo "  __cxa/unwind: $(def | grep -c '__cxa_\|_Unwind_')"
echo "  malloc-family: $(def | grep -wE 'malloc|free|calloc|realloc|posix_memalign|aligned_alloc|memalign|valloc|malloc_usable_size' | wc -l)"
echo "  operator new/delete: $(def | grep -c '_Znwm\|_Znam\|_ZdlPv\|_ZdaPv')"
echo "  jemalloc(je_/mallctl): $(def | grep -c 'je_\|mallctl')"
echo "  dl_iterate_phdr: $(def | grep -cw dl_iterate_phdr)"
echo "  doris::    : $(def | grep -c '_ZN5doris')"
echo "  GNU_UNIQUE : $(def | grep -c ' UNIQUE ')"
echo "== full list of defined exported symbols (first 200) =="; def | awk '{print $4, $5, $8}' | head -200
echo "== imports grouped by version needed =="; grep ' UND ' /w/dynsym.txt | grep -o '@[A-Z_0-9.]*' | sort | uniq -c | sort -rn | head -20
echo "== GLIBCXX strings in binary (static libstdc++ version fingerprints) =="; strings -n 8 $B | grep -E '^GLIBCXX_3\.4\.[0-9]+$' | sort -V | tail -3
echo "== protobuf version string =="; strings -n 6 $B | grep -E 'This program requires version .* of the Protocol Buffer|protobuf-[0-9]+\.[0-9]+' | head -3
echo "== abseil version markers =="; strings -n 10 $B | grep -oE 'absl[/_]lts_[0-9]+' | sort -u | head; strings -n 6 $B | grep -oE 'lts_2025[0-9]{4}' | sort -u | head -3
echo "== io_uring / CUDA / jemalloc / static-libstdc++ hints =="
for s in io_uring_setup libcuda.so jemalloc je_malloc_conf __libc_start_main _ZN5doris10PhdrCache; do echo "  $s: $(strings -n 6 $B | grep -c "$s")"; done
echo "== symtab present? =="; readelf -SW $B | grep -E '\.symtab|\.debug_info|\.gnu_debuglink' | awk '{print $2, $3, $6}'
