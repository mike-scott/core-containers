#!/bin/bash
#
# Copyright (c) 2018 Open Source Foundries Ltd.
# SPDX-License-Identifier: Apache-2.0
#
# Script to publish and sign a pre-built OSTree repository to an OTA+ server.
#

set -e

function usage() {
	cat << EOF >&2
usage: $(basename $0) options

OPTIONS:
	-c	OTA+ credentials zip file (e.g. credentials.zip)
	-h	Shows this message
	-m	Name for the machine target in OTA+ (e.g. raspberrypi3-64)
	-v	Optional version to add to the image information
	-u	Optional url to add to the image information
	-r	OSTree repository (e.g. ostree_repo directory or ostree_repo.tar.bz2 archive)
EOF
}

function error() {
	echo "ERROR: $@"
	exit -1
}

function fail() {
	usage
	exit -1
}

function get_opts() {
	declare -r optstr="c:m:r:u:v:h"
	while getopts ${optstr} opt; do
		case ${opt} in
			c) credentials=${OPTARG} ;;
			m) machine=${OPTARG} ;;
			r) ostree_repo=${OPTARG} ;;
			u) url=${OPTARG} ;;
			v) version=${OPTARG} ;;
			h) usage; exit 0 ;;
			*) fail ;;
		esac
	done

	if [ -z "${credentials}" ] || [ -z "${machine}" ] ||
		[ -z "${ostree_repo}" ]; then
		fail
	fi
}

get_opts $@

if [ ! -f "${credentials}" ]; then
	error "Credentials ${credentials} file not found"
fi

if [ -d "${ostree_repo}" ]; then
	if [ ! -f "${ostree_repo}/config" ]; then
		error "directory is not a valid OSTree repo: ${ostree_repo}"
	fi
elif [ -f "${ostree_repo}" ]; then
	echo "Validating OSTree archive"
	if tar -tvjf ${ostree_repo} ostree_repo/config >/dev/null 2>&1; then
		echo "Decompressing OSTree repository"
		tmpdir=$(mktemp -d)
		tar -jxf ${ostree_repo} --totals --checkpoint=.1000 -C ${tmpdir}
		ostree_repo=${tmpdir}/ostree_repo
	else
		error "file is not a valid OSTree repo: $ostree_repo"
	fi
fi

ostree_branch=$(ostree refs --repo ${ostree_repo})
ostree_hash=$(cat ${ostree_repo}/refs/heads/${ostree_branch})
version="${version-${ostree_hash}}"
url="${url-http://example.com}"
tufrepo=$(mktemp -u -d)
otarepo=$(mktemp -u -d)

echo "Publishing OSTree branch ${ostree_branch} hash ${ostree_hash} to treehub"
garage-push --repo ${ostree_repo} --ref ${ostree_branch} --credentials ${credentials}

echo "Initializing local TUF repository"
garage-sign init --repo ${tufrepo} --home-dir ${otarepo} --credentials ${credentials}

echo "Pulling TUF targets from the remote TUF repository"
garage-sign targets pull --repo ${tufrepo} --home-dir ${otarepo}

echo "Adding OSTree target to the local TUF repository"
garage-sign targets add --repo ${tufrepo} --home-dir ${otarepo} --name ${ostree_branch} \
	--format OSTREE --version "${version}" --length 0 --url "${url}" \
	--sha256 ${ostree_hash} --hardwareids ${machine}

echo "Signing local TUF targets"
garage-sign targets sign --repo ${tufrepo} --home-dir ${otarepo} --key-name targets

echo "Publishing local TUF targets to the remote TUF repository"
garage-sign targets push --repo ${tufrepo} --home-dir ${otarepo}

echo "Verifying remote OSTree + TUF repositories"
garage-check --ref ${ostree_hash} --credentials ${credentials}

echo "Cleaning up local TUF repository"
rm -rf ${tufrepo} ${otarepo}

echo "Local OSTree repository successfully published to the remote OTA+ treehub / TUF repositories"
