#!/bin/sh

set -ex

# Create temporary working directory
WORKDIR=$(mktemp -d)
cd ${WORKDIR}

# Create target directory structure with arch-specific subdirectories
TARGET_DIR="/usr/share/ironic-operator/var-lib-ironic"
mkdir -p ${TARGET_DIR}/httpboot/x86_64
mkdir -p ${TARGET_DIR}/tftpboot/x86_64
mkdir -p ${TARGET_DIR}/tftpboot/pxelinux.cfg

# Download boot asset packages for x86_64
mkdir -p ${WORKDIR}/x86_64
cd ${WORKDIR}/x86_64
dnf download ${DOWNLOADS_X64}
dnf clean all

# Extract x86_64 RPMs
for rpm in *.rpm; do
    rpm2cpio ${rpm} | cpio -idmv
done

# Helper: find a file under EFI vendor directories
# Usage: find_efi_file <extract_dir> <filename>
# In RHEL 10, shim installs to EFI/redhat/ and grub to EFI/centos/
find_efi_file() {
    local extract_dir="$1"
    local filename="$2"
    for vendor in redhat centos; do
        local path="${extract_dir}/boot/efi/EFI/${vendor}/${filename}"
        if [ -f "${path}" ]; then
            echo "${path}"
            return
        fi
    done
    echo "ERROR: ${filename} not found under ${extract_dir}/boot/efi/EFI/{redhat,centos}/" >&2
    exit 1
}

# Copy x86_64 iPXE and grub files to arch-specific directories
for dir in httpboot tftpboot; do
    # x86_64 iPXE files
    cp ${WORKDIR}/x86_64/usr/share/ipxe/ipxe-snponly-x86_64.efi ${TARGET_DIR}/${dir}/x86_64/snponly.efi
    cp ${WORKDIR}/x86_64/usr/share/ipxe/undionly.kpxe ${TARGET_DIR}/${dir}/x86_64/undionly.kpxe

    # x86_64 UEFI boot files (shim and grub may be in different EFI vendor dirs)
    cp $(find_efi_file ${WORKDIR}/x86_64 shimx64.efi) ${TARGET_DIR}/${dir}/x86_64/bootx64.efi
    cp $(find_efi_file ${WORKDIR}/x86_64 grubx64.efi) ${TARGET_DIR}/${dir}/x86_64/grubx64.efi
done

# Ensure all files are readable
chmod -R +r ${TARGET_DIR}

# Build x86_64 ESP image
pushd ${TARGET_DIR}/httpboot/x86_64
dd if=/dev/zero of=esp.img bs=4096 count=2048
mkfs.msdos -F 12 -n 'ESP_IMAGE' esp.img

mmd -i esp.img EFI
mmd -i esp.img EFI/BOOT
mcopy -i esp.img -v bootx64.efi ::EFI/BOOT
mcopy -i esp.img -v grubx64.efi ::EFI/BOOT
mdir -i esp.img ::EFI/BOOT
popd

echo "x86_64 ESP image created successfully at ${TARGET_DIR}/httpboot/x86_64/esp.img"

# Create compatibility symlinks in httpboot and tftpboot for backwards compatibility
for dir in httpboot tftpboot; do
    pushd ${TARGET_DIR}/${dir}
    ln -sf x86_64/snponly.efi snponly.efi
    ln -sf x86_64/undionly.kpxe undionly.kpxe
    if [ -f "x86_64/ipxe.lkrn" ]; then
        ln -sf x86_64/ipxe.lkrn ipxe.lkrn
    fi
    ln -sf x86_64/bootx64.efi bootx64.efi
    ln -sf x86_64/grubx64.efi grubx64.efi
    if [ "${dir}" = "httpboot" ]; then
        ln -sf x86_64/esp.img esp.img
    fi
    popd
done

echo "Compatibility symlinks created in ${TARGET_DIR}/httpboot and ${TARGET_DIR}/tftpboot"

# Clean up
cd /
rm -rf ${WORKDIR}

echo "Boot assets extracted successfully to ${TARGET_DIR}"
