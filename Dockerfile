ARG ATTR_VERSION=2.6.0
ARG ACL_VERSION=2.4.0
# avoid conflict with builtin var BASH_VERSION
ARG BASH_VERSION_=5.3
ARG BC_VERSION=7.0.3
ARG BINUTILS_VERSION=2.47
ARG BISON_VERSION=3.8.2
ARG BZIP2_VERSION=1.0.8
ARG COREUTILS_VERSION=9.11
ARG DEJAGNU_VERSION=1.6.3
ARG DIFFUTILS_VERSION=3.12
ARG EXPECT_VERSION=5.45.4
ARG FILE_VERSION=5.48
ARG FINDUTILS_VERSION=4.11.0
ARG FLEX_VERSION=2.6.4
ARG GAWK_VERSION=5.4.1
ARG GCC_VERSION=16.2.0
ARG GETTEXT_VERSION=1.0
ARG GLIBC_VERSION=2.44
ARG GMP_VERSION=6.3.0
ARG GREP_VERSION=3.12
ARG GZIP_VERSION=1.14
ARG IANA_ETC_VERSION=20260805
ARG LIBCAP_VERSION=2.78
ARG LIBXCRYPT_VERSION=4.5.2
ARG LINUX_MAJOR=7
ARG LINUX_VERSION=${LINUX_MAJOR}.1.8
ARG LZ4_VERSION=1.10.0
ARG MAKE_VERSION=4.4.1
ARG MAN_PAGES_VERSION=6.18
ARG MESON_VERSION=1.12.0
ARG MPC_VERSION=1.4.1
ARG MPDECIMAL_VERSION=4.0.1
ARG MPFR_VERSION=4.2.2
ARG M4_VERSION=1.4.21
ARG NCURSES_VERSION=6.6
ARG NINJA_VERSION=1.13.2
ARG PATCH_VERSION=2.8
ARG PCRE2_VERSION=10.47
ARG PERL_MAJOR_MINOR_VERSION=5.44
ARG PERL_VERSION=${PERL_MAJOR_MINOR_VERSION}.0
ARG PKGCONF_VERSION=3.0.5
ARG PYTHON_VERSION=3.14.7
ARG READLINE_VERSION=8.3
ARG SED_VERSION=4.10
ARG SHADOW_VERSION=4.20.2
ARG TAR_VERSION=1.35
ARG TCL_VERSION=8.6.18
ARG TEXINFO_VERSION=7.3
ARG TZDATA_VERSION=2026c
ARG UTIL_LINUX_VERSION=2.42.2
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

FROM ch4 AS packages
WORKDIR /packages
COPY --chown=lfs packages /packages

FROM ch4 AS ch5
WORKDIR /work
ARG BINUTILS_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/binutils-${BINUTILS_VERSION}.tar.xz
cd binutils-${BINUTILS_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG GLIBC_VERSION
ARG GCC_VERSION
ARG MPFR_VERSION
ARG MPC_VERSION
ARG GMP_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gcc-${GCC_VERSION}.tar.xz
cd gcc-${GCC_VERSION}
tar -xf /packages/mpfr-${MPFR_VERSION}.tar.xz
mv -v mpfr-${MPFR_VERSION} mpfr
tar -xf /packages/mpc-${MPC_VERSION}.tar.xz
mv -v mpc-${MPC_VERSION} mpc
tar -xf /packages/gmp-${GMP_VERSION}.tar.xz
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG LINUX_MAJOR
ARG LINUX_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/linux-${LINUX_VERSION}.tar.xz
cd linux-${LINUX_VERSION}
make mrproper
make headers
find usr/include -type f ! -name '*.h' -delete
cp -rv usr/include $LFS/usr
shopt -s dotglob
rm -fr /work/*
EOF

ARG GLIBC_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/glibc-${GLIBC_VERSION}.tar.xz
cd glibc-${GLIBC_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG GCC_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gcc-${GCC_VERSION}.tar.xz
cd gcc-${GCC_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

FROM ch5 AS ch6
ARG M4_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
echo ac_cv_func_posix_spawn_file_actions_addchdir=yes >> $LFS/usr/share/config.site
echo ac_cv_func_posix_spawn_file_actions_addfchdir=yes >> $LFS/usr/share/config.site
tar -xf /packages/m4-${M4_VERSION}.tar.xz
cd m4-${M4_VERSION}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG NCURSES_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/ncurses-${NCURSES_VERSION}.tar.gz
cd ncurses-${NCURSES_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG BASH_VERSION_
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/bash-${BASH_VERSION_}.tar.gz
cd bash-${BASH_VERSION_}
./configure --prefix=/usr           \
    --build=$(sh support/config.guess)  \
    --host=$LFS_TGT                     \
    --without-bash-malloc               \
    --docdir=/usr/share/doc/bash-${BASH_VERSION_}
make
make DESTDIR=$LFS install
ln -sv bash $LFS/bin/sh
shopt -s dotglob
rm -fr /work/*
EOF

ARG COREUTILS_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/coreutils-${COREUTILS_VERSION}.tar.xz
cd coreutils-${COREUTILS_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG DIFFUTILS_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/diffutils-${DIFFUTILS_VERSION}.tar.xz
cd diffutils-${DIFFUTILS_VERSION}
./configure --prefix=/usr       \
    --host=$LFS_TGT                 \
    gl_cv_func_strcasecmp_works=yes \
    --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG FILE_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/file-${FILE_VERSION}.tar.gz
cd file-${FILE_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG FINDUTILS_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/findutils-${FINDUTILS_VERSION}.tar.xz
cd findutils-${FINDUTILS_VERSION}
./configure --prefix=/usr       \
    --localstatedir=/var/lib/locate \
    --host=$LFS_TGT                 \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG GAWK_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gawk-${GAWK_VERSION}.tar.xz
cd gawk-${GAWK_VERSION}
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG GREP_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/grep-${GREP_VERSION}.tar.xz
cd grep-${GREP_VERSION}
./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG GZIP_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gzip-${GZIP_VERSION}.tar.xz
cd gzip-${GZIP_VERSION}
./configure --prefix=/usr   \
    --host=$LFS_TGT
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG MAKE_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/make-${MAKE_VERSION}.tar.gz
cd make-${MAKE_VERSION}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG PATCH_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/patch-${PATCH_VERSION}.tar.xz
cd patch-${PATCH_VERSION}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG SED_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/sed-${SED_VERSION}.tar.xz
cd sed-${SED_VERSION}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(./build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG TAR_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/tar-${TAR_VERSION}.tar.xz
cd tar-${TAR_VERSION}
./configure --prefix=/usr   \
    --host=$LFS_TGT             \
    --build=$(build-aux/config.guess)
make
make DESTDIR=$LFS install
shopt -s dotglob
rm -fr /work/*
EOF

ARG XZ_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/xz-${XZ_VERSION}.tar.xz
cd xz-${XZ_VERSION}
./configure --prefix=/usr           \
    --host=$LFS_TGT                     \
    --build=$(build-aux/config.guess)   \
    --disable-static                    \
    --docdir=/usr/share/doc/xz-${XZ_VERSION}
make
make DESTDIR=$LFS install
rm -v $LFS/usr/lib/liblzma.la
shopt -s dotglob
rm -fr /work/*
EOF

# binutils pass 2
ARG BINUTILS_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/binutils-${BINUTILS_VERSION}.tar.xz
cd binutils-${BINUTILS_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

# gcc pass 2
ARG GLIBC_VERSION
ARG GCC_VERSION
ARG MPFR_VERSION
ARG MPC_VERSION
ARG GMP_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gcc-${GCC_VERSION}.tar.xz
cd gcc-${GCC_VERSION}
tar -xf /packages/mpfr-${MPFR_VERSION}.tar.xz
mv -v mpfr-${MPFR_VERSION} mpfr
tar -xf /packages/mpc-${MPC_VERSION}.tar.xz
mv -v mpc-${MPC_VERSION} mpc
tar -xf /packages/gmp-${GMP_VERSION}.tar.xz
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
shopt -s dotglob
rm -fr /work/*
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
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gettext-${GETTEXT_VERSION}.tar.xz
cd gettext-${GETTEXT_VERSION}
./configure --disable-shared
make
cp -v gettext-tools/src/{msgfmt,msgmerge,xgettext} /usr/bin
shopt -s dotglob
rm -fr /work/*
EOF

ARG BISON_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/bison-${BISON_VERSION}.tar.xz
cd bison-${BISON_VERSION}
./configure --prefix=/usr \
    --docdir=/usr/share/doc/bison-${BISON_VERSION}
make
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG PERL_MAJOR_MINOR_VERSION
ARG PERL_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/perl-${PERL_VERSION}.tar.xz
cd perl-${PERL_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG ZLIB_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/zlib-${ZLIB_VERSION}.tar.gz
cd zlib-${ZLIB_VERSION}
./configure --prefix=/usr
make
make install
rm -fv /usr/lib/libz.a
shopt -s dotglob
rm -fr /work/*
EOF

ARG MPDECIMAL_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/mpdecimal-${MPDECIMAL_VERSION}.tar.gz
cd mpdecimal-${MPDECIMAL_VERSION}
./configure --prefix=/usr   \
    --disable-static            \
    --docdir=/usr/share/doc/mpdecimal-${MPDECIMAL_VERSION}
make
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG PYTHON_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/Python-${PYTHON_VERSION}.tar.xz
cd Python-${PYTHON_VERSION}
./configure --prefix=/usr   \
    --enable-shared             \
    --without-ensurepip         \
    --without-static-libpython
make
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG TEXINFO_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/texinfo-${TEXINFO_VERSION}.tar.xz
cd texinfo-${TEXINFO_VERSION}
./configure --prefix=/usr
make
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG UTIL_LINUX_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/util-linux-${UTIL_LINUX_VERSION}.tar.xz
cd util-linux-${UTIL_LINUX_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

RUN <<EOF
set -euo pipefail
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name \*.la -delete
rm -rf /tools
EOF

FROM ch7 AS ch8
ARG MAN_PAGES_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/man-pages-${MAN_PAGES_VERSION}.tar.xz
cd man-pages-${MAN_PAGES_VERSION}
rm -v man3/crypt*
make -R GIT=false prefix=/usr install
shopt -s dotglob
rm -fr /work/*
EOF

ARG IANA_ETC_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/iana-etc-${IANA_ETC_VERSION}.tar.gz
cd iana-etc-${IANA_ETC_VERSION}
cp -v services protocols /etc
shopt -s dotglob
rm -fr /work/*
EOF

ARG GLIBC_VERSION
ARG LINUX_VERSION
ARG TZDATA_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/glibc-${GLIBC_VERSION}.tar.xz
cd glibc-${GLIBC_VERSION}
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
tar -xf /packages/tzdata${TZDATA_VERSION}.tar.gz
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG ZLIB_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/zlib-${ZLIB_VERSION}.tar.gz
cd zlib-${ZLIB_VERSION}
./configure --prefix=/usr
make
make check
make install
rm -fv /usr/lib/libz.a
shopt -s dotglob
rm -fr /work/*
EOF

ARG BZIP2_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/bzip2-${BZIP2_VERSION}.tar.gz
cd bzip2-${BZIP2_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG XZ_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/xz-${XZ_VERSION}.tar.xz
cd xz-${XZ_VERSION}
./configure --prefix=/usr   \
    --disable-static            \
    --docdir=/usr/share/doc/xz-${XZ_VERSION}
make
make check
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG LZ4_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/lz4-${LZ4_VERSION}.tar.gz
cd lz4-${LZ4_VERSION}
make BUILD_STATIC=no PREFIX=/usr
make -j1 check
make BUILD_STATIC=no PREFIX=/usr install
shopt -s dotglob
rm -fr /work/*
EOF

ARG ZSTD_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/zstd-${ZSTD_VERSION}.tar.gz
cd zstd-${ZSTD_VERSION}
make prefix=/usr
make check
make prefix=/usr install
rm -v /usr/lib/libzstd.a
shopt -s dotglob
rm -fr /work/*
EOF

ARG FILE_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/file-${FILE_VERSION}.tar.gz
cd file-${FILE_VERSION}
./configure --prefix=/usr
make
make check
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG READLINE_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/readline-${READLINE_VERSION}.tar.gz
cd readline-${READLINE_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG PCRE2_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/pcre2-${PCRE2_VERSION}.tar.bz2
cd pcre2-${PCRE2_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG M4_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/m4-${M4_VERSION}.tar.xz
cd m4-${M4_VERSION}
./configure --prefix=/usr
make
make check
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG BC_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/bc-${BC_VERSION}.tar.xz
cd bc-${BC_VERSION}
CC='gcc -std=c99' ./configure --prefix=/usr -G -O3 -r
make
make test
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG FLEX_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/flex-${FLEX_VERSION}.tar.gz
cd flex-${FLEX_VERSION}
./configure --prefix=/usr       \
    --disable-static                \
    --docdir=/usr/share/doc/flex-${FLEX_VERSION}
make
make check
make install
ln -sv flex   /usr/bin/lex
ln -sv flex.1 /usr/share/man/man1/lex.1
shopt -s dotglob
rm -fr /work/*
EOF

ARG TCL_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/tcl${TCL_VERSION}-src.tar.gz
SRCDIR=/work/tcl${TCL_VERSION}
cd tcl${TCL_VERSION}/unix
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
tar -xf /packages/tcl${TCL_VERSION}-html.tar.gz --strip-components=1
mkdir -v -p /usr/share/doc/tcl-${TCL_VERSION}
cp -v -r  ./html/* /usr/share/doc/tcl-${TCL_VERSION}
shopt -s dotglob
rm -fr /work/*
EOF

ARG EXPECT_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/expect${EXPECT_VERSION}.tar.gz
cd expect${EXPECT_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG DEJAGNU_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/dejagnu-${DEJAGNU_VERSION}.tar.gz
cd dejagnu-${DEJAGNU_VERSION}
mkdir -pv build
cd build
../configure --prefix=/usr
makeinfo --html --no-split -o doc/dejagnu.html ../doc/dejagnu.texi
makeinfo --plaintext       -o doc/dejagnu.txt  ../doc/dejagnu.texi
make check
make install
install -v -dm755  /usr/share/doc/dejagnu-${DEJAGNU_VERSION}
install -v -m644   doc/dejagnu.{html,txt} /usr/share/doc/dejagnu-${DEJAGNU_VERSION}
shopt -s dotglob
rm -fr /work/*
EOF

ARG NINJA_VERSION
ENV NINJAJOBS=7
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/ninja-${NINJA_VERSION}.tar.gz
cd ninja-${NINJA_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG PKGCONF_VERSION
ARG MESON_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/pkgconf-${PKGCONF_VERSION}.tar.xz
cd pkgconf-${PKGCONF_VERSION}
tar -xf /packages/meson-${MESON_VERSION}.tar.gz
mkdir -pv build
cd build
python3 ../meson-${MESON_VERSION}/meson.py setup --prefix=/usr --buildtype=release ..
ninja
ninja test
ninja install
mv /usr/share/doc/pkgconf{,${PKGCONF_VERSION}}
ln -sv pkgconf   /usr/bin/pkg-config
ln -sv pkgconf.1 /usr/share/man/man1/pkg-config.1
shopt -s dotglob
rm -fr /work/*
EOF

ARG BINUTILS_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/binutils-${BINUTILS_VERSION}.tar.xz
cd binutils-${BINUTILS_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG GMP_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gmp-${GMP_VERSION}.tar.xz
cd gmp-${GMP_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG MPFR_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/mpfr-${MPFR_VERSION}.tar.xz
cd mpfr-${MPFR_VERSION}
./configure --prefix=/usr        \
            --disable-static     \
            --enable-thread-safe \
            --docdir=/usr/share/doc/mpfr-${MPFR_VERSION}
make
make html
make check
make install
make install-html
shopt -s dotglob
rm -fr /work/*
EOF

ARG MPC_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/mpc-${MPC_VERSION}.tar.xz
cd mpc-${MPC_VERSION}
./configure --prefix=/usr    \
            --disable-static \
            --docdir=/usr/share/doc/mpc-${MPC_VERSION}
make
make html
make check
make install
make install-html
shopt -s dotglob
rm -fr /work/*
EOF

ARG ATTR_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/attr-${ATTR_VERSION}.tar.gz
cd attr-${ATTR_VERSION}
./configure --prefix=/usr       \
            --disable-static    \
            --sysconfdir=/etc   \
            --docdir=/usr/share/doc/attr-${ATTR_VERSION}
make
# make check # docker doesn't support attr
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG ACL_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/acl-${ACL_VERSION}.tar.xz
cd acl-${ACL_VERSION}
./configure --prefix=/usr       \
            --disable-static    \
            --docdir=/usr/share/doc/acl-${ACL_VERSION}
make
# make check # docker doesn't support ACL
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG LIBCAP_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/libcap-${LIBCAP_VERSION}.tar.xz
cd libcap-${LIBCAP_VERSION}
sed -i '/install -m.*STA/d' libcap/Makefile
make prefix=/usr lib=lib
make test
make prefix=/usr lib=lib install
shopt -s dotglob
rm -fr /work/*
EOF

ARG LIBXCRYPT_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/libxcrypt-${LIBXCRYPT_VERSION}.tar.xz
cd libxcrypt-${LIBXCRYPT_VERSION}
sed -i '/strchr/s/const//' lib/crypt-{sm3,gost}-yescrypt.c
./configure --prefix=/usr                \
            --enable-hashes=strong,glibc \
            --enable-obsolete-api=no     \
            --disable-static             \
            --disable-failure-tokens
make
make check
make install
shopt -s dotglob
rm -fr /work/*
EOF

ARG SHADOW_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/shadow-${SHADOW_VERSION}.tar.xz
cd shadow-${SHADOW_VERSION}
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
shopt -s dotglob
rm -fr /work/*
EOF

ARG GAWK_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gawk-${GAWK_VERSION}.tar.xz
cd gawk-${GAWK_VERSION}
sed -i 's/extras//' Makefile.in
./configure --prefix=/usr
make
# chown -R tester .
# su tester -c "PATH=$PATH make check" # broken in docker
rm -f /usr/bin/gawk-${GAWK_VERSION}
make install
ln -sv gawk.1 /usr/share/man/man1/awk.1
install -vDm644 doc/{awkforai.txt,*.{eps,pdf,jpg}} -t /usr/share/doc/gawk-${GAWK_VERSION}
shopt -s dotglob
rm -fr /work/*
EOF

ARG GCC_VERSION
RUN --mount=type=bind,from=packages,source=/packages,target=/packages \
<<EOF
set -euo pipefail
tar -xf /packages/gcc-${GCC_VERSION}.tar.xz
cd gcc-${GCC_VERSION}
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
ulimit -s -H unlimited
chown -R tester .
su tester -c "PATH=$PATH make -k check"
../contrib/test_summary -t
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
shopt -s dotglob
rm -fr /work/*
EOF
