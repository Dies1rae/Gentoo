#!/bin/bash
LOG_BASE_NAME="${0}_$(date '+%FT%X')"
exec 333>/${LOG_BASE_NAME}.trace.log
BASH_XTRACEFD=333
exec > >(tee -ia /${LOG_BASE_NAME}.log)
exec 2> >(tee -ia /${LOG_BASE_NAME}.log >&2)
set -x


SQFS_IMG=$1

#Go to root, if start with errors
cd /

if [ $(id -u) -ne 0 ]; then
    echo "Must be root"
    exit 1
fi

#Here we need squashfs or img file with system(todo)
if [[ $(file -b "$SQFS_IMG" | cut -f 1 -d " ") != 'Squashfs' ]]; then
    echo "Usage: $0 <squashfs image file>"
    exit 1
fi

if [ -d /bak -o -d /new ]; then
    echo "Unclean root. Remove /new and /bak directories before upgrade."
    exit 1
fi

if ! ( mountpoint -q /home && mountpoint -q /var/lib && mountpoint -q /var/log ); then 
    echo "Unsuspected mount scheme for /var/lib, /var/log, /home";
    exit 1
fi

free_space=$(df --output=avail -BG / | tail -n1)
if [[ ${free_space%G} -lt 9 ]]; then
    echo "Unsufficient free space in root partition. Needed 9G free space."
    exit 1
fi

boot_type=$( [[ -d /sys/firmware/efi/efivars ]] && echo 'EFI' || echo 'BIOS' )

#Save network iface name with MAC
#If can not exiting
iface_cfg=$(grep -E '^[[:space:]]*'"config_" /etc/conf.d/net)
re='^[[:space:]]*config_([A-Za-z0-9]+)=.+'

if [[ ${iface_cfg} =~ ${re} ]]; then 
    iface_old_name=${BASH_REMATCH[1]}
    iface_mac=$(cat /sys/class/net/${iface_old_name}/address)
else
    echo "No valid network configuration found."
    exit 1
fi

#Go
NEWROOT='/mnt/newroot'
mkdir -p $NEWROOT

#Mount new system, later here chroot mount will be
mount -t squashfs -o loop $SQFS_IMG $NEWROOT
#Old root mount, to work later fromnew  chroot
OLDROOT="$NEWROOT/mnt"
mount -o bind / $OLDROOT

while read i;do
    rc-service $i stop
done <<SRVLIST
nfs
cupsd
xdm
dnsmasq
cronie
SRVLIST

#Change root
mount --rbind /dev $NEWROOT/dev
mount --make-rslave $NEWROOT/dev
mount -t proc none $NEWROOT/proc
mount --rbind /sys $NEWROOT/sys
mount --make-rslave $NEWROOT/sys
mount --rbind /tmp $NEWROOT/tmp

TIMEZONE_STR=$(eselect --brief timezone show | awk '{ print $1 }')
LOCALE_STR=$(eselect --brief locale show | awk '{ print $1 }')


ulimit -n 150000
chroot $NEWROOT /bin/bash -e <<'EOCHROOT'
BASH_XTRACEFD=333
set -x

OLDROOT='/mnt'

mkdir $OLDROOT/new
#From mounted img\squash copy root to new
cp -a -x -t $OLDROOT/new /{bin,sbin,boot,lib,lib64,etc,opt,usr,var}

mkdir $OLDROOT/bak
#Move old root to bak
mv $OLDROOT/{bin,sbin,boot,lib,lib64,etc,opt,usr,var} $OLDROOT/bak/

#Move new from /new to root
mv $OLDROOT/new/{bin,sbin,boot,lib,lib64,etc,opt,usr,var} $OLDROOT/

#Copy /etc configs from old /bak to new /
cd $OLDROOT/bak/etc
cat <<ENDOFLIST | while read i; do if [ -e $i ]; then echo $i; fi; done | xargs tar -c | tar -x -C $OLDROOT/etc
conf.d/hostname
conf.d/net
cups/cupsd.conf
cups/printers.conf
hosts
localtime
skytools/gen/
ssl/edi/
ssl/gpay/
ssl/stoloto/
timezone
x11vnc.passwd
postgresql-9.6/postgresql.conf
postgresql-9.6/pg_hba.conf
pgbouncer/userlist.txt
pgbouncer.ini
fstab
ENDOFLIST
cd -

cp -a -x -t $OLDROOT/var/opt/ $OLDROOT/bak/var/opt/*

EOCHROOT

rm -f /etc/local.d/*.start

#Kill dhcpd (todo need to do by args)
rc-service dhcpcd stop
rc-update delete dhcpcd default

for iface_new_name in `/bin/ls -1 /sys/class/net/`; do
    echo "Forced recreate links in runlevels"
    rc-update add net.${iface_new_name} default
    rc-service net.${iface_new_name} restart
done

sensors-detect --auto


chmod a-x $0
mv $0 /root/$(basename $0 '.start').do_not_run

EOF

chmod 754 /etc/local.d/at_first_boot.start

# Back gfrom chroot to /, here all new ;-)
# mount /var/lib & /var/log to old place
mount --bind /bak/var/log /var/log
mount --bind /bak/var/lib /var/lib

env-update
source /etc/profile

# Fix owners on /var/lib /var/log /home
# For that porpouse create arrays with old and new users id and group id on the systems,
# Change owners on folders\files recurcevly

read_ent_id_name() {
    F=$1
    declare -n A="$2"
    while IFS=: read -r ent_name x1 ent_id x2; do
        A[$ent_id]="$ent_name"
    done < "$F"
}

read_ent_name_id() {
    F=$1
    declare -n A="$2"
    while IFS=: read -r ent_name x1 ent_id x2; do
        A[$ent_name]="$ent_id"
    done < "$F"
}

get_name_or_root() {
    N=$1
    declare -n A="$2"
    declare -n res="$3"
    if [ -z ${A[$N]} ]; then
        res="root"
    else
        res="$N"
    fi
}

declare -A passwd_old_array
read_ent_id_name /bak/etc/passwd passwd_old_array

declare -A group_old_array
read_ent_id_name /bak/etc/group group_old_array

declare -A passwd_new_array
read_ent_name_id /etc/passwd passwd_new_array

declare -A group_new_array
read_ent_name_id /etc/group group_new_array

update_owners() {
    DIR=$1
    find -P $DIR -type d,f -printf '%p\t%U\t%G\n' | while IFS=$'\t' read -r fname uid gid;
    do
        uname=${passwd_old_array[$uid]}
        if [ -z $uname ]; then
            new_uname=$uid
        else
            get_name_or_root $uname passwd_new_array new_uname
        fi
        gname=${group_old_array[$gid]}
        if [ -z $gname ]; then
            new_gname=$gid
        else
            get_name_or_root $gname group_new_array new_gname
        fi
        chown -P -c $new_uname:$new_gname "$fname"
    done
}

update_owners /var/log
update_owners /var/lib
update_owners /var/opt
update_owners /home


#Set timezones
eselect timezone set "$TIMEZONE_STR"
eselect locale set "$LOCALE_STR"
source /etc/profile
paperconf -p a4

source /etc/conf.d/hostname
HOSTNAME="$hostname"

#This is varios part(may use not lxqt)
cat <<-'EOF' > /etc/env.d/90xsession
#Gentoo build config

XSESSION="lxqt"
EOF

cat <<-'EOF' > /etc/conf.d/display-manager
# We always try and start the DM on a static VT. The various DMs normally
# default to using VT7. If you wish to use the display-manager init
# script, then you should ensure that the VT checked is the same VT your
# DM wants to use.
# We do this check to ensure that you haven't accidentally configured
# something to run on the VT in your /etc/inittab file so that
# you don't get a dead keyboard.
CHECKVT=7

# What display manager do you use ?
#     [ xdm | greetd | gdm | sddm | gpe | lightdm | entrance ]
# NOTE: If this is set in /etc/rc.conf, that setting will override this one.
DISPLAYMANAGER="sddm"
EOF


#Get old root passwd to new root
OLD_ROOT_RECORD=$(grep -F 'root' /bak/etc/shadow)
if [ -n ${OLD_ROOT_RECORD} ]; then
    /bin/sed -i "s~root:.*~${OLD_ROOT_RECORD}~g" /etc/shadow
fi

add_optional_services()
{
    SVC_NAME=$1
    if [ -e /bak/etc/runlevels/default/$SVC_NAME ]; then
        rc-update add $SVC_NAME default
    fi
}

#Restore network
ls -1 /bak/etc/init.d/net.* | grep -v 'net.lo' | xargs cp -d -t /etc/init.d

#Grub reinstall
for i in $(lsblk -pnro NAME,TYPE | grep -iF 'disk' | cut -d ' ' -f1)
do
    if [[ "$boot_type" == 'EFI' ]] ;
    then
        efi_part=$(lsblk -pnro NAME,TYPE,PARTLABEL -x NAME $i | grep -iF 'part' | grep -iF 'EFI' | cut -d ' '  -f1 | xargs)
        mkdir -p  /boot/efi
        mount ${efi_part} /boot/efi/

        echo "Installing GRUB on $i in UEFI mode"
        grub-install --target=x86_64-efi --efi-directory=/boot/efi $i

        mkdir -p  /boot/efi/EFI/Boot
        cp -rv /boot/efi/EFI/gentoo/grubx64.efi /boot/efi/EFI/Boot/bootx64.efi
        umount /boot/efi/
    else
        echo "Installing GRUB on $i in BIOS mode"
        grub-install $i
    fi
done

# сгенерировать grub.conf
cat <<-'EOF' > /boot/grub/grub.cfg
set gfxmode=auto
insmod all_video
insmod gfxterm
loadfont $prefix/fonts/unicode.pf2
set locale_dir=$prefix/locale
#set lang=ru_RU.UTF-8
#set language=ru_RU.UTF-8
insmod gettext
set timeout=2

menuentry "Sensenet OS based on Gentoo GNU/Linux" {
    insmod gzio
    insmod mdraid1x
    insmod ext2
    insmod part_gpt

    linux /boot/vmlinuz rd.auto rd.md=1 rd.lvm=0 rd.dm=0 rd.multipath=0 domdadm root=LABEL=ROOT ro
    initrd /boot/initramfs
}
EOF

update-ca-certificates

#Hands reboot
#Do not forget update world after reboot

