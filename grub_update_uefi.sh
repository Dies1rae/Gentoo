#!/bin/bash
#
#Скрипт предполагает запуск с правами супер юзера из любой дирректории.
#Важное замечание скрипт в режиме создание раздела создаст новый раздел на устройстве где смонтировн кореневой раздел
#Если требуется иное, например создать загрузочный раздел на другом диске, то придется сделать это рукамии
#После создания раздела на нем будет исполненна команда grub-install  спараметрами EFI и запись в grub.cfg по аналогии со скриптами обновления ядра
#Синопсис приведен ниже в help, но в общем виде соблюдает правило синтаксиса 
#Так же важное уточнение. Скрипт работает только с разделами и параметрами GRUBa 
#Любые задачи EFI касающиеся ядра должны быть сделаны заблаговременно вручную администраторами
#./scrpt_name arg command 
#
#
#Логика работы скрипта делится на два сценария и включает следующие шаги
#Сценарий 1(Раздел создается и форматируется вручную):
#0) Администратор руками создает загрузочный раздел на блочном устройстве и форматирует его в vfat
#1) Скрипт запускается с аргументом -d /dev/sdm10999 и указанием созданного раздела 
#2) Проверка прав суперпользователя
#3) Проверка типа загрузки в системе(если уже EFI выход)
#4) Проверка раздела на то что он блочное устройство 
#5) Проверка раздела на объем(более 200Mb)
#6) Проверка раздела на тип vfat
#7) Поиск девайса на котором расположен корневой раздел
#8) Создание директорий /boot/efi и монтирование туда нового раздела
#9) Установка груба на новый раздел
#10) Правка grub.conf 
#11) Завершение работы
#
#Сценарий 2(Раздел создается и форматируется скриптом):
#0) Проверка прав суперпользователя
#1) Проверка типа загрузки в системе(если уже EFI выход)
#2) Поиск девайса на котором расположен корневой раздел
#3) Создание нового раздела
#   a) Поиск последнего ID партиции на корневом разделе и обозначение следующей за ней
#   b) Создание нового загрузочного раздела на 215Mb на устройстве корневой партиции со следующим за последним ID диска
#   c) форматирование раздела в vfat
#4) Проверка раздела на то что он блочное устройство 
#5) Проверка раздела на объем(более 200Mb)
#6) Проверка раздела на тип vfat
#10) Создание директорий /boot/efi и монтирование туда нового раздела
#11) Установка груба на новый раздел
#12) Правка grub.conf 
#13) Завершение работы

#-----------------------------
#LOGS
#-----------------------------
LOG_BASE_NAME="${0}_$(date '+%FT%X')"
exec 333>./${LOG_BASE_NAME}.trace.log
BASH_XTRACEFD=333
exec > >(tee -ia ./${LOG_BASE_NAME}.log)
exec 2> >(tee -ia ./${LOG_BASE_NAME}.log >&2)
set -o nounset
set -e
set -x

#-----------------------------
#DISK FROM ARGS(FOR NOW) AND VARS
#-----------------------------
NEW_VFAT_DISK=""
ROOT_PARTITION=""
CREATE_VAR=""
LAST_ID_ON_ROOT_PART=""
NEXT_ID_ON_ROOT_PART=""
ROOT_BLOCKDEV=""
LAST_SECTOR_OF_ROOT_BLOCKDEV=""

#----------------------------
#USAGE
#-----------------------------
usage()
{
    cat <<EOF

    Usage:
    $0 -c               install
    $0 -d               %*vfat* partition% install
    $0 -h
    Parameters:
    -c                                      install     Create new *vfat* block device 215 Mb capacity and try to install grub there in EFI mode and update grub cfg
    -d					%*vfat* partition%  install     Name of already created by hand vfat partition(like /dev/sda1) at least 215 Mb capacity
    -h					Help information
    Synopsis:
    $0 -command-
    $0 -command- -args- 

    $0 -c install
    $0 -d sda1 install
    $0 -h
    $0 help
EOF
}

check_root_priv()
{
    #-----------------------------
    #Checking root privileges
    #-----------------------------
    echo "Check root priv"
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root. Exiting."
        exit 1
    else
        echo "Root is on, all good."
    fi
}

check_old_boot_type()
{
    #-----------------------------
    #Checking if already efi boot
    #-----------------------------
    old_boot_type=$( [[ -d /sys/firmware/efi/efivars ]] && echo 'EFI' || echo 'BIOS' )

    if [[ "$old_boot_type" == 'EFI' ]] ;
    then
        echo "---Boot already on EFI mode---"
        echo "---Exit from switch to UEFI---"
        exit 0
    fi
}

root_partition()
{
    #-----------------------------
    #Find root partition (its for making boot in future)
    #-----------------------------
    echo "Finding root partition"
    ROOT_PARTITION=$(df -P / | tail -n 1 | awk '/.*/ { print $1 }')
    ROOT_BLOCKDEV=${ROOT_PARTITION%?}
    echo "Root block device is: " $ROOT_BLOCKDEV
    echo "Root partition is:" $ROOT_PARTITION

}

create_And_Format_New_Partition()
{
    # Create GPT partition table()
    fdisk $ROOT_BLOCKDEV <<EOF
    n


    +250Mb
    t
    
    ef00
    w
EOF

    #-----------------------------
    #Find root partition then find last disk ID on root partition and then 
    #create efi boot partition and format it with vfat
    #-----------------------------
    LAST_ID_ON_ROOT_PART=$(lsblk -nlpo NAME,TYPE "${ROOT_PARTITION%?}" | awk '$2=="part"{print $1}' | sed 's/.*\(.\)$/\1/' | tail -n 1)

    #Format the partition as FAT32
    mkfs.vfat -F32 ${ROOT_BLOCKDEV}${LAST_ID_ON_ROOT_PART}

    echo "EFI partition created successfully on ${ROOT_BLOCKDEV}${LAST_ID_ON_ROOT_PART}."
}

update_Grub_Creating_Disk()
{
    echo "---METHOD WITH DISK CREATING---"
    
    #-----------------------------
    #Create new vfat partition on root device
    #-----------------------------
    create_And_Format_New_Partition

    #-----------------------------
    #Installing grub to new vfat partition and modify grub stuff
    #-----------------------------
    mkdir -p /boot/efi
    umount /boot/efi/
    vfat=${ROOT_BLOCKDEV}${LAST_ID_ON_ROOT_PART}
    if [[ -b $vfat ]] ; then 
    [[ $(blkid -o value -s TYPE "$vfat") == vfat ]]
    (( $(lsblk -bnpo SIZE $vfat) > 209715200 ))
        #modify grub stuff
        mount $vfat /boot/efi/
        echo "Installing GRUB on $vfat in UEFI mode"
        grub-install --target=x86_64-efi --efi-directory=/boot/efi $vfat
        mkdir -p  /boot/efi/EFI/Boot
        cp -rv /boot/efi/EFI/gentoo/grubx64.efi /boot/efi/EFI/Boot/bootx64.efi
        umount /boot/efi/
        echo "Grub install on EFI disk done."
    else
        echo "Something wrong with disk $vfat exiting"
        exit 1
    fi
    #-----------------------------

    #-----------------------------
    #grub.conf generate
    #-----------------------------
    echo "grub.conf generate"

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

    menuentry "MobilCard OS based on Gentoo GNU/Linux" {
        insmod gzio
        insmod mdraid1x
        insmod ext2
        insmod part_gpt

        linux /boot/vmlinuz rd.auto rd.md=1 rd.lvm=0 rd.dm=0 rd.multipath=0 domdadm root=LABEL=ROOT ro
        initrd /boot/initramfs
    }
EOF

    echo "---Grub switch finished correctly---"
    echo "---Exit from switch to UEFI---"
    exit 0
}

update_Grub_Without_creating_disk()
{
    echo "---METHOD WITHOUT DISK CREATING---"
    echo "---DISK GETS FROM ARGS: $NEW_VFAT_DISK---"

    #-----------------------------
    #Check disk from args on block device, vfat mask and free space
    #(Disk need to be create by hand before runing this script)
    #-----------------------------
    if [[ ! -b $NEW_VFAT_DISK ]] ; then
        echo "$NEW_VFAT_DISK is not a block device"
        exit 1 
    fi

    if (( $(lsblk -bnpo SIZE $NEW_VFAT_DISK) < 209715200 )) ; then
        echo "$NEW_VFAT_DISK is too small for boot partition"
        exit 1 
    fi

    if [[ $(blkid -o value -s TYPE "$NEW_VFAT_DISK") != vfat ]] ; then
        echo "$NEW_VFAT_DISK is not VFAT"
        exit 1 
    fi 

    #-----------------------------
    #Installing grub to new vfat partition and modify grub stuff
    #-----------------------------
    mkdir -p /boot/efi
    mount $NEW_VFAT_DISK /boot/efi/

    echo "Installing GRUB on $NEW_VFAT_DISK in UEFI mode"
    grub-install --target=x86_64-efi --efi-directory=/boot/efi $NEW_VFAT_DISK

    mkdir -p  /boot/efi/EFI/Boot
    cp -rv /boot/efi/EFI/gentoo/grubx64.efi /boot/efi/EFI/Boot/bootx64.efi

    umount /boot/efi/
    echo "Grub install on EFI disk done."

    #-----------------------------
    #grub.conf generate
    #-----------------------------
    echo "grub.conf generate"

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

    menuentry "MobilCard OS based on Gentoo GNU/Linux" {
        insmod gzio
        insmod mdraid1x
        insmod ext2
        insmod part_gpt

        linux /boot/vmlinuz rd.auto rd.md=1 rd.lvm=0 rd.dm=0 rd.multipath=0 domdadm root=LABEL=ROOT ro
        initrd /boot/initramfs
    }
EOF

    echo "---Grub switch finished correctly---"
    echo "---Exit from switch to UEFI---"
    exit 0
}


###MAIN PART WITH OPTS###
#
while getopts "d:ch" OPTION ; do
    case $OPTION in
    c) CREATE_VAR="1";;
	d) NEW_VFAT_DISK=$OPTARG;;
	h) usage; exit 0;;	
	?) echo "WRONG OPTION: " $OPTION; usage; exit 1;;
    esac
done

shift $(($OPTIND-1))
if [[ -n "$1" ]] 
then
    COMMAND=$1
fi

case "$COMMAND" in
    "help")
	    usage; exit 0;;    
    "install")
    	echo "---Start grub switch to UEFI---";
        check_root_priv;
        check_old_boot_type;
        root_partition;
        if [ ! $CREATE_VAR ] 
        then
            if [ ! $NEW_VFAT_DISK ] 
            then
                echo "Args error";
                usage;
                exit 1;
            fi
            update_Grub_Without_creating_disk;
        else 
            update_Grub_Creating_Disk;
        fi
	
    	echo "---Grub switch finished correctly---";
        echo "---Exit from switch to UEFI---";
        exit 0;;
    *)
	    echo "Unknown command: $COMMAND";
	    usage;
	    exit 1;;	
esac
