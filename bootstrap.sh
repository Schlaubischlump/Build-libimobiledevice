#!/bin/bash

# TODO: dylib for openssl
# TODO: arm64e support is missing
# TODO: It would be nice to create a XCFramework with iOSSimulator support
# TODO: Apple silicon support

set -e

MIN_OSX_VERSION="11.0"
MIN_IOS_VERSION="14.0"

###############################################
###    Unpack tar file into a directory     ###
###############################################
untar()
{
    TAR_FILE=$1
    DIR_NAME=$2
    if test -d ${DIR_NAME}; then
        rm -rf ${DIR_NAME}
    fi

    mkdir ${DIR_NAME} && tar xf ${TAR_FILE} -C ${DIR_NAME} --strip-components 1
}

setupPkgConf()
{
    os=$1
    shift 1
    DEPENDENCIES=("$@")
    
    # Setup the package config according to the dependencies.
    PKG_CONFIG_PATH=""
    for d in ${DEPENDENCIES[@]}; do
        PKG_CONFIG_PATH=${PKG_CONFIG_PATH}:../${d}/install_${os}/lib/pkgconfig
    done
    
    export PKG_CONFIG_PATH
}

###############################################
###     Run autogen / configure + make      ###
###############################################

build()
{
    if test -f "Makefile"; then
        make clean
    fi
    
    ARCH=$1
    TARGET=$2
    HOST=$3
    SDK=$4
    FLAGS=$5
        
    SDK_PATH=`xcrun -sdk ${SDK} --show-sdk-path`
    NUM_CPU=`sysctl -n hw.logicalcpu`

    CFLAGS="-arch ${ARCH} -target ${TARGET} -isysroot ${SDK_PATH} -Wno-overriding-t-option -fembed-bitcode"
    
    if [ $SDK = "macosx" ]; then
        CFLAGS="${CFLAGS} -mmacosx-version-min=${MIN_OSX_VERSION}"
    else
        CFLAGS="${CFLAGS} -miphoneos-version-min=${MIN_IOS_VERSION}"
    fi
    
    export CFLAGS
    export CXXFLAGS=${CFLAGS}
    export LDFLAGS=${CFLAGS}
    export CC="$(xcrun --sdk ${SDK} -f clang) ${CFLAGS}"
    export CXX="$(xcrun --sdk ${SDK} -f clang++) ${CFLAGS}"
    
    ./autogen.sh --host=${HOST} ${FLAGS}
    make -j ${NUM_CPU}
    make install
}

###############################################
###   Make a library for iOS or Catalyst    ###
###############################################

buildLibrary()
{
    OS=$1
    NAME=$2
    PREFIX=$4/install_${OS}
    FLAGS="$3 --prefix=${PREFIX}"

    # Create the library output path and the path for make install
    mkdir -p ${PREFIX}
    mkdir -p ../${NAME}/lib/${OS}
    
    # Remove the obsolete prebind flag from configure.ac
    sed 's/,-prebind//g' configure.ac > configure.tmp
    rm configure.ac
    mv configure.tmp configure.ac
    
    echo "Build ${OS}"
    
    if [ ${OS} == iOS ]; then
        build "arm64" "aarch64-apple-ios" "arm-apple-darwin" "iphoneos" "${FLAGS}" &> ../${LOG_FILE}
    else
        if [ ${OS} == catalyst ]; then
            build "x86_64" "x86_64-apple-ios${MIN_IOS_VERSION}-macabi" "x86_64-apple-darwin" "macosx" "${FLAGS}" &> ../${LOG_FILE}
        else
            echo "Unknown os: ${OS}"
            exit 1
        fi
    fi
    
    # Copy the library to the corresponding folder
    TMP=(${PREFIX}/lib/${NAME}-*.a)
    cp ${TMP[0]} ../${NAME}/lib/${OS}/${NAME}.a
    TMP=(${PREFIX}/lib/${NAME}-*.dylib)
    cp ${TMP[0]} ../${NAME}/lib/${OS}/${NAME}.dylib
}


###############################################
###              Merge Library              ###
###############################################

mergeLibrary()
{
    NAME=$1
    echo "Create fat binary"
    lipo \
        ${NAME}/lib/Catalyst/${NAME}.a \
        ${NAME}/lib/iOS/${NAME}.a \
        -create -output ${NAME}/${NAME}.a &> ${LOG_FILE}
    lipo \
        ${NAME}/lib/Catalyst/${NAME}.dylib \
        ${NAME}/lib/iOS/${NAME}.dylib \
        -create -output ${NAME}/${NAME}.dylib &> ${LOG_FILE}
}

###############################################
###     Download / Build / Merge Library    ###
###############################################

buildProject()
{
    REPO=$1
    NAME=$2
    VERSION=$3
    FLAGS=$4
    
    # Read the last dependencies array element.
    shift 4
    DEPENDENCIES=("$@")
    
    # Remove the build product folder if it already exists.
    if test -f ${NAME}; then
        rm -rf ${NAME}
    fi

    LOG_FILE="${NAME}-${VERSION}.log"
    TAR_FILE="${VERSION}.tar.gz"
    PROJECT_DIR="${NAME}-${VERSION}"
    INSTALL_PATH="$(pwd)/${NAME}"
    
    # Download and unpack the library file.
    if [ ! -e ${TAR_FILE} ]; then
        echo "Downloading ${TAR_FILE}"
        curl -OL https://github.com/${REPO}/${NAME}/archive/${TAR_FILE}
    else
        echo "Using ${TAR_FILE}"
    fi

    echo "Unpacking ${NAME}"
    untar ${TAR_FILE} ${PROJECT_DIR}

    # Build the library file.
    echo "Building ${NAME}..."
    
    pushd . > /dev/null
    cd ${PROJECT_DIR}

    setupPkgConf "iOS" "${DEPENDENCIES[@]}"
    buildLibrary "iOS" ${NAME} "${FLAGS}" ${INSTALL_PATH}
    
    setupPkgConf "catalyst" "${DEPENDENCIES[@]}"
    buildLibrary "catalyst" ${NAME} "${FLAGS}" ${INSTALL_PATH}
    
    popd > /dev/null
    
    mergeLibrary ${NAME}
    
    # Copy the header files to include. PREFIX is defined by the last buildLibrary operation.
    echo "Copy header"
    cp -R ${PREFIX}/include ${NAME}/include
    
    echo "Done building ${NAME}"
    
    # Cleanup the temporary files.
    echo "Cleanup ${NAME}..."
    rm -rf ${NAME}/lib
    rm -rf ${PROJECT_DIR}
    rm ${TAR_FILE}
    rm ${LOG_FILE}
}

###############################################
###    Function to build the dependencies   ###
###############################################

buildLibplist()
{
    buildProject "libimobiledevice" "libplist" "2.2.0" "--disable-dependency-tracking --without-cython"
}

buildLibusbmuxd()
{
    DEP=(
        "libusb"
        "libplist"
    )
    buildProject "libimobiledevice" "libusbmuxd" "2.0.2" "--disable-dependency-tracking --without-cython --disable-silent-rules" "${DEP[@]}"
}

buildLibimobiledevice()
{
    DEP=(
        "libssl"
        "libplist"
        "libusbmuxd"
    )
    buildProject "libimobiledevice" "libimobiledevice" "1.3.0" "--disable-dependency-tracking --without-cython --disable-silent-rules --enable-debug-code" "${DEP[@]}"
}

buildLibusb()
{
    # Try to copy the IOKit header to the iOS IOKit framework from macOS.
    MACOS_SDK_PATH=`xcrun -sdk macosx${MIN_OSX_VERSION} --show-sdk-path`
    IOS_SDK_PATH=`xcrun -sdk iphoneos${MIN_IOS_VERSION} --show-sdk-path`
    IOKIT_FRAMEWORK="System/Library/Frameworks/IOKit.framework"
    MACOS_IOKIT_HEADER=${MACOS_SDK_PATH}/${IOKIT_FRAMEWORK}/Versions/A/Headers
    
    if test -d ${IOS_SDK_PATH}/${IOKIT_FRAMEWORK}/Headers; then
        echo "IOKit Headers already copied."
    else
        echo "Copy IOKit Headers..."
        sudo cp -r ${MACOS_IOKIT_HEADER} ${IOS_SDK_PATH}/${IOKIT_FRAMEWORK}
        sudo ${MACOS_SDK_PATH}/usr/include/libkern/OSTypes.h ${IOS_SDK_PATH}/usr/include/libkern
    fi
    
    buildProject "libusb" "libusb" "v1.0.23" ""
}

buildOpenSSL()
{
    REPO="x2on"
    NAME="libssl"
    VERSION="1.1.1g"

    LOG_FILE="${NAME}-${VERSION}.log"
    PROJECT_DIR="OpenSSL-for-iPhone-master"

    # OpenSSL is a little bit special
    ZIP_FILE="master.zip"
    if [ ! -e ${ZIP_FILE} ]; then
        echo "Downloading ${ZIP_FILE}"
        curl -OL https://github.com/${REPO}/OpenSSL-for-iPhone/archive/${ZIP_FILE}
    else
        echo "Using ${ZIP_FILE}"
    fi
    
    # Unpack the repo and overwrite any existing directory.
    unzip -o ${ZIP_FILE} &> ${LOG_FILE}
    
    # Remove the build product folder if it already exists.
    if test -f ${NAME}; then
        rm -rf ${NAME}
    fi
    
    mkdir -p ${NAME}
    
    echo "Building ${NAME}..."
    
    pushd . > /dev/null
    cd ${PROJECT_DIR}
    # build catalyst + iOS
    ./build-libssl.sh --version=${VERSION} \
                      --targets="mac-catalyst-x86_64 ios64-cross-arm64" \
                      --macosx-sdk="${MIN_OSX_VERSION}" \
                      --ios-sdk="${MIN_IOS_VERSION}" &> ../${LOG_FILE}
                      
    cp -R bin/iPhoneOS${MIN_IOS_VERSION}-arm64.sdk ../${NAME}/install_iOS
    cp -R bin/MacOSX${MIN_OSX_VERSION}-x86_64.sdk ../${NAME}/install_catalyst
    popd > /dev/null
    
    echo "Fixing PKG_CONF"
    PKG_FILES=(
        "libcrypto.pc"
        "libssl.pc"
        "openssl.pc"
    )
    
    for d in ${PKG_FILES[@]}; do
        IOS_PKG_PATH="${NAME}/install_iOS/lib/pkgconfig"
        sed "s/OpenSSL-for-iPhone-master\/bin\/iPhoneOS14.0-arm64.sdk/${NAME}\/install_iOS/g" ${IOS_PKG_PATH}/${d} > ${IOS_PKG_PATH}/${d}.tmp
        rm ${IOS_PKG_PATH}/${d}
        mv ${IOS_PKG_PATH}/${d}.tmp ${IOS_PKG_PATH}/${d}
        
        CATALYST_PKG_PATH="${NAME}/install_catalyst/lib/pkgconfig"
        sed "s/OpenSSL-for-iPhone-master\/bin\/MacOSX11.0-x86_64.sdk/${NAME}\/install_catalyst/g" ${CATALYST_PKG_PATH}/${d} > ${CATALYST_PKG_PATH}/${d}.tmp
        rm ${CATALYST_PKG_PATH}/${d}
        mv ${CATALYST_PKG_PATH}/${d}.tmp ${CATALYST_PKG_PATH}/${d}
    done
    
    # Create a fat binary
    echo "Link libraries"
    lipo \
        ${NAME}/install_iOS/lib/libcrypto.a \
        ${NAME}/install_catalyst/lib/libcrypto.a \
        -create -output ${NAME}/libcrypto.a  &> ${LOG_FILE}
    lipo \
        ${NAME}/install_iOS/lib/libssl.a \
        ${NAME}/install_catalyst/lib/libssl.a \
        -create -output ${NAME}/libssl.a  &> ${LOG_FILE}
        
    # Copy the header files
    echo "Copy header"
    cp -R ${NAME}/install_iOS/include ${NAME}/include
    
    echo "Done building ${NAME}"
    
    echo "Cleanup ${NAME}..."
    rm ${LOG_FILE}
    rm ${ZIP_FILE}
    rm -rf ${PROJECT_DIR}
}


###############################################
###         Main build instructions         ###
###############################################

buildLibplist
buildLibusb
buildLibusbmuxd
buildOpenSSL
buildLibimobiledevice
