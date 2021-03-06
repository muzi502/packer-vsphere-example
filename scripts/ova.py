#!/usr/bin/env python3

# Copyright 2019 The Kubernetes Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

################################################################################
# usage: image-build-ova.py [FLAGS] ARGS
#  This program builds an OVA file from a VMDK and manifest file generated as a
#  result of a Packer build.
################################################################################

import argparse
import hashlib
import io
import json
import os
import subprocess
from string import Template
import tarfile

def main():
    parser = argparse.ArgumentParser(
        description="Builds an OVA using the artifacts from a Packer build")
    parser.add_argument('--vmx',
                        dest='vmx_version',
                        default='15',
                        help='The virtual hardware version')
    parser.add_argument('--ovf_template',
                        nargs='?',
                        metavar='OVF_TEMPLATE',
                        default='./ovf_template.xml',
                        help='XML template to build OVF')
    parser.add_argument('--vmdk_file',
                        nargs='?',
                        metavar='FILE',
                        default=None,
                        help='Use FILE as VMDK instead of reading from manifest. '
                             'Must be in BUILD_DIR')
    parser.add_argument('--build_dir',
                        dest='build_dir',
                        nargs='?',
                        metavar='BUILD_DIR',
                        default='.',
                        help='The Packer build directory')
    args = parser.parse_args()

    # Read in the OVF template
    ovf_template = ""
    with io.open(args.ovf_template, 'r', encoding='utf-8') as f:
        ovf_template = f.read()

    # Change the working directory if one is specified.
    os.chdir(args.build_dir)
    print("image-build-ova: cd %s" % args.build_dir)

    # Load the packer manifest JSON
    data = None
    with open('packer-manifest.json', 'r') as f:
        data = json.load(f)

    # Get the first build.
    build = data['builds'][0]
    build_data = build['custom_data']

    if args.vmdk_file is None:
        # Get a list of the VMDK files from the packer manifest.
        vmdk_files = get_vmdk_files(build['files'])
    else:
        vmdk_files = [{"name": args.vmdk_file, "size": os.path.getsize(args.vmdk_file)}]

    for f in vmdk_files:
        f['stream_name'] = f['name']
        f['stream_size'] = os.path.getsize(f['name'])
    vmdk = vmdk_files[0]

    OS_id_map = {"vmware-photon-64": {"id": "36", "version": "", "type": "vmwarePhoton64Guest"},
                "centos7-64": {"id": "107", "version": "7", "type": "centos7-64"}}

    # Create the OVF file.
    data = {
        'BUILD_DATE': build_data['build_date'],
        'ARTIFACT_ID': build['artifact_id'],
        'BUILD_TIMESTAMP': build_data['build_timestamp'],
        'OS_NAME': build_data['os_name'],
        'OS_ID': OS_id_map[build_data['guest_os_type']]['id'],
        'OS_TYPE': OS_id_map[build_data['guest_os_type']]['type'],
        'OS_VERSION': OS_id_map[build_data['guest_os_type']]['version'],
        'CPU': build_data['cpu'],
        'MEMORY': build_data['memory'],
        'DISK_NAME': vmdk['stream_name'],
        'DISK_SIZE': build_data['disk_size'],
        'POPULATED_DISK_SIZE': vmdk['size'],
        'STREAM_DISK_SIZE': vmdk['stream_size'],
        'VMX_VERSION': args.vmx_version,
        'DISTRO_NAME': build_data['distro_name'],
        'DISTRO_VERSION': build_data['distro_version'],
        'DISTRO_ARCH': build_data['distro_arch'],
        'NESTEDHV': "false",
        'FIRMWARE': build_data['firmware'],
    }

    ovf = "%s-%s.ovf" % (build_data['build_name'], build_data['release_version'])
    mf = "%s-%s.mf" % (build_data['build_name'], build_data['release_version'])
    ova = "%s-%s.ova" % (build_data['build_name'], build_data['release_version'])

    # Create OVF
    create_ovf(ovf, data, ovf_template)

    # Create the OVA manifest.
    create_ova_manifest(mf, [ovf, vmdk['stream_name']])

    # Create the OVA
    create_ova(ova, ovf, ova_files=[mf,vmdk['stream_name']])


def sha256(path):
    m = hashlib.sha256()
    with open(path, 'rb') as f:
        while True:
            data = f.read(65536)
            if not data:
                break
            m.update(data)
    return m.hexdigest()


def create_ova(ova_path, ovf_path, ova_files=None):
    print("image-build-ova: creating OVA using tar")
    tar_cmd = ['tar', '-c', '-f', ova_path, ovf_path]
    for f in ova_files:
        tar_cmd.append(f)
    subprocess.check_call(tar_cmd)
    print("image-build-ova: %s" % tar_cmd)
    chksum_path = "%s.sha256" % ova_path
    print("image-build-ova: create ova checksum %s" % chksum_path)
    with open(chksum_path, 'w') as f:
        f.write(sha256(ova_path))


def create_ovf(path, data, ovf_template):
    print("image-build-ova: create ovf %s" % path)
    with io.open(path, 'w', encoding='utf-8') as f:
      f.write(Template(ovf_template).substitute(data))


def create_ova_manifest(path, infile_paths):
    print("image-build-ova: create ova manifest %s" % path)
    with open(path, 'w') as f:
        for i in infile_paths:
            f.write('SHA256(%s)= %s\n' % (i, sha256(i)))


def get_vmdk_files(inlist):
    outlist = []
    for f in inlist:
        if f['name'].endswith('.vmdk'):
            outlist.append(f)
    return outlist

if __name__ == "__main__":
    main()
