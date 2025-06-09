#!/bin/bash
#set -x
set -e

usage()
{
cat <<EOF
$0 <build|bindist> [options] ...

Available options are:
    -a <ARCHITECTURE>
       'amd64' or 'x86'. By default 'amd64'
    -r - recover existing chroot and exit. 
       Restore filesystem mounts inside existing chroot and do nothing anymore.
    -u - umount all internal (inside chroot) mounts and exit.
    -U - the same as '-u', but additionally umount chroot itself completely and exit.
    -d <TARGET_PATH> 
       Desired chroot folder path. 
       By default: "./gentoo_amd64_build" (for build) or "./gentoo_amd64_bindist" (for bindist)
    -D <DISTFILES_DIR>
       Directory with gentoo distfiles. By default is distfiles of this host.
    -P <PACKAGES_DIR>
       Directory with gentoo compiled packages. By default is ./packages.
    -C <CCAHE_DIR>
       Directory for ccache. By default is ./ccache.
EOF
}

if [ $# -lt 2 ] ;then
  usage
  exit 2
fi

DISTR_TYPE=$2
shift
shift

case ".${DISTR_TYPE}." in
    ".build.")
        ;;
    ".bindist.")
        ;;
    *)
        usage
        exit 2
        ;;
esac

ARCH=amd64 # x86
CHROOT_DIR=./gentoo-$ARCH-$DISTR_TYPE

#TODO GET MIRROR FROM ARGS
OWN_PORTAGE_MIRROR="https://mirror.yandex.ru/gentoo-distfiles/"

RECOVER_ONLY=no
UMOUNT_CHROOT=no
eval $(emerge --info | grep -F 'DISTDIR')
PACKAGES_DIR="./packages"
L_CCACHE_DIR="./ccache"
UMOUNT_INCHROOT=no

while getopts "a:d:D:P:rUu" OPTION ; do
    case $OPTION in
	a) ARCH=$OPTARG
	   case ".${ARCH}," in
	       ".amd64.") ;; ".x86.") ;;
	       *) echo "Invalid '-a <ARCHITECTURE>' settings"; usage; exit 2 ;;
	   esac
	   ;;
	d) CHROOT_DIR=`cat $OPTARG | sed 's%\([^/]\)/[/]\+$%\1%g'` # drop training slashes
	   if [ -z "$CHROOT_DIR" ] ; then
	       echo "Invalid '-d <TARGET_PATH>' settings"; usage; exit 2
	   fi
	   ;;
	D) DISTDIR=$OPTARG
	   if [ -z "$DISTDIR" ] ; then
	       echo "Invalid '-D <DISTFILES_DIR>' settings"; usage; exit 2
	   fi
	   ;;
	P) PACKAGES_DIR=$OPTARG
	   if [ -z "$PACKAGES_DIR" ] ; then
	       echo "Invalid '-P <PACKAGES_DIR>' settings"; usage; exit 2
	   fi
	   ;;
	C) L_CCACHE_DIR=$OPTARG
	   if [ -z "$L_CCACHE_DIR" ] ; then
	       echo "Invalid '-C <CCACHE_DIR>' settings"; usage; exit 2
	   fi
	   ;;
	r) RECOVER_ONLY=yes ;;
	U) UMOUNT_CHROOT=yes ;;
	u) UMOUNT_INCHROOT=yes ;;
    esac
done

[ $(id -u) -ne 0 ] && echo "must be superuser" && exit 1

mkdir -p $DISTDIR
mkdir -p $PACKAGES_DIR
mkdir -p $L_CCACHE_DIR
mkdir -p $CHROOT_DIR

:<<CommentOut
wget -r -l1 -np "http://mirror.yandex.ru/gentoo-distfiles/releases/$ARCH/autobuilds/current-stage3-$ARCH" -P ./ -A "stage3-$ARCH-20*.tar.xz"
wget http://mirror.yandex.ru/gentoo-distfiles/snapshots/portage-latest.tar.xz
CommentOut

do_umounts()
{
    UMOUNT_ROOT=${1:-'umount_chroot'}
    CHROOT_ABS=$(readlink -f ${CHROOT_DIR})
    ec=1
    counts=0
    while [ $ec -eq 1 -a $counts -lt 10 ] ; do
	ec=0
	counts=$(($counts+1))
	for fs in `cat /proc/self/mountinfo | cut -f5 -d ' ' | grep -F "${CHROOT_ABS}/" | sort -r -d`; do
	    echo umounting $fs
	    umount $fs && ec=1 || true
	done

	if [ $UMOUNT_ROOT = 'umount_chroot' ] ; then
	    umount $CHROOT_DIR && ec=1 || true
	fi
    done
}

check_target_mounted()
{
    TARGET_ABS=$(readlink -f $1)
    ( cat /proc/self/mountinfo | cut -f5 -d ' ' | grep -q -F "${TARGET_ABS}" ) && return 0 || return 1
}

do_in_chroot_mounts()
{
    check_target_mounted $CHROOT_DIR/dev  || mount --rbind /dev $CHROOT_DIR/dev && mount -o remount,gid=5 $CHROOT_DIR/dev/pts
    check_target_mounted $CHROOT_DIR/proc || mount -t proc none $CHROOT_DIR/proc
    check_target_mounted $CHROOT_DIR/sys  || mount -o bind /sys $CHROOT_DIR/sys
    check_target_mounted $CHROOT_DIR/var/cache/distfiles || mount -o bind $DISTDIR $CHROOT_DIR/var/cache/distfiles
    check_target_mounted $CHROOT_DIR/var/cache/binpkgs  || mount -o bind ${PACKAGES_DIR} $CHROOT_DIR/var/cache/binpkgs
    check_target_mounted $CHROOT_DIR/var/tmp/ccache  || mount -o bind ${L_CCACHE_DIR} $CHROOT_DIR/var/tmp/ccache
}

if [ $UMOUNT_CHROOT = yes ] ; then
    do_umounts "umount_chroot"
    exit;
fi

if [ $UMOUNT_INCHROOT = yes ] ; then
    do_umounts "dont_umount_chroot"
    exit
fi

if [ $RECOVER_ONLY = yes ] ; then
    do_umounts "dont_umount_chroot"
    do_in_chroot_mounts
    exit
fi

# do_umounts "umount_chroot"
if ( ! check_target_mounted $CHROOT_DIR ) ; then
    mount -t tmpfs -o size=50G none $CHROOT_DIR

    mkdir -p $CHROOT_DIR/{dev,proc,sys,tmp,etc/portage/repos.conf}


    STAGE3_ARCHIVE=`ls -1v ./stage3-$ARCH-*.tar.xz | tail -n1`
    PORTAGE_ARCIVE=`ls -1v ./portage-*.tar.xz | tail -n1`
    XZ=$( pxz -V 2>/dev/null 1>&2 && echo 'pxz' || echo 'xz' )

    echo "Unpacking Stage3 archive:"
    ./bar $STAGE3_ARCHIVE | tar --use-compress-program=$XZ --acls --xattrs --xattrs-include='*.*' -xp -C $CHROOT_DIR
    echo "Unpacking Portage archive:"
    ./bar $PORTAGE_ARCIVE | tar --use-compress-program=$XZ --acls --xattrs --xattrs-include='*.*' -x -C $CHROOT_DIR/var/db/repos/
    mv $CHROOT_DIR/var/db/repos/portage $CHROOT_DIR/var/db/repos/gentoo
else
    echo "#### Attention! Work with existing chroot env!"
    echo "     If this is not what you want, then you must run: $0 $DISTR_TYPE -U"
    mkdir -p $CHROOT_DIR/{dev,proc,sys,tmp,etc/portage/repos.conf}
fi

mkdir -p $CHROOT_DIR/var/cache/{distfiles,binpkgs}
mkdir -p $CHROOT_DIR/var/tmp/ccache
do_in_chroot_mounts

cp -L /etc/resolv.conf $CHROOT_DIR/etc

# Generate make.conf
cat <<-EOF > $CHROOT_DIR/etc/portage/make.conf
# Sensenet specific make.conf

EOF

grep -F 'CHOST' $CHROOT_DIR/usr/share/portage/config/make.conf.example >> $CHROOT_DIR/etc/portage/make.conf

cat <<-'EOF' >> $CHROOT_DIR/etc/portage/make.conf

PORTAGE_NICENESS="12"
COLLISION_IGNORE="${COLLISION_IGNORE} /lib/firmware/*"
LINGUAS="ru kk ky tj en be"
L10N="ru kk ky tj en be"

ACCEPT_LICENSE="*"

EOF

CPU_COUNT=$(( 1 + $(cat /proc/cpuinfo | grep -e 'processor[[:space:]]*:' | wc -l) ))

echo "MAKEOPTS="'"'"-j$CPU_COUNT"'"' >> $CHROOT_DIR/etc/portage/make.conf

case $DISTR_TYPE in
    build)
cat <<-'EOF' >> $CHROOT_DIR/etc/portage/make.conf
FEATURES="ccache"
CCACHE_SIZE="8G"
CCACHE_DIR=/var/tmp/ccache
EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS}"
EOF
        ;;
    bindist)
cat <<-'EOF' >> $CHROOT_DIR/etc/portage/make.conf
FEATURES=""
EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS}"
EOF
        ;;
    *)
        echo "Usage: $0 (build|bindist)"
        exit 2
        ;;
esac

# Generate portage & overlay configs
cat <<-EOF > $CHROOT_DIR/etc/portage/repos.conf/gentoo.conf
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
#sync-uri = rsync://${OWN_PORTAGE_MIRROR}/gentoo-portage
#sync-uri = rsync://10.74.33.166/gentoo-portage
sync-uri = https://github.com/gentoo-mirror/gentoo

EOF

# Pre-Configure system
cat <<-'EOF' > $CHROOT_DIR/etc/locale.gen
# Sensenet Gentoo build config

en_US ISO-8859-1
en_US.UTF-8 UTF-8
en_GB.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
EOF

source ${DISTRO_SPEC_DIR}/command_before_chroot

# Work begins in chroot
ulimit -n 50000
BEFORE_INST_SCRIPT=$(cat ${DISTRO_SPEC_DIR}/before_inst) \
AFTER_INST_SCRIPT=$(cat ${DISTRO_SPEC_DIR}/after_inst) \

#Get profile from args TODO
MYPROFILE=$(cat ${DISTRO_SPEC_DIR}/PROFILE) \
DISTR_TYPE=$DISTR_TYPE chroot $CHROOT_DIR /bin/bash -e <<'EOCHROOT'
source /etc/profile
env-update
export PS1="(chroot) $PS1"

emerge --sync

if [ "$DISTR_TYPE" = build ]; then
    EMERGE_EXTRA_OPTS=" --with-bdeps=y"
    emerge $EMERGE_EXTRA_OPTS dev-util/ccache
EOF
fi

eselect profile set "${MYPROFILE}"
source /etc/profile
env-update

emerge $EMERGE_EXTRA_OPTS app-portage/eix
chown -R portage:portage /var/cache/eix
eix-update
emerge $EMERGE_EXTRA_OPTS --oneshot portage

eselect news read

etc-update --automode -5

locale-gen
eselect locale set 'ru_RU.utf8'

eval "${BEFORE_INST_SCRIPT}"

if [ "$DISTR_TYPE" = build ]; then
    declare -a pkglist_to_rebuild=($(EIX_LIMIT=0 eix --installed))
    if [ ${#pkglist_to_rebuild[@]} -gt 0 ]; then
        emerge $EMERGE_EXTRA_OPTS --keep-going ${pkglist_to_rebuild[@]}
    fi
fi

emerge -uUND $EMERGE_EXTRA_OPTS @world

etc-update --automode -5

# Configure system
cat <<-'EOF' > /etc/locale.gen
# Sensenet Gentoo build config

en_US ISO-8859-1
en_US.UTF-8 UTF-8
en_GB.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
EOF

locale-gen
eselect locale set 'ru_RU.utf8'

cat <<-'EOF' > /etc/conf.d/consolefont
# Sensenet Gentoo build config

CONSOLEFONT="ter-k16n"
EOF

cat <<-'EOF' > /etc/conf.d/keymaps
# Sensenet Gentoo build config

keymap="-u ru"

windowkeys="YES"

extended_keymaps=""
#extended_keymaps="backspace keypad euro2"

dumpkeys_charset="koi8-r"
#dumpkeys_charset=""

fix_euro="NO"
EOF

update-ca-certificates
chown root:mail /var/spool/mail/
chmod 03775 /var/spool/mail/

cd /var/db
make
cd -

eval "${AFTER_INST_SCRIPT}"

EOCHROOT

echo "== Congratulation! It's complete! =="

