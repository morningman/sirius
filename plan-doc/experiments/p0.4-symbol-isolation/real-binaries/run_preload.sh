#!/bin/bash
# Run inside apache/doris:be-4.1.3 (Ubuntu 22.04, glibc 2.35): LD_PRELOAD the real Sirius artifact
# into the real doris_be and record where every symbol of the artifact binds.
set -u
export LD_LIBRARY_PATH=/w/stubs:/usr/lib/jvm/jdk-17/lib/server:/usr/lib/jvm/jdk-17/lib
BE=/opt/apache-doris/be/lib/doris_be
cd /w; rm -f /w/lddebug.*
echo "== ldd of artifact under stub path =="; ldd /w/sirius.duckdb_extension | grep -v '^\s*linux-vdso' | sed 's/^/  /' | head -30
echo "== run: LD_BIND_NOW=1 LD_PRELOAD=artifact doris_be --version =="
timeout 600 env LD_BIND_NOW=1 LD_PRELOAD=/w/sirius.duckdb_extension LD_DEBUG=bindings LD_DEBUG_OUTPUT=/w/lddebug $BE --version; echo "exit=$?"
F=$(ls /w/lddebug.* 2>/dev/null | head -1); echo "debug file: $F ($(wc -l < $F) lines)"
echo "== bindings FROM sirius.duckdb_extension, grouped by provider =="
grep "binding file /w/sirius.duckdb_extension" $F | sed -E 's/.* to ([^ ]+) \[.*/\1/' | sort | uniq -c | sort -rn
echo "== extension symbols bound to doris_be, by family =="
grep "binding file /w/sirius.duckdb_extension" $F | grep "to $BE" | sed -E "s/.*symbol \`([^']*)'.*/\1/" > /w/bound_to_be.txt
tot=$(wc -l < /w/bound_to_be.txt)
echo "  total: $tot"
echo "  libstdc++ (_ZSt/_ZNSt/_ZNKSt/_ZTV/_ZTI/_ZTS St): $(grep -cE '^_Z(N|NK)?St|^_ZT[VIS]St|^_ZT[VIS]N?St' /w/bound_to_be.txt)"
echo "  __cxa_* / __dynamic_cast / __cxxabiv1: $(grep -cE '^__cxa|__dynamic_cast|__cxxabiv1|^_ZTVN10__cxxabiv1' /w/bound_to_be.txt)"
echo "  _Unwind_* / libgcc: $(grep -cE '^_Unwind|^__gcc|^__aarch64|^__addtf|^__multf|^__subtf|^__divtf|^__extend|^__trunc|^__fixtf|^__floatti|^__floatunti' /w/bound_to_be.txt)"
echo "  operator new/delete: $(grep -cE '^_Zn[wa]|^_Zd[la]' /w/bound_to_be.txt)"
echo "  malloc family: $(grep -cwE 'malloc|free|calloc|realloc|posix_memalign|aligned_alloc|memalign|valloc|malloc_usable_size' /w/bound_to_be.txt)"
echo "  glibc-compat interposed libc (memcpy/pthread_*name*/getrandom/_chk/explicit_bzero/clock_gettime/epoll/glob): $(grep -cE '^memcpy$|^pthread_(set|get)name_np$|^getrandom$|^getentropy$|_chk$|^explicit_bzero$|^clock_gettime$|^epoll|^glob$|^posix_spawn' /w/bound_to_be.txt)"
echo "  protobuf: $(grep -c 'google8protobuf' /w/bound_to_be.txt)"
echo "  absl: $(grep -c '_ZN4absl' /w/bound_to_be.txt)"
echo "  openssl/curl/zstd/lz4/zlib: $(grep -cE '^(SSL_|EVP_|CRYPTO_|curl_|ZSTD_|LZ4_|inflate|deflate|crc32|adler32)' /w/bound_to_be.txt)"
echo "  other (sample):"; grep -vE '^_Z(N|NK)?St|^_ZT[VIS]|^__cxa|__dynamic_cast|__cxxabiv1|^_Unwind|^_Zn[wa]|^_Zd[la]|^(malloc|free|calloc|realloc|posix_memalign|aligned_alloc|memalign|valloc|malloc_usable_size)$|^memcpy$|^pthread_|^getrandom$|_chk$|google8protobuf|_ZN4absl|^(SSL_|EVP_|CRYPTO_|curl_|ZSTD_|LZ4_)' /w/bound_to_be.txt | sort | uniq -c | sort -rn | head -40 | sed 's/^/    /'
echo "== sample of libstdc++ symbols bound to doris_be (versioned refs satisfied by unversioned exe symbols) =="
grep "binding file /w/sirius.duckdb_extension" $F | grep "to $BE" | grep -E "_ZNSt|_ZSt" | head -12 | sed 's/^/  /'
echo "== extension symbols bound to system libstdc++.so.6 (not exported by doris_be): =="
grep "binding file /w/sirius.duckdb_extension" $F | grep "libstdc++.so.6" | sed -E "s/.*symbol \`([^']*)'.*/\1/" | head -15 | sed 's/^/  /'
echo "  count: $(grep "binding file /w/sirius.duckdb_extension" $F | grep -c "libstdc++.so.6")"
echo "== also: what binds INTO the extension from others (should be ~0 under RTLD_LOCAL-like isolation) =="
grep "to /w/sirius.duckdb_extension" $F | grep -v "binding file /w/sirius.duckdb_extension" | sed -E 's/binding file ([^ ]+) .*/\1/' | sort | uniq -c | sort -rn | head
