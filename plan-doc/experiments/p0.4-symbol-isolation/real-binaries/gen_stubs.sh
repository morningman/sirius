#!/bin/bash
# Generate stub CUDA/NVML libraries that satisfy sirius.duckdb_extension's DT_NEEDED + versioned
# imports, so the real artifact can be LD_PRELOADed into the real doris_be (no GPU needed) purely
# to observe symbol binding. Run inside the experiment image (has gcc + binutils).
set -eu
ART=/w/sirius.duckdb_extension
OUT=/w/stubs; rm -rf $OUT; mkdir -p $OUT/src
readelf --dyn-syms -W $ART | grep ' UND ' | awk '{print $8}' | grep -v '^$' > $OUT/src/und.txt
# soname -> (name-regex or version tag)
declare -A LIBS=(
  [libcuda.so.1]='^cu[A-Z]'
  [libnvidia-ml.so.1]='^nvml'
  [libcublas.so.13]='@libcublas\.so\.13$'
  [libcublasLt.so.13]='@libcublasLt\.so\.13$'
  [libcusparse.so.12]='@libcusparse\.so\.12$'
  [libcusolver.so.12]='@libcusolver\.so\.12$'
  [libcurand.so.10]='@libcurand\.so\.10$'
  [libnvrtc.so.13]='@libnvrtc\.so\.13$'
  [libnvJitLink.so.13]='@libnvJitLink\.so\.13$'
  [libgomp.so.1]='^(GOMP_|omp_)'
)
for so in "${!LIBS[@]}"; do
  pat=${LIBS[$so]}
  syms=$(grep -E "$pat" $OUT/src/und.txt | sed 's/@.*//' | sort -u || true)
  src=$OUT/src/${so%%.so*}.c
  echo "/* stub for $so */" > $src
  n=0
  for s in $syms; do echo "int $s(void) { return 0; }" >> $src; n=$((n+1)); done
  [ $n -eq 0 ] && echo "int __stub_dummy_${so//[.-]/_}(void){return 0;}" >> $src
  extra=""
  if [[ "$pat" == @* ]]; then
    ver=${pat#@}; ver=${ver//\\/}; ver=${ver%\$}
    echo "$ver { global: *; };" > $OUT/src/${so}.map
    extra="-Wl,--version-script=$OUT/src/${so}.map"
  fi
  gcc -shared -fPIC -o $OUT/$so $src -Wl,-soname,$so $extra
  echo "built $so with $n symbols"
done
ls -la $OUT
