#!/usr/bin/env bash
set -ex

# IMPORTANT: All the build steps have been adapted from
# https://github.com/bblanchon/pdfium-binaries/blob/91942b7e694e75c2a74f610c922e85521a0a3a5c/steps
# and https://github.com/conda-forge/libv8-feedstock/blob/2ad246cbd0089edece27145460850b44d76b8114/recipe/build.sh

########################################
## Cleaning up
## NOTE(hadim): gclient is doing extra necessary work compared to git clone and I
## cannot get rid of it for now.. Sor for now I will simply ignore and delete the
## entire build folder. The patches will also be applied manually.
## Hopefully we can get rid of that later.
########################################

rm -fr $SRC_DIR
mkdir $SRC_DIR
cd $SRC_DIR

########################################
## Environment variables
########################################

if [ -z "${PDFIUM_GIT_REVISION}" ]; then
  echo "Error: PDFIUM_GIT_REVISION is not set."
  exit 1
fi

if [[ $target_platform =~ "linux" ]]; then
  OS="linux"
elif [[ $target_platform =~ "osx" ]]; then
  OS="mac"
else
  echo "Unsupported platform: $target_platform"
  exit 1
fi

SOURCE="${SRC_DIR}/pdfium/"
BUILD="${SOURCE}/out"
TARGET_CPU="${ARCH}"         # x64, arm64, x86, arm, wasm, etc
TARGET_ENVIRONMENT="default" # can be musl as well
ENABLE_V8="false "           # true or false
IS_DEBUG="false"             # true or false

########################################
## 01-install.sh - Install depot_tools (gclient, etc)
########################################

DEPOT_TOOLS_DIR="$SRC_DIR/depot_tools"
git clone "https://chromium.googlesource.com/chromium/tools/depot_tools.git" "$DEPOT_TOOLS_DIR"
export PATH="$DEPOT_TOOLS_DIR:$PATH"

########################################
## 02-checkout.sh
########################################

CONFIG_ARGS=()
if [ "$ENABLE_V8" == "false" ]; then
  CONFIG_ARGS+=(
    --custom-var "checkout_configuration=minimal"
  )
fi

gclient config --unmanaged "https://pdfium.googlesource.com/pdfium.git" "${CONFIG_ARGS[@]-}"

echo "target_os = [ '$OS' ]" >>.gclient

gclient sync -r "src@${PDFIUM_GIT_REVISION}" --no-history --shallow

########################################
## 03-patch.sh
########################################

pushd "${SOURCE}"

PATCHES_DIR="${RECIPE_DIR}/patches"

git apply -v "$PATCHES_DIR/public_headers.patch"

[ "$OS" != "wasm" ] && git apply -v "$PATCHES_DIR/shared_library.patch"
[ "${ENABLE_V8}" == "true" ] && git apply -v "$PATCHES_DIR/v8/pdfium.patch"

popd

############################
# from https://github.com/conda-forge/libv8-feedstock/blob/2ad246cbd0089edece27145460850b44d76b8114/recipe/build.sh#L25

pushd "${SOURCE}"

export LD_LIBRARY_PATH=$PREFIX/lib

cat <<EOF >build/config/gclient_args.gni
use_custom_libcxx=false
clang_use_chrome_plugins=false
v8_use_external_startup_data=false
is_debug=false
clang_base_path="${BUILD_PREFIX}"
is_component_build=true
icu_use_system=true
icu_include_dir="$PREFIX/include"
icu_lib_dir="$PREFIX/lib"
v8_use_snapshot=false
enable_stripping=true
checkout_google_benchmark=false
EOF

if [[ "${target_platform}" =~ osx.* ]]; then
  # sed -i "s;@PREFIX@;${PREFIX};g" build/config/mac/BUILD.gn
  echo "mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\"" >>build/config/gclient_args.gni
fi

if [[ "${target_platform}" == "osx-64" ]]; then
  echo 'mac_sdk_min="10.9"' >>build/config/gclient_args.gni
  gn gen out.gn "--args=use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" mac_sdk_min=\"10.9\" is_component_build=true mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\" icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" enable_stripping=true"

  # Explicitly link to libz, otherwise _compressBound cannot be found
  # sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8.ninja
  # sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8_for_testing.ninja

elif [[ "${target_platform}" == "osx-arm64" ]]; then
  echo 'mac_sdk_min="11.0"' >>build/config/gclient_args.gni
  gn gen out.gn "--args=target_cpu=\"arm64\" use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" mac_sdk_min=\"11.0\" is_component_build=true mac_sdk_path=\"${CONDA_BUILD_SYSROOT}\" icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" enable_stripping=true"

  # Manually override the compiler
  sed -i "s;bin/clang;bin/${CC};g" out.gn/toolchain.ninja

  # Explicitly link to libz, otherwise _compressBound cannot be found
  sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8.ninja
  sed -i "s/libs =/libs = -lz/g" out.gn/obj/v8_for_testing.ninja
elif [[ "${target_platform}" == linux-* ]]; then
  echo 'use_sysroot=false' >>build/config/gclient_args.gni
  echo 'is_clang=false' >>build/config/gclient_args.gni
  echo 'treat_warnings_as_errors=false' >>build/config/gclient_args.gni
  echo 'fatal_linker_warnings=false' >>build/config/gclient_args.gni

  if [[ "${target_platform}" == "linux-aarch64" ]]; then
    TARGET_CPU='target_cpu="arm64" v8_target_cpu="arm64"'
  elif [[ "${target_platform}" == "linux-ppc64le" ]]; then
    TARGET_CPU='target_cpu="ppc64" v8_target_cpu="ppc64" host_byteorder="little"'
  fi

  gn gen out.gn "--args=target_os=\"linux\" ${TARGET_CPU:-} use_custom_libcxx=false clang_use_chrome_plugins=false v8_use_external_startup_data=false is_debug=false clang_base_path=\"${BUILD_PREFIX}\" is_component_build=true icu_use_system=true icu_include_dir=\"$PREFIX/include\" icu_lib_dir=\"$PREFIX/lib\" use_sysroot=false is_clang=false treat_warnings_as_errors=false fatal_linker_warnings=false enable_stripping=true"
  sed -i "s/ gcc/ $(basename ${CC})/g" out.gn/toolchain.ninja
  sed -i "s/ g++/ $(basename ${CXX})/g" out.gn/toolchain.ninja
  sed -i "s/ ${HOST}-gcc/ $(basename ${CC})/g" out.gn/toolchain.ninja
  sed -i "s/ ${HOST}-g++/ $(basename ${CXX})/g" out.gn/toolchain.ninja
  sed -i "s/deps = $(basename ${CC})\$//g" out.gn/toolchain.ninja
  sed -i "s/deps = $(basename ${CXX})\$//g" out.gn/toolchain.ninja

  if [[ "${target_platform}" == "linux-aarch64" ]]; then
    sed -i "s/ aarch64-linux-gnu-gcc/ $(basename ${CC})/g" out.gn/toolchain.ninja
    sed -i "s/ aarch64-linux-gnu-g++/ $(basename ${CXX})/g" out.gn/toolchain.ninja
    sed -i "s/aarch64-linux-gnu-readelf/$(basename ${READELF})/g" out.gn/toolchain.ninja
    sed -i "s/aarch64-linux-gnu-nm/$(basename ${NM})/g" out.gn/toolchain.ninja
    sed -i "s/aarch64-linux-gnu-ar/$(basename ${AR})/g" out.gn/toolchain.ninja
  fi

  # ld.gold segfaults on mksnapshot linkage with binutils 2.35
  # for f in out.gn/obj/bytecode_builtins_list_generator.ninja out.gn/obj/bytecode_builtins_list_generator.ninja out.gn/obj/v8.ninja out.gn/obj/v8_libbase.ninja out.gn/obj/v8_for_testing.ninja out.gn/obj/mksnapshot.ninja out.gn/obj/v8_simple_parser_fuzzer.ninja out.gn/obj/v8_simple_wasm_async_fuzzer.ninja out.gn/obj/v8_simple_wasm_fuzzer.ninja out.gn/obj/third_party/zlib/zlib.ninja out.gn/obj/cppgc_standalone.ninja; do
  for f in out.gn/obj/*.ninja out.gn/obj/third_party/zlib/zlib.ninja; do
    sed -i 's/--threads//g' $f
    sed -i 's/-fuse-ld=gold//g' $f
    sed -i 's/--thread-count=4//g' $f
  done
  for f in out.gn/obj/mksnapshot.ninja out.gn/obj/v8.ninja out.gn/obj/wee8.ninja out.gn/obj/d8.ninja; do
    if [ -f "$f" ]; then
      sed -i "s/libs = -latomic/libs = -lz -latomic/g" $f
    fi
  done

  # [[nodiscard]] support in GCC 9 is not as good as in clang
  sed -i "s/# define V8_HAS_CPP_ATTRIBUTE_NODISCARD (V8_HAS_CPP_ATTRIBUTE(nodiscard))//g" include/v8config.h
fi

find out.gn -type f -name '*.ninja' -exec sed -i 's|-Werror||g' {} +

ninja -C out.gn pdfium

popd

###########################

# echo "########################################"
# echo "## 05-configure.sh"
# echo "########################################"

# mkdir -p "$BUILD"

# (
#   echo "is_debug = $IS_DEBUG"
#   echo "pdf_is_standalone = true"
#   echo "pdf_use_partition_alloc = false"
#   echo "target_cpu = \"$TARGET_CPU\""
#   echo "target_os = \"$OS\""
#   echo "pdf_enable_v8 = $ENABLE_V8"
#   echo "pdf_enable_xfa = $ENABLE_V8"
#   echo "treat_warnings_as_errors = false"
#   echo "is_component_build = false"

#   if [ "$ENABLE_V8" == "true" ]; then
#     echo "v8_use_external_startup_data = false"
#     echo "v8_enable_i18n_support = false"
#   fi

#   case "$OS" in
#   linux)
#     echo "clang_use_chrome_plugins = false"
#     ;;
#   mac)
#     echo "mac_deployment_target = \"${MACOSX_DEPLOYMENT_TARGET}\""
#     echo "clang_use_chrome_plugins = false"
#     echo "mac_sdk_path = \"${CONDA_BUILD_SYSROOT}\""
#     ;;
#   esac

# ) | sort >"$BUILD/args.gn"

# # Generate Ninja files
# pushd "$SOURCE"
# gn gen "$BUILD"
# popd

# # echo "########################################"
# # echo "## 06-build.sh"
# # echo "########################################"

# # ninja -C "$BUILD" pdfium

# # echo "########################################"
# # echo "## 07-stage.sh"
# # echo "########################################"

# # # TODO
