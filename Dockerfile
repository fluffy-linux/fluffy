ARG ATTR_VERSION=2.6.0
ARG ACL_VERSION=2.4.0
ARG AUTOCONF_VERSION=2.73
ARG AUTOMAKE_VERSION=1.18.1
# avoid conflict with builtin var BASH_VERSION
ARG BASH_VERSION_=5.3
ARG BC_VERSION=7.0.3
ARG BINUTILS_VERSION=2.47
ARG BISON_VERSION=3.8.2
ARG BLFS_SYSTEMD_UNITS_VERSION=20251204
ARG BTRFS_PROGS_VERSION=7.1
ARG BZIP2_VERSION=1.0.8
ARG COREUTILS_VERSION=9.11
ARG CTYPES_SH_VERSION=1.3
ARG DBUS_VERSION=1.16.2
ARG DEJAGNU_VERSION=1.6.3
ARG DIFFUTILS_VERSION=3.12
ARG ELFUTILS_VERSION=0.195
ARG E2FSPROGS_VERSION=1.47.4
ARG EXPAT_VERSION=2.8.3
ARG EXPECT_VERSION=5.45.4
ARG FILE_VERSION=5.48
ARG FINDUTILS_VERSION=4.11.0
ARG FLEX_VERSION=2.6.4
ARG FLIT_CORE_VERSION=4.0.2
ARG GAWK_VERSION=5.4.1
ARG GCC_VERSION=16.2.0
ARG GDBM_VERSION=1.26
ARG GETTEXT_VERSION=1.0
ARG GLIBC_VERSION=2.44
ARG GMP_VERSION=6.3.0
ARG GRUB_VERSION=2.14
ARG GPERF_VERSION=3.3
ARG GREP_VERSION=3.12
ARG GROFF_VERSION=1.24.1
ARG GZIP_VERSION=1.14
ARG IANA_ETC_VERSION=20260805
ARG INET_UTILS_VERSION=2.8
ARG IPROUTE2_VERSION=7.1.0
ARG JINJA2_VERSION=3.1.6
ARG KBD_VERSION=2.10.0
ARG KMOD_VERSION=34.2
ARG LESS_VERSION=704
ARG LIBCAP_VERSION=2.78
ARG LIBFFI_VERSION=3.8.0
ARG LIBPIPELINE_VERSION=1.5.8
ARG LIBTASN1_VERSION=4.21.0
ARG LIBTOOL_VERSION=2.6.2
ARG LIBXCRYPT_VERSION=4.5.2
ARG LINUX_MAJOR=7
ARG LINUX_VERSION=${LINUX_MAJOR}.1.8
ARG LZ4_VERSION=1.10.0
ARG LZO_VERSION=2.10
ARG MAKE_CA_VERSION=1.16.1
ARG MAKE_VERSION=4.4.1
ARG MAN_DB_VERSION=2.13.1
ARG MAN_PAGES_VERSION=6.18
ARG MARKUPSAFE_VERSION=3.0.3
ARG MESON_VERSION=1.12.0
ARG MPC_VERSION=1.4.1
ARG MPDECIMAL_VERSION=4.0.1
ARG MPFR_VERSION=4.2.2
ARG M4_VERSION=1.4.21
ARG NCURSES_VERSION=6.6
ARG NINJA_VERSION=1.13.2
ARG OPENSSH_VERSION=10.5p1
ARG OPENSSL_VERSION=4.0.1
ARG P11_KIT_VERSION=0.26.5
ARG PACKAGING_VERSION=26.3
ARG PATCH_VERSION=2.8
ARG PCRE2_VERSION=10.47
ARG PERL_MAJOR_MINOR_VERSION=5.44
ARG PERL_VERSION=${PERL_MAJOR_MINOR_VERSION}.0
ARG PKGCONF_VERSION=3.0.5
ARG PROCPS_NG_VERSION=4.0.7
ARG PSMISC_VERSION=23.7
ARG PYTHON_VERSION=3.14.7
ARG READLINE_VERSION=8.3
ARG SED_VERSION=4.10
ARG SETUPTOOLS_VERSION=84.0.0
ARG SHADOW_VERSION=4.20.2
ARG SQLITE_VERSION=3530400
ARG SQLITE_MMM_VERSION=3.53.4
ARG SYSTEMD_VERSION=261.2
ARG TAR_VERSION=1.35
ARG TCL_VERSION=8.6.18
ARG TEXINFO_VERSION=7.3
ARG TZDATA_VERSION=2026c
ARG UTIL_LINUX_VERSION=2.42.2
ARG VIM_VERSION=9.2.1025
ARG WGET_VERSION=1.25.0
ARG WHEEL_VERSION=0.48.0
ARG XZ_VERSION=5.8.3
ARG ZLIB_VERSION=1.3.2
ARG ZSTD_VERSION=1.5.7

FROM debian:12.15-slim AS ch2

RUN <<EOF
apt update
apt install -y bash binutils bison gawk gcc g++ make patch perl python3 texinfo wget xz-utils
EOF

SHELL ["/bin/bash", "-c"]

ENV LFS=/mnt/lfs

FROM ch2 AS ch4
RUN <<EOF
mkdir -pv $LFS/{etc,var} $LFS/usr/{bin,lib,sbin}
for i in bin lib sbin; do \
  ln -sv usr/$i $LFS/$i; \
done

case $(uname -m) in \
  x86_64) mkdir -pv $LFS/lib64 ;; \
esac

mkdir -pv $LFS/tools
mkdir -pv /work

groupadd lfs
useradd -s /bin/bash -g lfs -m -k /dev/null lfs
chown -v lfs $LFS/{usr{,/*},var,etc,tools} /work
case $(uname -m) in \
  x86_64) chown -v lfs $LFS/lib64 ;; \
esac
EOF

USER lfs

ENV LC_ALL=POSIX
ENV LFS_TGT=x86_64-lfs-linux-gnu
ENV PATH=$LFS/tools/bin:/bin:/usr/bin
ENV CONFIG_SITE=$LFS/usr/share/config.site
ENV MAKEFLAGS=-j7

FROM ch4 AS ch5
WORKDIR /work


ARG BINUTILS_VERSION
ARG BINUTILS_ARCHIVE=binutils-${BINUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BINUTILS_ARCHIVE},target=/packages/${BINUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BINUTILS_ARCHIVE}
mkdir -pv build
cd build
../configure --prefix=$LFS/tools \
    --with-sysroot=$LFS \
    --target=$LFS_TGT   \
    --disable-nls       \
    --enable-gprofng=no \
    --disable-werror    \
    --enable-new-dtags  \
    --enable-default-hash-style=gnu
make
make install
EOF

ARG GLIBC_VERSION
ARG GCC_VERSION
ARG GCC_ARCHIVE=gcc-${GCC_VERSION}.tar.xz
ARG MPFR_VERSION
ARG MPFR_ARCHIVE=mpfr-${MPFR_VERSION}.tar.xz
ARG MPC_VERSION
ARG MPC_ARCHIVE=mpc-${MPC_VERSION}.tar.xz
ARG GMP_VERSION
ARG GMP_ARCHIVE=gmp-${GMP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GCC_ARCHIVE},target=/packages/${GCC_ARCHIVE} \
--mount=type=bind,source=packages/${MPFR_ARCHIVE},target=/packages/${MPFR_ARCHIVE} \
--mount=type=bind,source=packages/${MPC_ARCHIVE},target=/packages/${MPC_ARCHIVE} \
--mount=type=bind,source=packages/${GMP_ARCHIVE},target=/packages/${GMP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GCC_ARCHIVE}
tar -xf /packages/${MPFR_ARCHIVE}
mv -v mpfr-${MPFR_VERSION} mpfr
tar -xf /packages/${MPC_ARCHIVE}
mv -v mpc-${MPC_VERSION} mpc
tar -xf /packages/${GMP_ARCHIVE}
mv -v gmp-${GMP_VERSION} gmp
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
mkdir -pv build
cd build
../configure                  \
    --target=$LFS_TGT         \
    --prefix=$LFS/tools       \
    --with-glibc-version=${GLIBC_VERSION} \
    --with-sysroot=$LFS       \
    --with-newlib             \
    --without-headers         \
    --enable-default-pie      \
    --enable-default-ssp      \
    --disable-fixincludes     \
    --disable-nls             \
    --disable-shared          \
    --disable-multilib        \
    --disable-threads         \
    --disable-libatomic       \
    --disable-libgomp         \
    --disable-libquadmath     \
    --disable-libssp          \
    --disable-libvtv          \
    --disable-libstdcxx       \
    --enable-languages=c,c++
make
make install
cat ../gcc/{limitx,glimits,limity}.h > $($LFS_TGT-gcc -print-file-name=include)/limits.h
EOF

ARG LINUX_MAJOR
ARG LINUX_VERSION
ARG LINUX_ARCHIVE=linux-${LINUX_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${LINUX_ARCHIVE},target=/packages/${LINUX_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LINUX_ARCHIVE}
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include $LFS/usr
EOF

ARG GLIBC_VERSION
ARG GLIBC_ARCHIVE=glibc-${GLIBC_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GLIBC_ARCHIVE},target=/packages/${GLIBC_ARCHIVE} \
--mount=type=bind,source=packages/glibc-fhs-1.patch,target=/packages/glibc-fhs-1.patch \
--mount=type=bind,source=packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch,target=/packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GLIBC_ARCHIVE}
ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64
ln -sfv ../lib/ld-linux-x86-64.so.2 $LFS/lib64/ld-lsb-x86-64.so.3
patch -Np1 -i /packages/glibc-fhs-1.patch
patch -Np1 -i /packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch
mkdir -v build
cd build
echo "rootsbindir=/usr/sbin" > configparms
../configure                        \
    --prefix=/usr                       \
    --host=$LFS_TGT                     \
    --build=$(../scripts/config.guess)  \
    --disable-nscd                      \
    libc_cv_slibdir=/usr/lib            \
    --enable-kernel=5.10
make
make DESTDIR=$LFS install
sed '/RTLDLIST=/s@/usr@@g' -i $LFS/usr/bin/ldd
# test
echo 'int main(){}' | $LFS_TGT-gcc -x c - -v -Wl,--verbose &> dummy.log
$LFS_TGT-readelf -l a.out | grep ': /lib'
rm a.out dummy.log
EOF

ARG GCC_VERSION
ARG GCC_ARCHIVE=gcc-${GCC_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GCC_ARCHIVE},target=/packages/${GCC_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GCC_ARCHIVE}
mkdir -pv build
cd build
../libstdc++-v3/configure   \
    --host=$LFS_TGT             \
    --build=$(../config.guess)  \
    CXX=$LFS_TGT-gcc            \
    --prefix=/usr               \
    --disable-multilib          \
    --disable-nls               \
    --disable-libstdcxx-pch     \
    --with-gxx-include-dir=/tools/$LFS_TGT/include/c++/16.2.0
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{stdc++{,exp,fs},supc++}.la
EOF

FROM ch5 AS ch6
ARG M4_VERSION
ARG M4_ARCHIVE=m4-${M4_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${M4_ARCHIVE},target=/packages/${M4_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${M4_ARCHIVE}
echo ac_cv_func_posix_spawn_file_actions_addchdir=yes >> $LFS/usr/share/config.site
echo ac_cv_func_posix_spawn_file_actions_addfchdir=yes >> $LFS/usr/share/config.site
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG NCURSES_VERSION
ARG NCURSES_ARCHIVE=ncurses-${NCURSES_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${NCURSES_ARCHIVE},target=/packages/${NCURSES_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${NCURSES_ARCHIVE}
mkdir -pv build
pushd build
    ../configure --prefix=$LFS/tools AWK=gawk
    make -C include
    make -C progs tic
    install progs/tic $LFS/tools/bin
popd
./configure --prefix=/usr       \
    --host=$LFS_TGT                 \
    --build=$(./config.guess)       \
    --mandir=/usr/share/man         \
    --with-manpage-format=normal    \
    --with-shared                   \
    --without-normal                \
    --with-cxx-shared               \
    --without-debug                 \
    --without-ada                   \
    --disable-stripping             \
    AWK=gawk
make
make DESTDIR=$LFS install
ln -sv libncursesw.so $LFS/usr/lib/libncurses.so
sed -e 's/^#if.*XOPEN.*$/#if 1/' -i $LFS/usr/include/curses.h
EOF

ARG BASH_VERSION_
ARG BASH_ARCHIVE=bash-${BASH_VERSION_}.tar.gz
RUN --mount=type=bind,source=packages/${BASH_ARCHIVE},target=/packages/${BASH_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BASH_ARCHIVE}
./configure --prefix=/usr           \
    --build=$(sh support/config.guess)  \
    --host=$LFS_TGT                     \
    --without-bash-malloc               \
    --docdir=/usr/share/doc/bash-${BASH_VERSION_}
make
make DESTDIR=$LFS install
ln -sv bash $LFS/bin/sh
EOF

ARG COREUTILS_VERSION
ARG COREUTILS_ARCHIVE=coreutils-${COREUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${COREUTILS_ARCHIVE},target=/packages/${COREUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${COREUTILS_ARCHIVE}
./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)   \
    --enable-install-program=hostname
make
make DESTDIR=$LFS install
mv -v $LFS/usr/bin/chroot              $LFS/usr/sbin
mkdir -pv $LFS/usr/share/man/man8
mv -v $LFS/usr/share/man/man1/chroot.1 $LFS/usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/'                    $LFS/usr/share/man/man8/chroot.8
EOF

ARG DIFFUTILS_VERSION
ARG DIFFUTILS_ARCHIVE=diffutils-${DIFFUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${DIFFUTILS_ARCHIVE},target=/packages/${DIFFUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${DIFFUTILS_ARCHIVE}
./configure --prefix=/usr       \
    --host=$LFS_TGT                 \
    gl_cv_func_strcasecmp_works=yes \
    --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG FILE_VERSION
ARG FILE_ARCHIVE=file-${FILE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${FILE_ARCHIVE},target=/packages/${FILE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${FILE_ARCHIVE}
mkdir build
pushd build
    ../configure            \
        --disable-bzlib         \
        --disable-libseccomp    \
        --disable-xzlib         \
        --disable-zlib
    make
popd
./configure     \
    --prefix=/usr   \
    --host=$LFS_TGT \
    --build=$(./config.guess)
make FILE_COMPILE=$(pwd)/build/src/file
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/libmagic.la
EOF

ARG FINDUTILS_VERSION
ARG FINDUTILS_ARCHIVE=findutils-${FINDUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${FINDUTILS_ARCHIVE},target=/packages/${FINDUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${FINDUTILS_ARCHIVE}
./configure --prefix=/usr       \
    --localstatedir=/var/lib/locate \
    --host=$LFS_TGT                 \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG GAWK_VERSION
ARG GAWK_ARCHIVE=gawk-${GAWK_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GAWK_ARCHIVE},target=/packages/${GAWK_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GAWK_ARCHIVE}
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG GREP_VERSION
ARG GREP_ARCHIVE=grep-${GREP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GREP_ARCHIVE},target=/packages/${GREP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GREP_ARCHIVE}
./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG GZIP_VERSION
ARG GZIP_ARCHIVE=gzip-${GZIP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GZIP_ARCHIVE},target=/packages/${GZIP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GZIP_ARCHIVE}
./configure --prefix=/usr   \
    --host=$LFS_TGT
make
make DESTDIR=$LFS install
EOF

ARG MAKE_VERSION
ARG MAKE_ARCHIVE=make-${MAKE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${MAKE_ARCHIVE},target=/packages/${MAKE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MAKE_ARCHIVE}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG PATCH_VERSION
ARG PATCH_ARCHIVE=patch-${PATCH_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${PATCH_ARCHIVE},target=/packages/${PATCH_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PATCH_ARCHIVE}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG SED_VERSION
ARG SED_ARCHIVE=sed-${SED_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${SED_ARCHIVE},target=/packages/${SED_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${SED_ARCHIVE}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG TAR_VERSION
ARG TAR_ARCHIVE=tar-${TAR_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${TAR_ARCHIVE},target=/packages/${TAR_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${TAR_ARCHIVE}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
EOF

ARG XZ_VERSION
ARG XZ_ARCHIVE=xz-${XZ_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${XZ_ARCHIVE},target=/packages/${XZ_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${XZ_ARCHIVE}
./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)   \
    --disable-static                    \
    --docdir=/usr/share/doc/xz-${XZ_VERSION}
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/liblzma.la
EOF

# binutils pass 2
ARG BINUTILS_VERSION
ARG BINUTILS_ARCHIVE=binutils-${BINUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BINUTILS_ARCHIVE},target=/packages/${BINUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BINUTILS_ARCHIVE}
sed '6031s/$add_dir//' -i ltmain.sh
mkdir -v build
cd build
../configure                \
    --prefix=/usr               \
    --build=$(../config.guess)  \
    --host=$LFS_TGT             \
    --disable-nls               \
    --enable-shared             \
    --enable-gprofng=no         \
    --disable-werror            \
    --enable-64-bit-bfd         \
    --enable-new-dtags          \
    --enable-default-hash-style=gnu
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/lib{bfd,ctf,ctf-nobfd,opcodes,sframe}.{a,la}
EOF

# gcc pass 2
ARG GLIBC_VERSION
ARG GCC_VERSION
ARG GCC_ARCHIVE=gcc-${GCC_VERSION}.tar.xz
ARG MPFR_VERSION
ARG MPFR_ARCHIVE=mpfr-${MPFR_VERSION}.tar.xz
ARG MPC_VERSION
ARG MPC_ARCHIVE=mpc-${MPC_VERSION}.tar.xz
ARG GMP_VERSION
ARG GMP_ARCHIVE=gmp-${GMP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GCC_ARCHIVE},target=/packages/${GCC_ARCHIVE} \
--mount=type=bind,source=packages/${MPFR_ARCHIVE},target=/packages/${MPFR_ARCHIVE} \
--mount=type=bind,source=packages/${MPC_ARCHIVE},target=/packages/${MPC_ARCHIVE} \
--mount=type=bind,source=packages/${GMP_ARCHIVE},target=/packages/${GMP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GCC_ARCHIVE}
tar -xf /packages/${MPFR_ARCHIVE}
mv -v mpfr-${MPFR_VERSION} mpfr
tar -xf /packages/${MPC_ARCHIVE}
mv -v mpc-${MPC_VERSION} mpc
tar -xf /packages/${GMP_ARCHIVE}
mv -v gmp-${GMP_VERSION} gmp
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
sed '/thread_header =/s/@.*@/gthr-posix.h/' -i libgcc/Makefile.in libstdc++-v3/include/Makefile.in
mkdir -v build
cd build
../configure                                        \
    --build=$(../config.guess)                          \
    --host=$LFS_TGT                                     \
    --target=$LFS_TGT                                   \
    --prefix=/usr                                       \
    --with-build-sysroot=$LFS                           \
    --enable-default-pie                                \
    --enable-default-ssp                                \
    --disable-fixincludes                               \
    --disable-nls                                       \
    --disable-multilib                                  \
    --disable-libatomic                                 \
    --disable-libgomp                                   \
    --disable-libquadmath                               \
    --disable-libsanitizer                              \
    --disable-libssp                                    \
    --disable-libvtv                                    \
    --enable-languages=c,c++                            \
    CXX_FOR_TARGET="$LFS_TGT-gcc -nostdinc++"           \
    LDFLAGS_FOR_TARGET=-L$PWD/$LFS_TGT/libgcc           \
    target_configargs=gcc_cv_target_thread_file=posix
make
make DESTDIR=$LFS install
ln -sv gcc $LFS/usr/bin/cc
EOF

USER root
RUN chown --from lfs -R root:root $LFS/{usr,var,etc,tools,lib64}

FROM scratch AS ch7
COPY --from=ch6 /mnt/lfs /
ENV HOME=/root
ENV PATH=/usr/bin:/usr/sbin
ENV MAKEFLAGS=-j7
ENV TESTSUITEFLAGS=-j7
SHELL ["/bin/bash", "--login", "-c"]
RUN <<EOF
set -euo pipefail

mkdir -p /work

mkdir -pv /{boot,home,mnt,opt,srv}

mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{include,src}
mkdir -pv /usr/lib/locale
mkdir -pv /usr/local/{bin,lib,sbin}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}

ln -sfv /run /var/run
ln -sfv /run/lock /var/lock

install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp
ln -sv /proc/self/mounts /etc/mtab
# TODO write real /etc/hosts after export
cat <<"HOSTS" >/etc/hosts.tmp
127.0.0.1  localhost $(hostname)
::1        localhost
HOSTS
cat <<"PASSWD" >/etc/passwd
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
PASSWD
cat <<"GROUP" >/etc/group
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
clock:x:14:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
nogroup:x:65534:
GROUP
echo "tester:x:101:101::/home/tester:/bin/bash" >> /etc/passwd
echo "tester:x:101:" >> /etc/group
install -o tester -d /home/tester
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664  /var/log/lastlog
chmod -v 600  /var/log/btmp
EOF

WORKDIR /work
ARG GETTEXT_VERSION
ARG GETTEXT_ARCHIVE=gettext-${GETTEXT_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GETTEXT_ARCHIVE},target=/packages/${GETTEXT_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GETTEXT_ARCHIVE}
./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
EOF

ARG BISON_VERSION
ARG BISON_ARCHIVE=bison-${BISON_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BISON_ARCHIVE},target=/packages/${BISON_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BISON_ARCHIVE}
./configure --prefix=/usr \
    --docdir=/usr/share/doc/bison-${BISON_VERSION}
make
make install
EOF

ARG PERL_MAJOR_MINOR_VERSION
ARG PERL_VERSION
ARG PERL_ARCHIVE=perl-${PERL_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${PERL_ARCHIVE},target=/packages/${PERL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PERL_ARCHIVE}
sh Configure -des                               \
    -D prefix=/usr                                  \
    -D vendorprefix=/usr                            \
    -D useshrplib                                   \
    -D privlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/core_perl        \
    -D archlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/core_perl        \
    -D sitelib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/site_perl        \
    -D sitearch=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/site_perl       \
    -D vendorlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/vendor_perl    \
    -D vendorarch=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/vendor_perl
make
make install
EOF

ARG ZLIB_VERSION
ARG ZLIB_ARCHIVE=zlib-${ZLIB_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${ZLIB_ARCHIVE},target=/packages/${ZLIB_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${ZLIB_ARCHIVE}
./configure --prefix=/usr
make
make install
rm -fv /usr/lib/libz.a
EOF

ARG MPDECIMAL_VERSION
ARG MPDECIMAL_ARCHIVE=mpdecimal-${MPDECIMAL_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${MPDECIMAL_ARCHIVE},target=/packages/${MPDECIMAL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MPDECIMAL_ARCHIVE}
./configure --prefix=/usr   \
    --disable-static            \
    --docdir=/usr/share/doc/mpdecimal-${MPDECIMAL_VERSION}
make
make install
EOF

ARG PYTHON_VERSION
ARG PYTHON_ARCHIVE=Python-${PYTHON_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${PYTHON_ARCHIVE},target=/packages/${PYTHON_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PYTHON_ARCHIVE}
./configure --prefix=/usr   \
    --enable-shared             \
    --without-ensurepip         \
    --without-static-libpython
make
make install
EOF

ARG TEXINFO_VERSION
ARG TEXINFO_ARCHIVE=texinfo-${TEXINFO_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${TEXINFO_ARCHIVE},target=/packages/${TEXINFO_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${TEXINFO_ARCHIVE}
./configure --prefix=/usr
make
make install
EOF

ARG UTIL_LINUX_VERSION
ARG UTIL_LINUX_ARCHIVE=util-linux-${UTIL_LINUX_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${UTIL_LINUX_ARCHIVE},target=/packages/${UTIL_LINUX_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${UTIL_LINUX_ARCHIVE}
mkdir -pv /var/lib/hwclock
./configure --libdir=/usr/lib     \
    --runstatedir=/run    \
    --disable-chfn-chsh   \
    --disable-login       \
    --disable-nologin     \
    --disable-su          \
    --disable-setpriv     \
    --disable-runuser     \
    --disable-pylibmount  \
    --disable-static      \
    --disable-liblastlog2 \
    --without-python      \
    ADJTIME_PATH=/var/lib/hwclock/adjtime \
    --docdir=/usr/share/doc/util-linux-${UTIL_LINUX_VERSION}
make
make install
EOF

RUN <<EOF
set -euo pipefail
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name \*.la -delete
rm -rf /tools
EOF

FROM ch7 AS ch8
ARG MAN_PAGES_VERSION
ARG MAN_PAGES_ARCHIVE=man-pages-${MAN_PAGES_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${MAN_PAGES_ARCHIVE},target=/packages/${MAN_PAGES_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MAN_PAGES_ARCHIVE}
rm -v man3/crypt*
make -R GIT=false prefix=/usr install
EOF

ARG IANA_ETC_VERSION
ARG IANA_ETC_ARCHIVE=iana-etc-${IANA_ETC_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${IANA_ETC_ARCHIVE},target=/packages/${IANA_ETC_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${IANA_ETC_ARCHIVE}
cp -v services protocols /etc
EOF

ARG GLIBC_VERSION
ARG GLIBC_ARCHIVE=glibc-${GLIBC_VERSION}.tar.xz
ARG LINUX_VERSION
ARG TZDATA_VERSION
ARG TZDATA_ARCHIVE=tzdata${TZDATA_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${GLIBC_ARCHIVE},target=/packages/${GLIBC_ARCHIVE} \
--mount=type=bind,source=packages/${TZDATA_ARCHIVE},target=/packages/${TZDATA_ARCHIVE} \
--mount=type=bind,source=packages/glibc-fhs-1.patch,target=/packages/glibc-fhs-1.patch \
--mount=type=bind,source=packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch,target=/packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GLIBC_ARCHIVE}
patch -Np1 -i /packages/glibc-fhs-1.patch
patch -Np1 -i /packages/glibc-${GLIBC_VERSION}-upstream_fixes-1.patch
mkdir -v build
cd build
../configure --prefix=/usr      \
    --disable-werror                \
    --disable-nscd                  \
    libc_cv_slibdir=/usr/lib        \
    --enable-stack-protector=strong \
    --enable-kernel=${LINUX_VERSION}
make
# make check
touch /etc/ld.so.conf
sed '/test-installation/s@$(PERL)@echo not running@' -i ../Makefile
make install
sed '/RTLDLIST=/s@/usr@@g' -i /usr/bin/ldd
make localedata/install-locales
cat <<"NSSWITCH" >/etc/nsswitch.conf
# Begin /etc/nsswitch.conf

passwd: files systemd
group: files systemd
shadow: files systemd

hosts: mymachines resolve [!UNAVAIL=return] files myhostname dns
networks: files

protocols: files
services: files
ethers: files
rpc: files

# End /etc/nsswitch.conf
NSSWITCH
tar -xf /packages/${TZDATA_ARCHIVE}
ZONEINFO=/usr/share/zoneinfo
mkdir -pv $ZONEINFO/{posix,right}
for tz in etcetera southamerica northamerica europe africa antarctica asia australasia backward
do
    zic -L /dev/null   -d $ZONEINFO       ${tz}
    zic -L /dev/null   -d $ZONEINFO/posix ${tz}
    zic -L leapseconds -d $ZONEINFO/right ${tz}
done
cp -v zone.tab zone1970.tab iso3166.tab $ZONEINFO
zic -d $ZONEINFO -p America/New_York
ln -sfv $ZONEINFO/America/New_York /etc/localtime
unset ZONEINFO
cat <<"LDSOCONF" > /etc/ld.so.conf
# Begin /etc/ld.so.conf
/usr/local/lib
/opt/lib

LDSOCONF
cat <<"LDSOCONF" >> /etc/ld.so.conf
# Add an include directory
include /etc/ld.so.conf.d/*.conf

LDSOCONF
mkdir -pv /etc/ld.so.conf.d
EOF

ARG ZLIB_VERSION
ARG ZLIB_ARCHIVE=zlib-${ZLIB_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${ZLIB_ARCHIVE},target=/packages/${ZLIB_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${ZLIB_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
rm -fv /usr/lib/libz.a
EOF

ARG BZIP2_VERSION
ARG BZIP2_ARCHIVE=bzip2-${BZIP2_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${BZIP2_ARCHIVE},target=/packages/${BZIP2_ARCHIVE} \
--mount=type=bind,source=packages/bzip2-${BZIP2_VERSION}-install_docs-1.patch,target=/packages/bzip2-${BZIP2_VERSION}-install_docs-1.patch \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BZIP2_ARCHIVE}
patch -Np1 -i /packages/bzip2-${BZIP2_VERSION}-install_docs-1.patch
sed -i 's@\(ln -s -f \)$(PREFIX)/bin/@\1@' Makefile
sed -i "s@(PREFIX)/man@(PREFIX)/share/man@g" Makefile
make -f Makefile-libbz2_so
make clean
make
make PREFIX=/usr install
cp -av libbz2.so.* /usr/lib
ln -sfv libbz2.so.${BZIP2_VERSION} /usr/lib/libbz2.so
ln -sfv libbz2.so.${BZIP2_VERSION} /usr/lib/libbz2.so.1
cp -v bzip2-shared /usr/bin/bzip2
for i in /usr/bin/{bzcat,bunzip2}
do
    ln -sfv bzip2 $i
done
rm -fv /usr/lib/libbz2.a
EOF

ARG XZ_VERSION
ARG XZ_ARCHIVE=xz-${XZ_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${XZ_ARCHIVE},target=/packages/${XZ_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${XZ_ARCHIVE}
./configure --prefix=/usr   \
    --disable-static            \
    --docdir=/usr/share/doc/xz-${XZ_VERSION}
make
make check
make install
EOF

ARG LZ4_VERSION
ARG LZ4_ARCHIVE=lz4-${LZ4_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${LZ4_ARCHIVE},target=/packages/${LZ4_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LZ4_ARCHIVE}
make BUILD_STATIC=no PREFIX=/usr
make -j1 check
make BUILD_STATIC=no PREFIX=/usr install
EOF

ARG ZSTD_VERSION
ARG ZSTD_ARCHIVE=zstd-${ZSTD_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${ZSTD_ARCHIVE},target=/packages/${ZSTD_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${ZSTD_ARCHIVE}
make prefix=/usr
make check
make prefix=/usr install
rm -v /usr/lib/libzstd.a
EOF

ARG FILE_VERSION
ARG FILE_ARCHIVE=file-${FILE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${FILE_ARCHIVE},target=/packages/${FILE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${FILE_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG READLINE_VERSION
ARG READLINE_ARCHIVE=readline-${READLINE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${READLINE_ARCHIVE},target=/packages/${READLINE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${READLINE_ARCHIVE}
sed -i '/MV.*old/d' Makefile.in
sed -i '/{OLDSUFF}/c:' support/shlib-install
sed -i 's/-Wl,-rpath,[^ ]*//' support/shobj-conf
sed -e '270a\
     else\
       chars_avail = 1;'      \
    -e '288i\   result = -1;' \
    -i.orig input.c
./configure --prefix=/usr   \
    --disable-static            \
    --with-curses               \
    --docdir=/usr/share/doc/readline-${READLINE_VERSION}
make SHLIB_LIBS="-lncursesw"
make install
install -v -m644 doc/*.{ps,pdf,html,dvi} /usr/share/doc/readline-${READLINE_VERSION}
EOF

ARG PCRE2_VERSION
ARG PCRE2_ARCHIVE=pcre2-${PCRE2_VERSION}.tar.bz2
RUN --mount=type=bind,source=packages/${PCRE2_ARCHIVE},target=/packages/${PCRE2_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PCRE2_ARCHIVE}
./configure --prefix=/usr                       \
    --docdir=/usr/share/doc/pcre2-${PCRE2_VERSION}  \
    --enable-unicode                                \
    --enable-jit                                    \
    --enable-pcre2-16                               \
    --enable-pcre2-32                               \
    --enable-pcre2grep-libz                         \
    --enable-pcre2grep-libbz2                       \
    --enable-pcre2test-libreadline                  \
    --disable-static
make
make check
make install
EOF

ARG M4_VERSION
ARG M4_ARCHIVE=m4-${M4_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${M4_ARCHIVE},target=/packages/${M4_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${M4_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG BC_VERSION
ARG BC_ARCHIVE=bc-${BC_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BC_ARCHIVE},target=/packages/${BC_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BC_ARCHIVE}
CC='gcc -std=c99' ./configure --prefix=/usr -G -O3 -r
make
make test
make install
EOF

ARG FLEX_VERSION
ARG FLEX_ARCHIVE=flex-${FLEX_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${FLEX_ARCHIVE},target=/packages/${FLEX_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${FLEX_ARCHIVE}
./configure --prefix=/usr       \
    --disable-static                \
    --docdir=/usr/share/doc/flex-${FLEX_VERSION}
make
make check
make install
ln -sv flex   /usr/bin/lex
ln -sv flex.1 /usr/share/man/man1/lex.1
EOF

ARG TCL_VERSION
ARG TCL_ARCHIVE=tcl${TCL_VERSION}-src.tar.gz
ARG TCL_HTML_ARCHIVE=tcl${TCL_VERSION}-html.tar.gz
RUN --mount=type=bind,source=packages/${TCL_ARCHIVE},target=/packages/${TCL_ARCHIVE} \
--mount=type=bind,source=packages/${TCL_HTML_ARCHIVE},target=/packages/${TCL_HTML_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${TCL_ARCHIVE}
SRCDIR=/work/tcl${TCL_VERSION}
cd unix
./configure --prefix=/usr   \
    --mandir=/usr/share/man     \
    --disable-rpath
make
sed -e "s|$SRCDIR/unix|/usr/lib|"   \
    -e "s|$SRCDIR|/usr/include|"        \
    -i tclConfig.sh
sed -e "s|$SRCDIR/unix/pkgs/tdbc1.1.13|/usr/lib/tdbc1.1.13|"    \
    -e "s|$SRCDIR/pkgs/tdbc1.1.13/generic|/usr/include|"            \
    -e "s|$SRCDIR/pkgs/tdbc1.1.13/library|/usr/lib/tcl8.6|"         \
    -e "s|$SRCDIR/pkgs/tdbc1.1.13|/usr/include|"                    \
    -i pkgs/tdbc1.1.13/tdbcConfig.sh
sed -e "s|$SRCDIR/unix/pkgs/itcl4.3.7|/usr/lib/itcl4.3.7|"      \
    -e "s|$SRCDIR/pkgs/itcl4.3.7/generic|/usr/include|"             \
    -e "s|$SRCDIR/pkgs/itcl4.3.7|/usr/include|"                     \
    -i pkgs/itcl4.3.7/itclConfig.sh
unset SRCDIR
LC_ALL=C.UTF-8 make test
make install
chmod 644 /usr/lib/libtclstub8.6.a
chmod -v u+w /usr/lib/libtcl8.6.so
make install-private-headers
ln -sfv tclsh8.6 /usr/bin/tclsh
mv -v /usr/share/man/man3/{Thread,Tcl_Thread}.3
cd ..
tar -xf /packages/${TCL_HTML_ARCHIVE} --strip-components=1
mkdir -v -p /usr/share/doc/tcl-${TCL_VERSION}
cp -v -r  ./html/* /usr/share/doc/tcl-${TCL_VERSION}
EOF

ARG EXPECT_VERSION
ARG EXPECT_ARCHIVE=expect${EXPECT_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${EXPECT_ARCHIVE},target=/packages/${EXPECT_ARCHIVE} \
--mount=type=bind,source=packages/expect-${EXPECT_VERSION}-gcc15-1.patch,target=/packages/expect-${EXPECT_VERSION}-gcc15-1.patch \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${EXPECT_ARCHIVE}
patch -Np1 -i /packages/expect-${EXPECT_VERSION}-gcc15-1.patch
./configure --prefix=/usr   \
    --with-tcl=/usr/lib         \
    --enable-shared             \
    --disable-rpath             \
    --mandir=/usr/share/man     \
    --with-tclinclude=/usr/include
make
make test
make install
ln -svf expect${EXPECT_VERSION}/libexpect${EXPECT_VERSION}.so /usr/lib
EOF

ARG DEJAGNU_VERSION
ARG DEJAGNU_ARCHIVE=dejagnu-${DEJAGNU_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${DEJAGNU_ARCHIVE},target=/packages/${DEJAGNU_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${DEJAGNU_ARCHIVE}
mkdir -pv build
cd build
../configure --prefix=/usr
makeinfo --html --no-split -o doc/dejagnu.html ../doc/dejagnu.texi
makeinfo --plaintext       -o doc/dejagnu.txt  ../doc/dejagnu.texi
make check
make install
install -v -dm755  /usr/share/doc/dejagnu-${DEJAGNU_VERSION}
install -v -m644   doc/dejagnu.{html,txt} /usr/share/doc/dejagnu-${DEJAGNU_VERSION}
EOF

ARG NINJA_VERSION
ARG NINJA_ARCHIVE=ninja-${NINJA_VERSION}.tar.gz
ENV NINJAJOBS=7
RUN --mount=type=bind,source=packages/${NINJA_ARCHIVE},target=/packages/${NINJA_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${NINJA_ARCHIVE}
sed -i '/int Guess/a \
    int   j = 0;\
    char* jobs = getenv( "NINJAJOBS" );\
    if ( jobs != NULL ) j = atoi( jobs );\
    if ( j > 0 ) return j;\
' src/ninja.cc
python3 configure.py --bootstrap --verbose
install -vm755 ninja /usr/bin/
install -vDm644 misc/bash-completion /usr/share/bash-completion/completions/ninja
install -vDm644 misc/zsh-completion  /usr/share/zsh/site-functions/_ninja
EOF

ARG PKGCONF_VERSION
ARG PKGCONF_ARCHIVE=pkgconf-${PKGCONF_VERSION}.tar.xz
ARG MESON_VERSION
ARG MESON_ARCHIVE=meson-${MESON_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${PKGCONF_ARCHIVE},target=/packages/${PKGCONF_ARCHIVE} \
--mount=type=bind,source=packages/${MESON_ARCHIVE},target=/packages/${MESON_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PKGCONF_ARCHIVE}
tar -xf /packages/${MESON_ARCHIVE}
mkdir -pv build
cd build
python3 ../meson-${MESON_VERSION}/meson.py setup --prefix=/usr --buildtype=release ..
ninja
ninja test
ninja install
mv /usr/share/doc/pkgconf{,${PKGCONF_VERSION}}
ln -sv pkgconf   /usr/bin/pkg-config
ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
EOF

ARG BINUTILS_VERSION
ARG BINUTILS_ARCHIVE=binutils-${BINUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BINUTILS_ARCHIVE},target=/packages/${BINUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BINUTILS_ARCHIVE}
mkdir -v build
cd       build
../configure --prefix=/usr       \
             --sysconfdir=/etc   \
             --enable-ld=default \
             --enable-plugins    \
             --enable-shared     \
             --disable-werror    \
             --enable-64-bit-bfd \
             --enable-new-dtags  \
             --with-system-zlib  \
             --with-lib-path=/usr/lib \
             --enable-default-hash-style=gnu
make tooldir=/usr
make -k check && true
test $(grep '^FAIL:' $(find -name '*.log') | wc -l) -le 1
make tooldir=/usr install
EOF

ARG GMP_VERSION
ARG GMP_ARCHIVE=gmp-${GMP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GMP_ARCHIVE},target=/packages/${GMP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GMP_ARCHIVE}
sed -i '/long long t1;/,+1s/()/(...)/' configure
./configure --prefix=/usr    \
            --enable-cxx     \
            --disable-static \
            --docdir=/usr/share/doc/gmp-${GMP_VERSION}
make
make html
make check
test $(cat $(find -name '*.log') | grep -c ^PASS) -ge 199
make install
make install-html
EOF

ARG MPFR_VERSION
ARG MPFR_ARCHIVE=mpfr-${MPFR_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${MPFR_ARCHIVE},target=/packages/${MPFR_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MPFR_ARCHIVE}
./configure --prefix=/usr        \
            --disable-static     \
            --enable-thread-safe \
            --docdir=/usr/share/doc/mpfr-${MPFR_VERSION}
make
make html
make check
make install
make install-html
EOF

ARG MPC_VERSION
ARG MPC_ARCHIVE=mpc-${MPC_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${MPC_ARCHIVE},target=/packages/${MPC_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MPC_ARCHIVE}
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/mpc-${MPC_VERSION}
make
make html
make check
make install
make install-html
EOF

ARG ATTR_VERSION
ARG ATTR_ARCHIVE=attr-${ATTR_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${ATTR_ARCHIVE},target=/packages/${ATTR_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${ATTR_ARCHIVE}
./configure --prefix=/usr       \
            --disable-static    \
            --sysconfdir=/etc   \
            --docdir=/usr/share/doc/attr-${ATTR_VERSION}
make
# make check # docker doesn't support attr
make install
EOF

ARG ACL_VERSION
ARG ACL_ARCHIVE=acl-${ACL_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${ACL_ARCHIVE},target=/packages/${ACL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${ACL_ARCHIVE}
./configure --prefix=/usr       \
            --disable-static    \
            --docdir=/usr/share/doc/acl-${ACL_VERSION}
make
# make check # docker doesn't support ACL
make install
EOF

ARG LIBCAP_VERSION
ARG LIBCAP_ARCHIVE=libcap-${LIBCAP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${LIBCAP_ARCHIVE},target=/packages/${LIBCAP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LIBCAP_ARCHIVE}
sed -i '/install -m.*STA/d' libcap/Makefile
make prefix=/usr lib=lib
make test
make prefix=/usr lib=lib install
EOF

ARG LIBXCRYPT_VERSION
ARG LIBXCRYPT_ARCHIVE=libxcrypt-${LIBXCRYPT_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${LIBXCRYPT_ARCHIVE},target=/packages/${LIBXCRYPT_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LIBXCRYPT_ARCHIVE}
sed -i '/strchr/s/const//' lib/crypt-{sm3,gost}-yescrypt.c
./configure --prefix=/usr                \
            --enable-hashes=strong,glibc \
            --enable-obsolete-api=no     \
            --disable-static             \
            --disable-failure-tokens
make
make check
make install
EOF

ARG SHADOW_VERSION
ARG SHADOW_ARCHIVE=shadow-${SHADOW_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${SHADOW_ARCHIVE},target=/packages/${SHADOW_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${SHADOW_ARCHIVE}
find man -name Makefile.in -exec sed -i 's/getspnam\.3 / /' {} \;
find man -name Makefile.in -exec sed -i 's/passwd\.5 / /'   {} \;
sed -e 's:#ENCRYPT_METHOD SHA512:ENCRYPT_METHOD YESCRYPT:' \
    -e 's:/var/spool/mail:/var/mail:'                      \
    -e '/PATH=/{s@/sbin:@@;s@/bin:@@}'                     \
    -i etc/login.defs
touch /usr/bin/passwd
./configure --sysconfdir=/etc   \
            --disable-static    \
            --with-{b,yes}crypt \
            --without-libbsd    \
            --disable-logind    \
            --with-group-name-max-length=32
make
make exec_prefix=/usr install
make -C man install-man
pwconv
grpconv
mkdir -p /etc/default
useradd -D --gid 999
sed -i '/MAIL/s/yes/no/' /etc/default/useradd
touch /etc/sub{u,g}id
echo root:root | chpasswd # TODO: change after first login
EOF

ARG GAWK_VERSION
ARG GAWK_ARCHIVE=gawk-${GAWK_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GAWK_ARCHIVE},target=/packages/${GAWK_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GAWK_ARCHIVE}
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr
make
# chown -R tester .
# su tester -c "PATH=$PATH make check" # broken in docker
rm -f /usr/bin/gawk-${GAWK_VERSION}
make install
ln -sv gawk.1 /usr/share/man/man1/awk.1
install -vDm644 doc/{awkforai.txt,*.{eps,pdf,jpg}} -t /usr/share/doc/gawk-${GAWK_VERSION}
EOF

ARG GCC_VERSION
ARG GCC_ARCHIVE=gcc-${GCC_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GCC_ARCHIVE},target=/packages/${GCC_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GCC_ARCHIVE}
sed -e '/m64=/s/lib64/lib/' -i.orig gcc/config/i386/t-linux64
mkdir -v build
cd       build
../configure --prefix=/usr            \
             LD=ld                    \
             --enable-languages=c,c++ \
             --enable-default-pie     \
             --enable-default-ssp     \
             --enable-host-pie        \
             --enable-targets=all     \
             --disable-multilib       \
             --disable-bootstrap      \
             --disable-fixincludes    \
             --with-system-zlib
make
# ulimit -s -H unlimited
# chown -R tester .
# su tester -c "PATH=$PATH make -k check" # too slow
# ../contrib/test_summary -t
make install
chown -v -R root:root $(gcc -print-file-name=include){,-fixed}
ln -svr /usr/bin/cpp /usr/lib
ln -sv gcc.1 /usr/share/man/man1/cc.1
ln -sfvr $(gcc -print-prog-name=liblto_plugin.so) /usr/lib/bfd-plugins/
echo 'int main(){}' | cc -x c - -v -Wl,--verbose &> dummy.log
readelf -l a.out | grep ': /lib'
rm -v a.out dummy.log
mkdir -pv /usr/share/gdb/auto-load/usr/lib
mv -v /usr/lib/*gdb.py /usr/share/gdb/auto-load/usr/lib
EOF

ARG NCURSES_VERSION
ARG NCURSES_ARCHIVE=ncurses-${NCURSES_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${NCURSES_ARCHIVE},target=/packages/${NCURSES_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${NCURSES_ARCHIVE}
./configure --prefix=/usr           \
            --mandir=/usr/share/man \
            --with-shared           \
            --without-debug         \
            --without-normal        \
            --with-cxx-shared       \
            --enable-pc-files       \
            --with-pkg-config-libdir=/usr/lib/pkgconfig
make
make DESTDIR=$PWD/dest install
sed -e 's/^#if.*XOPEN.*$/#if 1/' -i dest/usr/include/curses.h
cp --remove-destination -av dest/* /
for lib in ncurses form panel menu ; do
    ln -sfv lib${lib}w.so /usr/lib/lib${lib}.so
    ln -sfv ${lib}w.pc    /usr/lib/pkgconfig/${lib}.pc
done
ln -sfv libncursesw.so /usr/lib/libcurses.so
cp -v -R doc -T /usr/share/doc/ncurses-${NCURSES_VERSION}
make distclean
./configure --prefix=/usr    \
            --with-shared    \
            --without-normal \
            --without-debug  \
            --without-cxx-binding \
            --with-abi-version=5
make sources libs
cp -av lib/lib*.so.5* /usr/lib
EOF

ARG SED_VERSION
ARG SED_ARCHIVE=sed-${SED_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${SED_ARCHIVE},target=/packages/${SED_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${SED_ARCHIVE}
./configure --prefix=/usr
make
make html
chown -R tester .
su tester -c "PATH=$PATH make check"
make install
install -vDm644 doc/sed.html -t /usr/share/doc/sed-${SED_VERSION}
EOF

ARG PSMISC_VERSION
ARG PSMISC_ARCHIVE=psmisc-${PSMISC_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${PSMISC_ARCHIVE},target=/packages/${PSMISC_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PSMISC_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG GETTEXT_VERSION
ARG GETTEXT_ARCHIVE=gettext-${GETTEXT_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GETTEXT_ARCHIVE},target=/packages/${GETTEXT_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GETTEXT_ARCHIVE}
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/gettext-${GETTEXT_VERSION}
make
make check
make install
chmod -v 0755 /usr/lib/preloadable_libintl.so
EOF

ARG BISON_VERSION
ARG BISON_ARCHIVE=bison-${BISON_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BISON_ARCHIVE},target=/packages/${BISON_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BISON_ARCHIVE}
./configure --prefix=/usr --docdir=/usr/share/doc/bison-${BISON_VERSION}
make
make check
make install
EOF

ARG GREP_VERSION
ARG GREP_ARCHIVE=grep-${GREP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GREP_ARCHIVE},target=/packages/${GREP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GREP_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG BASH_VERSION_
ARG BASH_ARCHIVE=bash-${BASH_VERSION_}.tar.gz
RUN --mount=type=bind,source=packages/${BASH_ARCHIVE},target=/packages/${BASH_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BASH_ARCHIVE}
./configure --prefix=/usr             \
            --without-bash-malloc     \
            --with-installed-readline \
            --docdir=/usr/share/doc/bash-${BASH_VERSION_}
make
chown -R tester .
LC_ALL=C.UTF-8 su -s /usr/bin/expect tester << "EOT"
set timeout -1
spawn make tests
expect eof
lassign [wait] _ _ _ value
exit $value
EOT
make install
EOF

ARG LIBTOOL_VERSION
ARG LIBTOOL_ARCHIVE=libtool-${LIBTOOL_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${LIBTOOL_ARCHIVE},target=/packages/${LIBTOOL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LIBTOOL_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
rm -fv /usr/lib/libltdl.a
EOF

ARG GDBM_VERSION
ARG GDBM_ARCHIVE=gdbm-${GDBM_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${GDBM_ARCHIVE},target=/packages/${GDBM_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GDBM_ARCHIVE}
./configure --prefix=/usr    \
            --disable-static \
            --enable-libgdbm-compat
make
make check
make install
EOF

ARG GPERF_VERSION
ARG GPERF_ARCHIVE=gperf-${GPERF_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${GPERF_ARCHIVE},target=/packages/${GPERF_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GPERF_ARCHIVE}
./configure --prefix=/usr --docdir=/usr/share/doc/gperf-${GPERF_VERSION}
make
make check
make install
EOF

ARG EXPAT_VERSION
ARG EXPAT_ARCHIVE=expat-${EXPAT_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${EXPAT_ARCHIVE},target=/packages/${EXPAT_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${EXPAT_ARCHIVE}
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/expat-${EXPAT_VERSION}
make
make check
make install
install -v -m644 doc/*.{html,css} /usr/share/doc/expat-2.8.3
EOF

ARG INET_UTILS_VERSION
ARG INET_UTILS_ARCHIVE=inetutils-${INET_UTILS_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${INET_UTILS_ARCHIVE},target=/packages/${INET_UTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${INET_UTILS_ARCHIVE}
sed -i 's/def HAVE_TERMCAP_TGETENT/ 1/' telnet/telnet.c
./configure --prefix=/usr        \
            --bindir=/usr/bin    \
            --localstatedir=/var \
            --disable-logger     \
            --disable-whois      \
            --disable-rcp        \
            --disable-rexec      \
            --disable-rlogin     \
            --disable-rsh        \
            --disable-servers
make
# make check # hostname.sh fails under docker
make install
mv -v /usr/{,s}bin/ifconfig
EOF

ARG LESS_VERSION
ARG LESS_ARCHIVE=less-${LESS_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${LESS_ARCHIVE},target=/packages/${LESS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LESS_ARCHIVE}
./configure --prefix=/usr --sysconfdir=/etc
make
make install
EOF

ARG PERL_VERSION
ARG PERL_ARCHIVE=perl-${PERL_VERSION}.tar.xz
ARG PERL_MAJOR_MINOR_VERSION
RUN --mount=type=bind,source=packages/${PERL_ARCHIVE},target=/packages/${PERL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PERL_ARCHIVE}
export BUILD_ZLIB=False
export BUILD_BZIP2=0
sh Configure -des                                          \
             -D prefix=/usr                                \
             -D vendorprefix=/usr                          \
             -D privlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/core_perl      \
             -D archlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/core_perl      \
             -D sitelib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/site_perl      \
             -D sitearch=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/site_perl     \
             -D vendorlib=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/vendor_perl  \
             -D vendorarch=/usr/lib/perl5/${PERL_MAJOR_MINOR_VERSION}/vendor_perl \
             -D man1dir=/usr/share/man/man1                \
             -D man3dir=/usr/share/man/man3                \
             -D pager="/usr/bin/less -isR"                 \
             -D useshrplib                                 \
             -D usethreads
make
TEST_JOBS=7 make test_harness
make install
EOF

ARG AUTOCONF_VERSION
ARG AUTOCONF_ARCHIVE=autoconf-${AUTOCONF_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${AUTOCONF_ARCHIVE},target=/packages/${AUTOCONF_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${AUTOCONF_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG AUTOMAKE_VERSION
ARG AUTOMAKE_ARCHIVE=automake-${AUTOMAKE_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${AUTOMAKE_ARCHIVE},target=/packages/${AUTOMAKE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${AUTOMAKE_ARCHIVE}
./configure --prefix=/usr --docdir=/usr/share/doc/automake-${AUTOMAKE_VERSION}
make
make check
make install
EOF

ARG OPENSSL_VERSION
ARG OPENSSL_ARCHIVE=openssl-${OPENSSL_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${OPENSSL_ARCHIVE},target=/packages/${OPENSSL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${OPENSSL_ARCHIVE}
./config --prefix=/usr         \
         --openssldir=/etc/ssl \
         --libdir=lib          \
         shared                \
         zlib-dynamic
make
make test
make INSTALL_LIBS= MANSUFFIX=ssl install
mv -v /usr/share/doc/openssl /usr/share/doc/openssl-${OPENSSL_VERSION}
cp -vfr doc/* /usr/share/doc/openssl-${OPENSSL_VERSION}
EOF

ARG ELFUTILS_VERSION
ARG ELFUTILS_ARCHIVE=elfutils-${ELFUTILS_VERSION}.tar.bz2
RUN --mount=type=bind,source=packages/${ELFUTILS_ARCHIVE},target=/packages/${ELFUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${ELFUTILS_ARCHIVE}
./configure --prefix=/usr        \
            --disable-debuginfod \
            --enable-libdebuginfod=dummy
make -C lib
make -C libelf
make -k check
make -C libelf install
install -vm644 config/libelf.pc /usr/lib/pkgconfig
rm /usr/lib/libelf.a
EOF

ARG LIBFFI_VERSION
ARG LIBFFI_ARCHIVE=libffi-${LIBFFI_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${LIBFFI_ARCHIVE},target=/packages/${LIBFFI_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LIBFFI_ARCHIVE}
./configure --prefix=/usr    \
            --disable-static \
            --with-gcc-arch=native
make
make check
make install
EOF

ARG SQLITE_VERSION
ARG SQLITE_ARCHIVE=sqlite-autoconf-${SQLITE_VERSION}.tar.gz
ARG SQLITE_DOC_ARCHIVE=sqlite-doc-${SQLITE_VERSION}.zip
ARG SQLITE_MMM_VERSION
RUN --mount=type=bind,source=packages/${SQLITE_ARCHIVE},target=/packages/${SQLITE_ARCHIVE} \
--mount=type=bind,source=packages/${SQLITE_DOC_ARCHIVE},target=/packages/${SQLITE_DOC_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${SQLITE_ARCHIVE}
python3 -m zipfile -e /packages/${SQLITE_DOC_ARCHIVE} .
./configure --prefix=/usr     \
            --disable-static  \
            --enable-fts{4,5} \
            CPPFLAGS="-D SQLITE_ENABLE_COLUMN_METADATA=1 \
                      -D SQLITE_ENABLE_UNLOCK_NOTIFY=1   \
                      -D SQLITE_ENABLE_DBSTAT_VTAB=1     \
                      -D SQLITE_SECURE_DELETE=1"
make LDFLAGS.rpath=""
make install
cp -v -R sqlite-doc-${SQLITE_VERSION} -T /usr/share/doc/sqlite-${SQLITE_MMM_VERSION}
EOF

ARG MPDECIMAL_VERSION
ARG MPDECIMAL_ARCHIVE=mpdecimal-${MPDECIMAL_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${MPDECIMAL_ARCHIVE},target=/packages/${MPDECIMAL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MPDECIMAL_ARCHIVE}
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/mpdecimal-${MPDECIMAL_VERSION}
make
make check_local
make install
EOF

ARG PYTHON_VERSION
ARG PYTHON_ARCHIVE=Python-${PYTHON_VERSION}.tar.xz
ARG PYTHON_DOCS_ARCHIVE=python-${PYTHON_VERSION}-docs-html.tar.bz2
RUN --mount=type=bind,source=packages/${PYTHON_ARCHIVE},target=/packages/${PYTHON_ARCHIVE} \
--mount=type=bind,source=packages/${PYTHON_DOCS_ARCHIVE},target=/packages/${PYTHON_DOCS_ARCHIVE} \
--mount=type=bind,source=packages/Python-3.14.7-openssl_4-1.patch,target=/packages/Python-3.14.7-openssl_4-1.patch \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PYTHON_ARCHIVE}
patch -Np1 -i /packages/Python-3.14.7-openssl_4-1.patch
./configure --prefix=/usr          \
            --enable-shared        \
            --with-system-expat    \
            --enable-optimizations \
            --without-static-libpython
make
make test TESTOPTS="--timeout 120"
make install
cat > /etc/pip.conf << EOP
[global]
root-user-action = ignore
disable-pip-version-check = true
EOP

install -v -dm755 /usr/share/doc/python-${PYTHON_VERSION}/html

tar --strip-components=1  \
    --no-same-owner       \
    --no-same-permissions \
    -C /usr/share/doc/python-${PYTHON_VERSION}/html \
    -xvf /packages/${PYTHON_DOCS_ARCHIVE}
EOF

ARG FLIT_CORE_VERSION
ARG FLIT_CORE_ARCHIVE=flit_core-${FLIT_CORE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${FLIT_CORE_ARCHIVE},target=/packages/${FLIT_CORE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${FLIT_CORE_ARCHIVE}
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist flit_core
EOF

ARG PACKAGING_VERSION
ARG PACKAGING_ARCHIVE=packaging-${PACKAGING_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${PACKAGING_ARCHIVE},target=/packages/${PACKAGING_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PACKAGING_ARCHIVE}
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist packaging
EOF

ARG WHEEL_VERSION
ARG WHEEL_ARCHIVE=wheel-${WHEEL_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${WHEEL_ARCHIVE},target=/packages/${WHEEL_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${WHEEL_ARCHIVE}
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist wheel
EOF

ARG SETUPTOOLS_VERSION
ARG SETUPTOOLS_ARCHIVE=setuptools-${SETUPTOOLS_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${SETUPTOOLS_ARCHIVE},target=/packages/${SETUPTOOLS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${SETUPTOOLS_ARCHIVE}
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist setuptools
EOF

ARG MESON_VERSION
ARG MESON_ARCHIVE=meson-${MESON_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${MESON_ARCHIVE},target=/packages/${MESON_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MESON_ARCHIVE}
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist meson
install -vDm644 data/shell-completions/bash/meson /usr/share/bash-completion/completions/meson
install -vDm644 data/shell-completions/zsh/_meson /usr/share/zsh/site-functions/_meson
EOF

ARG KMOD_VERSION
ARG KMOD_ARCHIVE=kmod-${KMOD_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${KMOD_ARCHIVE},target=/packages/${KMOD_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${KMOD_ARCHIVE}
mkdir -p build
cd       build

meson setup --prefix=/usr ..    \
            --buildtype=release \
            -D manpages=false
ninja
ninja install
EOF

ARG COREUTILS_VERSION
ARG COREUTILS_ARCHIVE=coreutils-${COREUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${COREUTILS_ARCHIVE},target=/packages/${COREUTILS_ARCHIVE} \
--mount=type=bind,source=packages/coreutils-9.11-i18n-1.patch,target=/packages/coreutils-9.11-i18n-1.patch \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${COREUTILS_ARCHIVE}
patch -Np1 -i /packages/coreutils-9.11-i18n-1.patch
autoreconf -fv
automake -af
FORCE_UNSAFE_CONFIGURE=1 ./configure \
            --prefix=/usr
make NON_ROOT_USERNAME=tester check-root
# groupadd -g 102 dummy -U tester # tests all pass but still exits 2 in docker
# chown -R tester .
# su tester -c "PATH=$PATH make -k RUN_EXPENSIVE_TESTS=yes check" \
#    < /dev/null
# groupdel dummy
make install
mv -v /usr/bin/chroot /usr/sbin
mv -v /usr/share/man/man1/chroot.1 /usr/share/man/man8/chroot.8
sed -i 's/"1"/"8"/' /usr/share/man/man8/chroot.8
EOF

ARG DIFFUTILS_VERSION
ARG DIFFUTILS_ARCHIVE=diffutils-${DIFFUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${DIFFUTILS_ARCHIVE},target=/packages/${DIFFUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${DIFFUTILS_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG FINDUTILS_VERSION
ARG FINDUTILS_ARCHIVE=findutils-${FINDUTILS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${FINDUTILS_ARCHIVE},target=/packages/${FINDUTILS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${FINDUTILS_ARCHIVE}
./configure --prefix=/usr --localstatedir=/var/lib/locate
make
# exits 1 under docker
# chown -R tester .
# su tester -c "PATH=$PATH make check -k"
make install
EOF

ARG GROFF_VERSION
ARG GROFF_ARCHIVE=groff-${GROFF_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${GROFF_ARCHIVE},target=/packages/${GROFF_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GROFF_ARCHIVE}
PAGE=letter ./configure --prefix=/usr
make -j1
# make check # one expected failure, but still exits 1 under docker.  TODO
make install
EOF

ARG GRUB_VERSION
ARG GRUB_ARCHIVE=grub-${GRUB_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GRUB_ARCHIVE},target=/packages/${GRUB_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GRUB_ARCHIVE}
sed 's/--image-base/--nonexist-linker-option/' -i configure
./configure --prefix=/usr     \
            --sysconfdir=/etc \
            --disable-efiemu  \
            --disable-werror
make
make install
make clean
./configure --prefix=/usr       \
            --sysconfdir=/etc   \
            --target=x86_64     \
            --with-platform=efi \
            --disable-efiemu    \
            --disable-werror
make
make install
EOF

ARG GZIP_VERSION
ARG GZIP_ARCHIVE=gzip-${GZIP_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${GZIP_ARCHIVE},target=/packages/${GZIP_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${GZIP_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG IPROUTE2_VERSION
ARG IPROUTE2_ARCHIVE=iproute2-${IPROUTE2_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${IPROUTE2_ARCHIVE},target=/packages/${IPROUTE2_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${IPROUTE2_ARCHIVE}
sed -i /ARPD/d Makefile
rm -fv man/man8/arpd.8
make NETNS_RUN_DIR=/run/netns
make SBINDIR=/usr/sbin install
install -vDm644 COPYING README* -t /usr/share/doc/iproute2-${IPROUTE2_VERSION}
EOF

ARG LIBPIPELINE_VERSION
ARG LIBPIPELINE_ARCHIVE=libpipeline-${LIBPIPELINE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${LIBPIPELINE_ARCHIVE},target=/packages/${LIBPIPELINE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LIBPIPELINE_ARCHIVE}
./configure --prefix=/usr
make
make install
EOF

ARG MAKE_VERSION
ARG MAKE_ARCHIVE=make-${MAKE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${MAKE_ARCHIVE},target=/packages/${MAKE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MAKE_ARCHIVE}
./configure --prefix=/usr
make
chown -R tester .
su tester -c "PATH=$PATH make check"
make install
EOF

ARG PATCH_VERSION
ARG PATCH_ARCHIVE=patch-${PATCH_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${PATCH_ARCHIVE},target=/packages/${PATCH_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PATCH_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
EOF

ARG TAR_VERSION
ARG TAR_ARCHIVE=tar-${TAR_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${TAR_ARCHIVE},target=/packages/${TAR_ARCHIVE} \
--mount=type=bind,source=packages/tar-1.35-acl_fix-1.patch,target=/packages/tar-1.35-acl_fix-1.patch \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${TAR_ARCHIVE}
patch -Np1 -i /packages/tar-1.35-acl_fix-1.patch
FORCE_UNSAFE_CONFIGURE=1 ./configure --prefix=/usr
make
# make check # 2 failures on Docker
make install
make -C doc install-html docdir=/usr/share/doc/tar-${TAR_VERSION}
EOF

ARG TEXINFO_VERSION
ARG TEXINFO_ARCHIVE=texinfo-${TEXINFO_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${TEXINFO_ARCHIVE},target=/packages/${TEXINFO_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${TEXINFO_ARCHIVE}
./configure --prefix=/usr
make
make check
make install
make TEXMF=/usr/share/texmf install-tex
EOF

ARG VIM_VERSION
ARG VIM_ARCHIVE=vim-${VIM_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${VIM_ARCHIVE},target=/packages/${VIM_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${VIM_ARCHIVE}
echo '#define SYS_VIMRC_FILE "/etc/vimrc"' >> src/feature.h
./configure --prefix=/usr
make
# chown -R tester . # fails in Docker
# sed '/test_plugin_glvs/d' -i src/testdir/Make_all.mak
# su tester -c "TERM=xterm-256color LANG=en_US.UTF-8 make -j1 test" &> vim-test.log
make install
ln -sv vim /usr/bin/vi
for L in  /usr/share/man/{,*/}man1/vim.1; do
    ln -sv vim.1 $(dirname $L)/vi.1
done
ln -sv ../vim/vim92/doc /usr/share/doc/vim-${VIM_VERSION}
EOF

ARG MARKUPSAFE_VERSION
ARG MARKUPSAFE_ARCHIVE=markupsafe-${MARKUPSAFE_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${MARKUPSAFE_ARCHIVE},target=/packages/${MARKUPSAFE_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MARKUPSAFE_ARCHIVE}
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist Markupsafe
EOF

ARG JINJA2_VERSION
ARG JINJA2_ARCHIVE=jinja2-${JINJA2_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${JINJA2_ARCHIVE},target=/packages/${JINJA2_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${JINJA2_ARCHIVE}
pip3 wheel -w dist --no-cache-dir --no-build-isolation --no-deps $PWD
pip3 install --no-index --find-links dist Jinja2
EOF

ARG SYSTEMD_VERSION
ARG SYSTEMD_ARCHIVE=systemd-${SYSTEMD_VERSION}.tar.gz
ARG SYSTEMD_MAN_PAGES_ARCHIVE=systemd-man-pages-${SYSTEMD_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${SYSTEMD_ARCHIVE},target=/packages/${SYSTEMD_ARCHIVE} \
--mount=type=bind,source=packages/${SYSTEMD_MAN_PAGES_ARCHIVE},target=/packages/${SYSTEMD_MAN_PAGES_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${SYSTEMD_ARCHIVE}
sed -e 's/GROUP="render"/GROUP="video"/' \
    -e 's/GROUP="sgx", //'               \
    -i rules.d/50-udev-default.rules.in

mkdir -p build
cd       build

meson setup ..                \
      --prefix=/usr           \
      --buildtype=release     \
      -D default-dnssec=no    \
      -D firstboot=false      \
      -D install-tests=false  \
      -D ldconfig=false       \
      -D sysusers=false       \
      -D rpmmacrosdir=no      \
      -D homed=disabled       \
      -D man=disabled         \
      -D mode=release         \
      -D pamconfdir=no        \
      -D dev-kvm-mode=0660    \
      -D nobody-group=nogroup \
      -D sysupdate=disabled   \
      -D ukify=disabled       \
      -D default-kill-user-processes=false \
      -D docdir=/usr/share/doc/systemd-${SYSTEMD_VERSION}

ninja
echo 'NAME="Linux From Scratch"' > /etc/os-release
# unshare -m ninja test
ninja install

tar -xf /packages/${SYSTEMD_MAN_PAGES_ARCHIVE} \
    --no-same-owner --strip-components=1     \
    -C /usr/share/man

systemd-machine-id-setup
systemctl preset-all
EOF

ARG DBUS_VERSION
ARG DBUS_ARCHIVE=dbus-${DBUS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${DBUS_ARCHIVE},target=/packages/${DBUS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${DBUS_ARCHIVE}
mkdir build
cd    build

meson setup --prefix=/usr --buildtype=release --wrap-mode=nofallback ..
ninja
ninja test
ninja install
EOF

ARG MAN_DB_VERSION
ARG MAN_DB_ARCHIVE=man-db-${MAN_DB_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${MAN_DB_ARCHIVE},target=/packages/${MAN_DB_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MAN_DB_ARCHIVE}
./configure --prefix=/usr                         \
            --docdir=/usr/share/doc/man-db-${MAN_DB_VERSION} \
            --sysconfdir=/etc                     \
            --disable-setuid                      \
            --enable-cache-owner=bin              \
            --with-browser=/usr/bin/lynx          \
            --with-vgrind=/usr/bin/vgrind         \
            --with-grap=/usr/bin/grap
make
make check
make install
EOF

ARG PROCPS_NG_VERSION
ARG PROCPS_NG_ARCHIVE=procps-ng-${PROCPS_NG_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${PROCPS_NG_ARCHIVE},target=/packages/${PROCPS_NG_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${PROCPS_NG_ARCHIVE}
./configure --prefix=/usr                           \
            --docdir=/usr/share/doc/procps-ng-${PROCPS_NG_VERSION} \
            --disable-static                        \
            --disable-kill                          \
            --enable-watch8bit                      \
            --with-systemd
make
chown -R tester .
su tester -c "PATH=$PATH make check"
make install
EOF

ARG UTIL_LINUX_VERSION
ARG UTIL_LINUX_ARCHIVE=util-linux-${UTIL_LINUX_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${UTIL_LINUX_ARCHIVE},target=/packages/${UTIL_LINUX_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${UTIL_LINUX_ARCHIVE}
./configure --bindir=/usr/bin     \
            --libdir=/usr/lib     \
            --runstatedir=/run    \
            --sbindir=/usr/sbin   \
            --disable-chfn-chsh   \
            --disable-login       \
            --disable-nologin     \
            --disable-su          \
            --disable-setpriv     \
            --disable-runuser     \
            --disable-pylibmount  \
            --disable-liblastlog2 \
            --disable-static      \
            --without-python      \
            ADJTIME_PATH=/var/lib/hwclock/adjtime \
            --docdir=/usr/share/doc/util-linux-${UTIL_LINUX_VERSION}
make
touch /etc/fstab
# chown -R tester . # fails in docker
# su tester -c "make -k check"
make install
EOF

ARG E2FSPROGS_VERSION
ARG E2FSPROGS_ARCHIVE=e2fsprogs-${E2FSPROGS_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${E2FSPROGS_ARCHIVE},target=/packages/${E2FSPROGS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${E2FSPROGS_ARCHIVE}
mkdir -v build
cd       build
../configure --prefix=/usr       \
             --sysconfdir=/etc   \
             --enable-elf-shlibs \
             --disable-libblkid  \
             --disable-libuuid   \
             --disable-uuidd     \
             --disable-fsck
make
make check
make install
rm -fv /usr/lib/{libcom_err,libe2p,libext2fs,libss}.a
EOF

# blfs

ARG LZO_VERSION
ARG LZO_ARCHIVE=lzo-${LZO_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${LZO_ARCHIVE},target=/packages/${LZO_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LZO_ARCHIVE}
./configure --prefix=/usr    \
            --enable-shared  \
            --disable-static \
            --docdir=/usr/share/doc/lzo-${LZO_VERSION}
make
make install
EOF

ARG BTRFS_PROGS_VERSION
ARG BTRFS_PROGS_ARCHIVE=btrfs-progs-v${BTRFS_PROGS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BTRFS_PROGS_ARCHIVE},target=/packages/${BTRFS_PROGS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BTRFS_PROGS_ARCHIVE}
./configure --prefix=/usr           \
            --disable-static        \
            --disable-documentation
make
make install
EOF

ARG OPENSSH_VERSION
ARG OPENSSH_ARCHIVE=openssh-${OPENSSH_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${OPENSSH_ARCHIVE},target=/packages/${OPENSSH_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${OPENSSH_ARCHIVE}
install -v -g sys -m700 -d /var/lib/sshd
groupadd -g 50 sshd
useradd  -c 'sshd PrivSep' \
         -d /var/lib/sshd  \
         -g sshd           \
         -s /bin/false     \
         -u 50 sshd
./configure --prefix=/usr                            \
            --sysconfdir=/etc/ssh                    \
            --with-privsep-path=/var/lib/sshd        \
            --with-default-path=/usr/bin             \
            --with-superuser-path=/usr/sbin:/usr/bin \
            --with-pid-dir=/run
make
make -j1 tests
make install
install -v -m755    contrib/ssh-copy-id /usr/bin
install -v -m644    contrib/ssh-copy-id.1 \
                    /usr/share/man/man1
install -v -m755 -d /usr/share/doc/openssh-${OPENSSH_VERSION}
install -v -m644    INSTALL LICENCE OVERVIEW README* \
                    /usr/share/doc/openssh-${OPENSSH_VERSION}
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
EOF

ARG LIBTASN1_VERSION
ARG LIBTASN1_ARCHIVE=libtasn1-${LIBTASN1_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${LIBTASN1_ARCHIVE},target=/packages/${LIBTASN1_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${LIBTASN1_ARCHIVE}
./configure --prefix=/usr --disable-static
make
make check
make install
EOF

ARG P11_KIT_VERSION
ARG P11_KIT_ARCHIVE=p11-kit-${P11_KIT_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${P11_KIT_ARCHIVE},target=/packages/${P11_KIT_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${P11_KIT_ARCHIVE}
sed '20,$ d' -i trust/trust-extract-compat

cat >> trust/trust-extract-compat << "EOT"
# Copy existing anchor modifications to /etc/ssl/local
/usr/libexec/make-ca/copy-trust-modifications

# Update trust stores
/usr/sbin/make-ca -r
EOT
mkdir p11-build
cd    p11-build

meson setup ..            \
      --prefix=/usr       \
      --buildtype=release \
      -D trust_paths=/etc/pki/anchors
ninja
ninja install
ln -sfv /usr/libexec/p11-kit/trust-extract-compat \
        /usr/bin/update-ca-certificates
ln -sfv ./pkcs11/p11-kit-trust.so /usr/lib/libnssckbi.so
EOF

ARG MAKE_CA_VERSION
ARG MAKE_CA_ARCHIVE=make-ca-${MAKE_CA_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${MAKE_CA_ARCHIVE},target=/packages/${MAKE_CA_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${MAKE_CA_ARCHIVE}
sed '/mktemp/s/-t //' -i make-ca
make install
install -vdm755 /etc/ssl/local
/usr/sbin/make-ca -g
# TODO cron
EOF

ARG WGET_VERSION
ARG WGET_ARCHIVE=wget-${WGET_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${WGET_ARCHIVE},target=/packages/${WGET_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${WGET_ARCHIVE}
NEW_LINE='#if !defined OPENSSL_NO_SSL3_METHOD '
NEW_LINE+='&& OPENSSL_VERSION_NUMBER < 0x40000000L'

sed -i "/SSL3/c $NEW_LINE" src/openssl.c

unset NEW_LINE

./configure --prefix=/usr      \
            --sysconfdir=/etc  \
            --with-ssl=openssl
make
make install
EOF

ARG BLFS_SYSTEMD_UNITS_VERSION
ARG BLFS_SYSTEMD_UNITS_ARCHIVE=blfs-systemd-units-${BLFS_SYSTEMD_UNITS_VERSION}.tar.xz
RUN --mount=type=bind,source=packages/${BLFS_SYSTEMD_UNITS_ARCHIVE},target=/packages/${BLFS_SYSTEMD_UNITS_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${BLFS_SYSTEMD_UNITS_ARCHIVE}
make install-sshd
EOF

# my stuff
ARG CTYPES_SH_VERSION
ARG CTYPES_SH_ARCHIVE=ctypes-sh-${CTYPES_SH_VERSION}.tar.gz
RUN --mount=type=bind,source=packages/${CTYPES_SH_ARCHIVE},target=/packages/${CTYPES_SH_ARCHIVE} \
--mount=type=bind,source=packages/prepare,target=/packages/prepare \
<<EOF
source /packages/prepare ${CTYPES_SH_ARCHIVE}
./configure --prefix=/usr
make
make install
EOF

# 8.85
RUN <<EOF
set -euo pipefail
# There are also several files in the /usr/lib and /usr/libexec directories with a file name extension of .la. These are "libtool archive" files. On a modern Linux system the libtool .la files are only useful for libltdl. No libraries in LFS are expected to be loaded by libltdl, and it's known that some .la files can break BLFS package builds. Remove those files now:
find /usr/lib /usr/libexec -name \*.la -delete
# For more information about libtool archive files, see the BLFS section "About Libtool Archive (.la) files".
# The compiler built in Chapter 6 and Chapter 7 is still partially installed and not needed anymore. Remove it with:
find /usr -depth -name $(uname -m)-lfs-linux-gnu\* | xargs rm -rf
# Finally, remove the temporary 'tester' user account created at the beginning of the previous chapter.
userdel -r tester
EOF

FROM ch8 AS ch9
RUN <<EOF
set -euo pipefail

echo "builder:x:1000:1000::/home/builder:/bin/bash" >> /etc/passwd
echo "builder:x:1000:" >> /etc/group
install -o builder -d /home/builder

echo mufasa > /etc/hostname
# TODO /etc/hosts after docker

cat > /etc/adjtime << "EOT"
0.0 0 0.0
0
LOCAL
EOT

echo FONT=Lat2-Terminus16 > /etc/vconsole.conf
echo LANG=en_US.UTF-8 > /etc/locale.conf
cat > /etc/profile << "EOP"
# Begin /etc/profile
for i in $(locale); do
  unset ${i%=*}
done

if [[ "$TERM" = linux ]]; then
  export LANG=C.UTF-8
else
  source /etc/locale.conf

  for i in $(locale); do
    key=${i%=*}
    if [[ -v $key ]]; then
      export $key
    fi
  done
fi
# End /etc/profile
EOP

cat > /etc/inputrc << "EOI"
# Begin /etc/inputrc
# Modified by Chris Lynn <roryo@roryo.dynup.net>

# Allow the command prompt to wrap to the next line
set horizontal-scroll-mode Off

# Enable 8-bit input
set meta-flag On
set input-meta On

# Turns off 8th bit stripping
set convert-meta Off

# Keep the 8th bit for display
set output-meta On

# none, visible or audible
set bell-style none

# All of the following map the escape sequence of the value
# contained in the 1st argument to the readline specific functions
"\eOd": backward-word
"\eOc": forward-word

# for linux console
"\e[1~": beginning-of-line
"\e[4~": end-of-line
"\e[5~": beginning-of-history
"\e[6~": end-of-history
"\e[3~": delete-char
"\e[2~": quoted-insert

# for xterm
"\eOH": beginning-of-line
"\eOF": end-of-line

# for Konsole
"\e[H": beginning-of-line
"\e[F": end-of-line

# uncomment for history search mode with up/down
# "\e[A": history-search-backward
# "\e[B": history-search-forward
# End /etc/inputrc
EOI

cat > /etc/shells << "EOS"
# Begin /etc/shells
/bin/sh
/bin/bash
# End /etc/shells
EOS

mkdir -pv /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/noclear.conf << EOT
[Service]
TTYVTDisallocate=no
EOT

mkdir -pv /etc/systemd/coredump.conf.d

cat > /etc/systemd/coredump.conf.d/maxuse.conf << EOC
[Coredump]
MaxUse=5G
EOC

cat > /etc/fstab << "EOD"
# <file system>                                         <mount point>   <type>      <options>               <dump>  <pass>
/dev/disk/by-uuid/103b03ca-d079-46fe-8bdc-eab2518e63c7  /               btrfs       defaults                1       1
EOD
EOF
# ARG LINUX_MAJOR
# ARG LINUX_VERSION
# ARG LINUX_ARCHIVE=linux-${LINUX_VERSION}.tar.xz
# RUN --mount=type=bind,source=packages/${LINUX_ARCHIVE},target=/packages/${LINUX_ARCHIVE} \
# --mount=type=bind,source=packages/prepare,target=/packages/prepare \
# --mount=type=bind,source=kconfig,target=/kconfig \
# <<EOF
# source /packages/prepare ${LINUX_ARCHIVE}
# set -x
# make mrproper
# cp /kconfig .config
# chmod 644 .config
# chown root:root .config
# make
# make modules_install
# cp -iv arch/x86/boot/bzImage /boot/vmlinuz-${LINUX_VERSION}-lfs-13.1-systemd
# cp -iv System.map /boot/System.map-${LINUX_VERSION}
# cp -iv .config /boot/config-${LINUX_VERSION}
# cp -r Documentation -T /usr/share/doc/linux-${LINUX_VERSION}
# find usr/include -type f ! -name '*.h' -delete
# cp -rv usr/include $LFS/usr
# EOF
