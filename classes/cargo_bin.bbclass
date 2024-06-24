inherit rust_bin-common

# Many crates rely on pkg-config to find native versions of their libraries for
# linking - do the simple thing and make it generally available.
DEPENDS:append = "\
    ${@ "cargo-bin-cross-${TARGET_ARCH}" if d.getVar('TARGET_ARCH') != "${BUILD_ARCH}" else "cargo-bin-native" }    \
    pkgconfig-native \
"

# Move CARGO_HOME from default of ~/.cargo
export CARGO_HOME = "${WORKDIR}/cargo_home"

# If something fails while building, this might give useful information
export RUST_BACKTRACE = "1"

# Do build out-of-tree
B = "${WORKDIR}/target"
export CARGO_TARGET_DIR = "${B}"

RUST_TARGET = "${@rust_target(d, 'TARGET')}"
RUST_BUILD = "${@rust_target(d, 'BUILD')}"

# Additional flags passed directly to the "cargo build" invocation
EXTRA_CARGO_FLAGS ??= ""
EXTRA_RUSTFLAGS ??= ""
RUSTFLAGS += "${EXTRA_RUSTFLAGS}"

# Space-separated list of features to enable
CARGO_FEATURES ??= ""

# Control the Cargo build type (debug or release)
CARGO_BUILD_PROFILE ?= "release"

CARGO_INSTALL_DIR ?= "${D}${bindir}"

def cargo_profile_to_builddir(profile):
    # See https://doc.rust-lang.org/cargo/guide/build-cache.html
    # for the special cases mapped here.
    return {
        'dev': 'debug',
        'test': 'debug',
        'release': 'release',
        'bench': 'release',
    }.get(profile, profile)

CARGO_BINDIR = "${B}/${RUST_TARGET}/${@cargo_profile_to_builddir(d.getVar('CARGO_BUILD_PROFILE'))}"
WRAPPER_DIR = "${WORKDIR}/wrappers"

# Set the Cargo manifest path to the typical location
CARGO_MANIFEST_PATH ?= "${S}/Cargo.toml"

FILES:${PN}-dev += "${libdir}/*.rlib"

CARGO_BUILD_FLAGS = "\
    --verbose \
    --manifest-path ${CARGO_MANIFEST_PATH} \
    --target=${RUST_TARGET} \
    --profile=${CARGO_BUILD_PROFILE} \
    ${@oe.utils.conditional('CARGO_FEATURES', '', '', '--features "${CARGO_FEATURES}"', d)} \
    ${EXTRA_CARGO_FLAGS} \
"

cargo_bin_do_configure() {
    mkdir -p "${B}"
    mkdir -p "${CARGO_HOME}"
    mkdir -p "${WRAPPER_DIR}"

    # Yocto provides the C compiler in ${CC} but that includes options beyond
    # the compiler binary. cargo/rustc expect a single binary, so we put ${CC}
    # in a wrapper script.
    echo "#!/bin/sh" >"${WRAPPER_DIR}/cc-wrapper.sh"
    echo "${CC} \"\$@\"" >>"${WRAPPER_DIR}/cc-wrapper.sh"
    chmod +x "${WRAPPER_DIR}/cc-wrapper.sh"

    echo "#!/bin/sh" >"${WRAPPER_DIR}/cxx-wrapper.sh"
    echo "${CXX} \"\$@\"" >>"${WRAPPER_DIR}/cxx-wrapper.sh"
    chmod +x "${WRAPPER_DIR}/cxx-wrapper.sh"

    echo "#!/bin/sh" >"${WRAPPER_DIR}/cc-native-wrapper.sh"
    echo "${CC} \"\$@\"" >>"${WRAPPER_DIR}/cc-native-wrapper.sh"
    chmod +x "${WRAPPER_DIR}/cc-native-wrapper.sh"

    echo "#!/bin/sh" >"${WRAPPER_DIR}/cxx-native-wrapper.sh"
    echo "${CXX} \"\$@\"" >>"${WRAPPER_DIR}/cxx-native-wrapper.sh"
    chmod +x "${WRAPPER_DIR}/cxx-native-wrapper.sh"

    echo "#!/bin/sh" >"${WRAPPER_DIR}/linker-wrapper.sh"
    echo "${CC} ${LDFLAGS} \"\$@\"" >>"${WRAPPER_DIR}/linker-wrapper.sh"
    chmod +x "${WRAPPER_DIR}/linker-wrapper.sh"

    echo "#!/bin/sh" >"${WRAPPER_DIR}/linker-native-wrapper.sh"
    echo "${CC} ${LDFLAGS} \"\$@\"" >>"${WRAPPER_DIR}/linker-native-wrapper.sh"
    chmod +x "${WRAPPER_DIR}/linker-native-wrapper.sh"
}

# wrappers to get around the fact that Rust needs a single
# binary but Yocto's compiler and linker commands have
# arguments. Technically the archiver is always one command but
# this is necessary for builds that determine the prefix and then
# use those commands based on the prefix.
WRAPPER_DIR = "${WORKDIR}/wrapper"
RUST_BUILD_CC = "${WRAPPER_DIR}/build-rust-cc"
RUST_BUILD_CXX = "${WRAPPER_DIR}/build-rust-cxx"
RUST_BUILD_CCLD = "${WRAPPER_DIR}/build-rust-ccld"
RUST_BUILD_AR = "${WRAPPER_DIR}/build-rust-ar"
RUST_TARGET_CC = "${WRAPPER_DIR}/target-rust-cc"
RUST_TARGET_CXX = "${WRAPPER_DIR}/target-rust-cxx"
RUST_TARGET_CCLD = "${WRAPPER_DIR}/target-rust-ccld"
RUST_TARGET_AR = "${WRAPPER_DIR}/target-rust-ar"

create_wrapper_rust () {
	file="$1"
	shift
	extras="$1"
	shift
	crate_cc_extras="$1"
	shift

	cat <<- EOF > "${file}"
	#!/usr/bin/env python3
	import os, sys
	orig_binary = "$@"
	extras = "${extras}"

	# Apply a required subset of CC crate compiler flags
	# when we build a target recipe for a non-bare-metal target.
	# https://github.com/rust-lang/cc-rs/blob/main/src/lib.rs#L1614
	if "CRATE_CC_NO_DEFAULTS" in os.environ.keys() and \
	   "TARGET" in os.environ.keys() and not "-none-" in os.environ["TARGET"]:
	    orig_binary += "${crate_cc_extras}"

	binary = orig_binary.split()[0]
	args = orig_binary.split() + sys.argv[1:]
	if extras:
	    args.append(extras)
	os.execvp(binary, args)
	EOF
	chmod +x "${file}"
}

WRAPPER_TARGET_CC = "${CC}"
WRAPPER_TARGET_CXX = "${CXX}"
WRAPPER_TARGET_CCLD = "${CCLD}"
WRAPPER_TARGET_LDFLAGS = "${LDFLAGS}"
WRAPPER_TARGET_EXTRALD = ""
# see recipes-devtools/gcc/gcc/0018-Add-ssp_nonshared-to-link-commandline-for-musl-targe.patch
# we need to link with ssp_nonshared on musl to avoid "undefined reference to `__stack_chk_fail_local'"
# when building MACHINE=qemux86 for musl
WRAPPER_TARGET_EXTRALD:libc-musl = "-lssp_nonshared"
WRAPPER_TARGET_AR = "${AR}"

# compiler is used by gcc-rs
# linker is used by rustc/cargo
# archiver is used by the build of libstd-rs
do_rust_create_wrappers () {
	mkdir -p "${WRAPPER_DIR}"

	# Yocto Build / Rust Host C compiler
	create_wrapper_rust "${RUST_BUILD_CC}" "" "${CRATE_CC_FLAGS}" "${BUILD_CC}"
	# Yocto Build / Rust Host C++ compiler
	create_wrapper_rust "${RUST_BUILD_CXX}" "" "${CRATE_CC_FLAGS}" "${BUILD_CXX}"
	# Yocto Build / Rust Host linker
	create_wrapper_rust "${RUST_BUILD_CCLD}" "" "" "${BUILD_CCLD}" "${BUILD_LDFLAGS}"
	# Yocto Build / Rust Host archiver
	create_wrapper_rust "${RUST_BUILD_AR}" "" "" "${BUILD_AR}"

	# Yocto Target / Rust Target C compiler
	create_wrapper_rust "${RUST_TARGET_CC}" "${WRAPPER_TARGET_EXTRALD}" "${CRATE_CC_FLAGS}" "${WRAPPER_TARGET_CC}" "${WRAPPER_TARGET_LDFLAGS}"
	# Yocto Target / Rust Target C++ compiler
	create_wrapper_rust "${RUST_TARGET_CXX}" "${WRAPPER_TARGET_EXTRALD}" "${CRATE_CC_FLAGS}" "${WRAPPER_TARGET_CXX}" "${CXXFLAGS}"
	# Yocto Target / Rust Target linker
	create_wrapper_rust "${RUST_TARGET_CCLD}" "${WRAPPER_TARGET_EXTRALD}" "" "${WRAPPER_TARGET_CCLD}" "${WRAPPER_TARGET_LDFLAGS}"
	# Yocto Target / Rust Target archiver
	create_wrapper_rust "${RUST_TARGET_AR}" "" "" "${WRAPPER_TARGET_AR}"

}

addtask rust_create_wrappers before do_configure after do_patch do_prepare_recipe_sysroot
do_rust_create_wrappers[dirs] += "${WRAPPER_DIR}"

cargo_bin_do_compile() {
    export CC="${RUST_TARGET_CC}"
	export CXX="${RUST_TARGET_CXX}"
	export CFLAGS="${CFLAGS}"
	export CXXFLAGS="${CXXFLAGS}"
	export AR="${AR}"
	export TARGET_CC="${RUST_TARGET_CC}"
	export TARGET_CXX="${RUST_TARGET_CXX}"
	export TARGET_CFLAGS="${CFLAGS}"
	export TARGET_CXXFLAGS="${CXXFLAGS}"
	export TARGET_AR="${AR}"
	export HOST_CC="${RUST_BUILD_CC}"
	export HOST_CXX="${RUST_BUILD_CXX}"
	export HOST_CFLAGS="${BUILD_CFLAGS}"
	export HOST_CXXFLAGS="${BUILD_CXXFLAGS}"
	export HOST_AR="${BUILD_AR}"
    export PKG_CONFIG_ALLOW_CROSS="1"
    export LDFLAGS=""
    export RUSTFLAGS="${RUSTFLAGS}"
    export SSH_AUTH_SOCK="${SSH_AUTH_SOCK}"

    # This "DO_NOT_USE_THIS" option of cargo is currently the only way to
    # configure a different linker for host and target builds when RUST_BUILD ==
    # RUST_TARGET.
    export __CARGO_TEST_CHANNEL_OVERRIDE_DO_NOT_USE_THIS="nightly"
    export CARGO_UNSTABLE_TARGET_APPLIES_TO_HOST="true"
    export CARGO_UNSTABLE_HOST_CONFIG="true"
    export CARGO_TARGET_APPLIES_TO_HOST="false"
    export CARGO_TARGET_${@rust_target(d, 'TARGET').replace('-','_').upper()}_LINKER="${RUST_TARGET_CCLD}"
    export CARGO_HOST_LINKER="${RUST_BUILD_CCLD}"
    export CARGO_BUILD_FLAGS="-C rpath"
    export CARGO_PROFILE_RELEASE_DEBUG="true"

    # The CC crate defaults to using CFLAGS when compiling everything. We can
    # give it custom flags for compiling on the host.
    export HOST_CXXFLAGS=""
    export HOST_CFLAGS=""

    bbnote "which rustc:" `which rustc`
    bbnote "rustc --version" `rustc --version`
    bbnote "which cargo:" `which cargo`
    bbnote "cargo --version" `cargo --version`
    bbnote cargo build ${CARGO_BUILD_FLAGS}
    cargo build ${CARGO_BUILD_FLAGS}
}

cargo_bin_do_install() {
    local files_installed=""

    for tgt in "${CARGO_BINDIR}"/*; do
        case $tgt in
            *.so|*.rlib)
                install -d "${D}${libdir}"
                install -m755 "$tgt" "${D}${libdir}"
                files_installed="$files_installed $tgt"
                ;;
            *examples)
                if [ -d "$tgt" ]; then
                    for example in "$tgt/"*; do
                        if [ -f "$example" ] && [ -x "$example" ]; then
                            install -d "${CARGO_INSTALL_DIR}"
                            install -m755 "$example" "${CARGO_INSTALL_DIR}"
                            files_installed="$files_installed $example"
                        fi
                    done
                fi
                ;;
            *)
                if [ -f "$tgt" ] && [ -x "$tgt" ]; then
                    install -d "${CARGO_INSTALL_DIR}"
                    install -m755 "$tgt" "${CARGO_INSTALL_DIR}"
                    files_installed="$files_installed $tgt"
                fi
                ;;
	esac
    done

    if [ -z "$files_installed" ]; then
        bbfatal "Cargo found no files to install"
    else
        bbnote "Installed the following files:"
        for f in $files_installed; do
            bbnote "  " `basename $f`
        done
    fi
}

EXPORT_FUNCTIONS do_configure do_compile do_install
