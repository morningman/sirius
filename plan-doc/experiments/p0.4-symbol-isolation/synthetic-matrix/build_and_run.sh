#!/bin/bash
# Builds host variants x plugin variants, then runs the dlopen matrix.
set -u
cd /exp
OUT=/exp/out; rm -rf $OUT; mkdir -p $OUT/gen_apt $OUT/gen_conda
echo "== toolchains =="
g++ --version | head -1; protoc --version; ls /opt/pb21/lib/libprotobuf.a /usr/lib/*/libjemalloc.a 2>&1
eval "$(micromamba shell hook -s bash)"; micromamba activate sirius
CXX=${CXX:-$(ls $CONDA_PREFIX/bin/*-conda-linux-gnu-g++ 2>/dev/null | head -1)}; [ -z "$CXX" ] && CXX=$CONDA_PREFIX/bin/g++
echo "conda CXX=$CXX"; $CXX --version | head -1; protoc --version; ls $CONDA_PREFIX/lib/libprotobuf.so* $CONDA_PREFIX/lib/libstdc++.so.6* | head
/usr/bin/protoc -Iproto --cpp_out=$OUT/gen_apt proto/substrait/plan.proto
$CONDA_PREFIX/bin/protoc -Iproto --cpp_out=$OUT/gen_conda proto/substrait/plan.proto
micromamba deactivate

echo; echo "== build hosts (system g++, static libstdc++/libgcc, static protobuf 3.21, static jemalloc) =="
ZLIB=$(ls /usr/lib/*/libz.a 2>/dev/null | head -1); [ -z "$ZLIB" ] && ZLIB="-lz"
HOSTLIBS="/opt/pb21/lib/libprotobuf.a $ZLIB -l:libjemalloc.a -ldl -pthread -static-libstdc++ -static-libgcc"
/usr/bin/g++ -std=c++20 -O1 -I/opt/pb21/include -I$OUT/gen_apt host/host.cpp $OUT/gen_apt/substrait/plan.pb.cc -o $OUT/host_noexport $HOSTLIBS || exit 1
/usr/bin/g++ -std=c++20 -O1 -I/opt/pb21/include -I$OUT/gen_apt host/host.cpp $OUT/gen_apt/substrait/plan.pb.cc -o $OUT/host_rdynamic -rdynamic $HOSTLIBS || exit 1
for h in host_noexport host_rdynamic; do
  echo "-- $h: DT_NEEDED: $(readelf -d $OUT/$h | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | tr '\n' ' ')"
  echo "   dynsym defined total=$(readelf --dyn-syms -W $OUT/$h | grep -v ' UND ' | grep -c ' FUNC\| OBJECT') protobuf=$(readelf --dyn-syms -W $OUT/$h | grep -v ' UND ' | grep -c 'google8protobuf') malloc/free=$(readelf --dyn-syms -W $OUT/$h | grep -v ' UND ' | grep -cw 'malloc\|free') libstdc++=$(readelf --dyn-syms -W $OUT/$h | grep -v ' UND ' | grep -c '_ZSt\|_ZNSt\|_ZTVSt') gnu_unique=$(readelf --dyn-syms -W $OUT/$h | grep -c UNIQUE)"
done

echo; echo "== build plugins =="
eval "$(micromamba shell hook -s bash)"; micromamba activate sirius
CXX=${CXX:-$(ls $CONDA_PREFIX/bin/*-conda-linux-gnu-g++ 2>/dev/null | head -1)}; [ -z "$CXX" ] && CXX=$CONDA_PREFIX/bin/g++
ABSL_FLAGS=$(pkg-config --cflags --libs absl_strings absl_flat_hash_map 2>/dev/null)
# P1: conda toolchain, DYNAMIC conda protobuf + abseil + conda libstdc++ (pixi/conda-style libsirius), hidden own symbols
$CXX -std=c++20 -O1 -fPIC -shared -fvisibility=hidden -DWITH_ABSL -I$OUT/gen_conda plugin/plugin.cpp $OUT/gen_conda/substrait/plan.pb.cc \
   -o $OUT/plugin_conda_dyn.so -lprotobuf $ABSL_FLAGS -Wl,-rpath,$CONDA_PREFIX/lib || exit 1
# P1b: same but default visibility (leaky exports)
$CXX -std=c++20 -O1 -fPIC -shared -DWITH_ABSL -I$OUT/gen_conda plugin/plugin.cpp $OUT/gen_conda/substrait/plan.pb.cc \
   -o $OUT/plugin_conda_dyn_leaky.so -lprotobuf $ABSL_FLAGS -Wl,-rpath,$CONDA_PREFIX/lib || exit 1
micromamba deactivate
# P2: system toolchain, STATIC protobuf (same 3.21 as host!), hidden + exclude-libs + version script (vcpkg-style libsirius)
/usr/bin/g++ -std=c++20 -O1 -fPIC -shared -fvisibility=hidden -I/opt/pb21/include -I$OUT/gen_apt plugin/plugin.cpp $OUT/gen_apt/substrait/plan.pb.cc \
   -o $OUT/plugin_static_hidden.so /opt/pb21/lib/libprotobuf.a $ZLIB -Wl,--exclude-libs,ALL -Wl,--version-script=plugin.map -pthread || exit 1
# P2b: static protobuf but leaky (default visibility, no exclude-libs, no version script)
/usr/bin/g++ -std=c++20 -O1 -fPIC -shared -I/opt/pb21/include -I$OUT/gen_apt plugin/plugin.cpp $OUT/gen_apt/substrait/plan.pb.cc \
   -o $OUT/plugin_static_leaky.so /opt/pb21/lib/libprotobuf.a $ZLIB -pthread || exit 1
# P3: like P2 but ALSO static libstdc++/libgcc inside the plugin (no libstdc++.so.6 DT_NEEDED at all) — the
#     "single self-contained DSO" shape a distributable libsirius should have.
/usr/bin/g++ -std=c++20 -O1 -fPIC -shared -fvisibility=hidden -I/opt/pb21/include -I$OUT/gen_apt plugin/plugin.cpp $OUT/gen_apt/substrait/plan.pb.cc \
   -o $OUT/plugin_fullstatic_hidden.so /opt/pb21/lib/libprotobuf.a $ZLIB -static-libstdc++ -static-libgcc \
   -Wl,--exclude-libs,ALL -Wl,--version-script=plugin.map -pthread || exit 1
for p in plugin_conda_dyn plugin_conda_dyn_leaky plugin_static_hidden plugin_static_leaky plugin_fullstatic_hidden; do
  echo "-- $p.so: exported dynsym=$(readelf --dyn-syms -W $OUT/$p.so | grep -v ' UND ' | grep -c ' FUNC\| OBJECT') protobuf_exports=$(readelf --dyn-syms -W $OUT/$p.so | grep -v ' UND ' | grep -c google8protobuf) gnu_unique=$(readelf --dyn-syms -W $OUT/$p.so | grep -v ' UND ' | grep -c UNIQUE)"
  echo "   DT_NEEDED: $(readelf -d $OUT/$p.so | grep NEEDED | sed 's/.*\[\(.*\)\]/\1/' | tr '\n' ' ')"
done

echo; echo "== RUN MATRIX =="
for h in host_noexport host_rdynamic; do
 for p in plugin_conda_dyn plugin_conda_dyn_leaky plugin_static_hidden plugin_static_leaky plugin_fullstatic_hidden; do
  for f in local deepbind global; do
   for t in 0 1 2; do
     echo "### $h | $p | RTLD_$f | test$t"
     timeout 20 $OUT/$h $OUT/$p.so $f $t 2>&1 | sed 's/^/  /'
   done
  done
 done
done
