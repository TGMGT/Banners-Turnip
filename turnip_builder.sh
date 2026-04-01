#!/bin/bash -e
set -o pipefail

deps="pkg-config ninja patchelf unzip curl pip flex bison zip git perl glslangValidator python3"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r28"
target_sdk="31"
script_dir="$(pwd)"
patch_dir="$script_dir/patches"

check_deps(){
	for dep in $deps; do
		if ! command -v $dep >/dev/null 2>&1; then echo "Missing: $dep"; exit 1; fi
	done
	pip install meson mako --break-system-packages &> /dev/null || true
}

prepare_ndk(){
	mkdir -p "$workdir" && cd "$workdir"
	if [ ! -d "$ndkver" ]; then
		curl -L "https://dl.google.com/android/repository/${ndkver}-linux.zip" --output "${ndkver}-linux.zip" &> /dev/null
		unzip -q "${ndkver}-linux.zip" &> /dev/null
		rm -rf "${ndkver}-linux.zip"
	fi
    export ANDROID_NDK_HOME="$workdir/$ndkver"
}

compile_mesa() {
    local repo_url="https://gitlab.freedesktop.org/mesa/mesa.git"
    local branch="main"
    local build_name="Turnip-Main-Clean-SDK31"
    local output_tag="V97-Main-SDK31"

    echo "Cloning Mesa Main..."
    
    cd "$workdir"
    rm -rf mesa
    
    git clone --depth 100 -b "$branch" "$repo_url" mesa
    cd mesa

	patch -p1 -i "$patch_dir/mesa-implement-android_stub.patch"
    patch -p1 --forward --batch -i "$patch_dir/mesa-android-include-all-vulkan-extension.patch"

    mkdir -p subprojects && cd subprojects
    rm -rf spirv-tools spirv-headers libdrm
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Tools.git spirv-tools
    git clone --depth=1 https://github.com/KhronosGroup/SPIRV-Headers.git spirv-headers
	git clone --depth=1 https://gitlab.freedesktop.org/mesa/drm.git libdrm
    cd ..

    local build_dir="$workdir/mesa/build"
    rm -rf "$build_dir"

    local ndk_bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local ndk_sys="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
    local cver="31"
    [ ! -f "$ndk_bin/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF > android-cross.txt
[binaries]
ar = '$ndk_bin/llvm-ar'
c = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang', '--sysroot=$ndk_sys']
cpp = ['ccache', '$ndk_bin/aarch64-linux-android${cver}-clang++', '--sysroot=$ndk_sys']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$ndk_bin/aarch64-linux-android-strip'
[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
[built-in options]
c_link_args = ['-static-libstdc++']
cpp_link_args = ['-static-libstdc++']
EOF
    
    export CFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"
    export CXXFLAGS="-D__ANDROID__ -Wno-error -Wno-deprecated-declarations"

    meson setup "$build_dir" --cross-file android-cross.txt \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=31 \
        -Dandroid-stub=true \
        -Dgallium-drivers=freedreno \
        -Dvulkan-drivers=freedreno \
        -Dfreedreno-kmds=kgsl \
        -Degl=enabled \
        -Dglx=disabled \
        -Dvulkan-beta=true \
        -Ddefault_library=shared \
        -Dzstd=disabled \
        -Dwerror=false \
		-Dgles1=enabled \
        -Dgles2=enabled \
		-Dopengl=false \
        -Dgbm=disabled \
        -Dintel-rt=disabled \
        -Dvideo-codecs= \
        -Dzstd=disabled \
        -Dwerror=false \
		-Dallow-fallback-for=libdrm \
        --force-fallback-for=spirv-tools,spirv-headers,libdrm
    
    ninja -C "$build_dir"
	
    local vlk_lib="$build_dir/src/freedreno/vulkan/libvulkan_freedreno.so"
    local egl_lib="$build_dir/src/egl/libEGL.so"
    local gles1_lib="$build_dir/src/mesa/glapi/es1api/libGLESv1_CM.so"
    local gles2_lib="$build_dir/src/mesa/glapi/es2api/libGLESv2.so"

    if [ ! -f "$vlk_lib" ]; then echo "Build Failed: Vulkan missing"; exit 1; fi
    
    local pkg_dir="$workdir/pkg_$output_tag"
    mkdir -p "$pkg_dir"
    
    # Copy with correct names for system hooking
    cp "$vlk_lib"   "$pkg_dir/vulkan.adreno.so"
    cp "$egl_lib"   "$pkg_dir/libEGL.so"
    cp "$gles1_lib" "$pkg_dir/libGLESv1_CM.so"
    cp "$gles2_lib" "$pkg_dir/libGLESv2.so"

    cd "$pkg_dir"
    
    patchelf --set-soname "vulkan.adreno.so" vulkan.adreno.so
    patchelf --set-soname "libEGL.so" libEGL.so
    patchelf --set-soname "libGLESv1_CM.so" libGLESv1_CM.so
    patchelf --set-soname "libGLESv2.so" libGLESv2.so
	
    echo "{
  \"schemaVersion\": 1,
  \"name\": \"$build_name\",
  \"description\": \"System-Ready Mesa Main (SDK 31) + GLES\",
  \"author\": \"StevenMX_TouseefX_nihui\",
  \"packageVersion\": \"1\",
  \"vendor\": \"Mesa\",
  \"driverVersion\": \"$output_tag\",
  \"minApi\": 28,
  \"libraryName\": \"vulkan.adreno.so\",
  \"eglLibraryName\": \"libEGL.so\",
  \"glesv1LibraryName\": \"libGLESv1_CM.so\",
  \"glesv2LibraryName\": \"libGLESv2.so\"
}" > meta.json
    
    zip -9 "$workdir/Turnip-System-${output_tag}.zip" *.so meta.json
    echo "Done: Turnip-System-${output_tag}.zip"
}

check_deps
prepare_ndk
compile_mesa
