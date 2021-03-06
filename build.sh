#!/bin/sh -ex
# Build a Xen/Ubuntu image for a Cubieboard2

# sudo apt-get install kpartx sfdisk curl
IMG=${BOARD}.img
rm -f $IMG
qemu-img create $IMG 2G
parted ${IMG} --script -- mklabel msdos
parted ${IMG} --script -- mkpart primary fat32 2048s 264191s
parted ${IMG} --script -- mkpart primary ext4 264192s -1s
# Note: ext4 start sector MUST match value in templates/init.d/1st-boot

#printf ",32,C,*\n,4096,L\n,,8e\n\n\n" | sfdisk -uM -D $IMG
# cleanup loops
for loop in $(losetup -j ${IMG}); do
  loop_dev=$(echo $loop|cut -d ":" -f 1)
  umount $loop_dev || true
  losetup -d $loop_dev || true
done
losetup -f ${IMG}
LOOPDEV=$(losetup -j ${IMG} -o 0 | cut -d ":" -f 1)

# Create partition table
dd if=u-boot-sunxi/build-${BOARD}/u-boot-sunxi-with-spl.bin of=${LOOPDEV} bs=1024 seek=8
SIZE=`fdisk -l ${LOOPDEV} | grep Disk | grep bytes | awk '{print $5}'`
CYLINDERS=`echo $SIZE/255/63/512 | bc`
WRKDIR=`pwd`

finish () {
  cd ${WRKDIR}
  sleep 5
  umount /mnt/proc || true
  umount /mnt/dev || true
  umount /mnt || true
  kpartx -d ${LOOPDEV} || true
  losetup -d ${LOOPDEV} || true
}

trap finish EXIT

MLOOPDEV=`echo $LOOPDEV | sed -e 's,/dev/,/dev/mapper/,g'`
kpartx -avs ${LOOPDEV}
mkfs.vfat ${MLOOPDEV}p1
mkfs.ext4 ${MLOOPDEV}p2

mount ${MLOOPDEV}p1 /mnt
cp boot/boot-${BOARD}.scr /mnt/boot.scr
cp linux/arch/arm/boot/zImage /mnt/vmlinuz
cp linux/arch/arm/boot/dts/sun7i-a20-cubieboard2.dtb /mnt/
cp linux/arch/arm/boot/dts/sun7i-a20-cubietruck.dtb /mnt/
cp xen/xen/xen /mnt/
umount /mnt

mount ${MLOOPDEV}p2 /mnt
tar -C /mnt -xf $ROOTFS
cd /mnt
mv binary/* .
rmdir binary
rsync -av ${WRKDIR}/linux-arm-modules/ /mnt/
chown -R root:root /mnt/lib/modules/
cp ${WRKDIR}/templates/fstab etc/fstab
cp ${WRKDIR}/templates/interfaces etc/network/interfaces
rm -f etc/resolv.conf
cp ${WRKDIR}/templates/resolv.conf etc/resolv.conf
cp ${WRKDIR}/templates/hvc0.conf etc/init
cp --preserve=mode ${WRKDIR}/templates/init.d/1st-boot etc/init.d/
ln -s ../init.d/1st-boot etc/rcS.d/S10firstboot
mkdir -p lib/firmware
for f in ${FIRMWARE}; do
	cp -av "${WRKDIR}/linux-firmware/$f" lib/firmware
done

# Copy kernel to dom0 so it can be used in guests
cp ${WRKDIR}/linux/arch/arm/boot/zImage /mnt/root/dom0_kernel
# Copy example scripts to /root
cp -av ${WRKDIR}/templates/scripts /mnt/root


# Prevent services from starting while we build the image
echo 'exit 101' > usr/sbin/policy-rc.d
chmod a+x usr/sbin/policy-rc.d

mount -o bind /proc /mnt/proc
mount -o bind /dev /mnt/dev

echo "deb http://ppa.launchpad.net/avsm/ocaml41+opam12/ubuntu trusty main" > /mnt/etc/apt/sources.list.d/ppa-opam.list
chown root /mnt/etc/apt/sources.list.d/ppa-opam.list

chroot /mnt apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 5B2D0C5561707B09

echo "deb http://ports.ubuntu.com/ubuntu-ports/ trusty-updates main universe 
deb-src http://ports.ubuntu.com/ubuntu-ports/ trusty-updates main universe
deb http://ports.ubuntu.com/ubuntu-ports/ trusty-security main universe
deb-src http://ports.ubuntu.com/ubuntu-ports/ trusty-security main universe" | chroot /mnt tee -a /etc/apt/sources.list > /dev/null

chroot /mnt apt-get -y update
chroot /mnt apt-get -y upgrade
chroot /mnt apt-get -y install openssh-server ocaml ocaml-native-compilers camlp4-extra opam build-essential lvm2 aspcud pkg-config m4 libssl-dev libffi-dev parted avahi-daemon libnss-mdns iw batctl --no-install-recommends
chroot /mnt apt-get -y install libxml2-dev libdevmapper-dev libpciaccess-dev libnl-dev libgnutls-dev --no-install-recommends
chroot /mnt apt-get -y install tcpdump telnet nmap tshark tmux locate hping3 traceroute man-db --no-install-recommends
chroot /mnt apt-get -y install uuid-dev libxen-dev software-properties-common --no-install-recommends
chroot /mnt apt-get -y clean

rm usr/sbin/policy-rc.d

echo UseDNS no >> etc/ssh/sshd_config

# Hostname
sed -i "s/linaro-developer/$BOARD/" etc/hosts
echo $BOARD > etc/hostname

# Mirage user
chroot /mnt userdel -r linaro
chroot /mnt useradd -s /bin/bash -G admin -m mirage -p mljnMhCVerQE6	# Password is "mirage"
sed -i "s/linaro-developer/$BOARD/" etc/hosts

# Xen fixes
chroot /mnt mkdir -p /usr/include/xen/arch-arm/hvm
chroot /mnt touch /usr/include/xen/arch-arm/hvm/save.h
sed -i '/modprobe xen-gntdev/a modprobe xen-gntalloc' /mnt/etc/init.d/xen

# OPAM init - disabled for now
#OPAM_ROOT=/home/mirage/.opam
#OPAM_REPO=/home/mirage/git/opam-repository
#git clone https://github.com/ocaml/opam-repository.git /mnt/${OPAM_REPO}
#chroot /mnt chown -R mirage ${OPAM_REPO}
#chroot /mnt opam init ${OPAM_REPO} -y --root=${OPAM_ROOT}

# chroot /mnt opam repo add mirage https://github.com/mirage/mirage-dev.git --root=${OPAM_ROOT}
# chroot /mnt opam update --root=${OPAM_ROOT} # due to a bug in 1.1.1 (fixed in 1.2)
chroot /mnt chown -R mirage /home/mirage
