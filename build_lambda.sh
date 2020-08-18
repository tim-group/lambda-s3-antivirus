#!/usr/bin/env bash
set -e
LAMBDA_FILE="lambda.zip"

rm -f ${LAMBDA_FILE}

mkdir -p clamav

echo "-- Downloading AmazonLinux container --"
docker pull amazonlinux
docker create -i -t -v ${PWD}/clamav:/home/docker  --name s3-antivirus-builder amazonlinux
docker start s3-antivirus-builder

echo "-- Updating, downloading and unpacking clamAV and ClamAV update --"
docker exec -w /home/docker s3-antivirus-builder yum install -y cpio yum-utils
docker exec -w /home/docker s3-antivirus-builder amazon-linux-extras install -y epel
docker exec -w /home/docker s3-antivirus-builder yumdownloader -x \*i686 --archlist=x86_64 clamav clamav-lib clamav-update json-c pcre2 libtool-ltdl
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "echo 'folder content' && ls -la"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "rpm2cpio clamav-0*.rpm | cpio -idmv"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "rpm2cpio clamav-lib*.rpm | cpio -idmv"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "rpm2cpio clamav-update*.rpm | cpio -idmv"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "rpm2cpio json-c*.rpm | cpio -idmv"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "rpm2cpio pcre2*.rpm | cpio -idmv"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "rpm2cpio libtool-ltdl*.rpm | cpio -idmv"

docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "cp -v /lib64/libxml2.so* usr/lib64"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "cp -v /lib64/libbz2.so* usr/lib64"
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "cp -v /lib64/liblzma.so* usr/lib64"

docker stop s3-antivirus-builder
docker rm s3-antivirus-builder

mkdir ./bin

echo "-- Copying the executables and required libraries --"
cp clamav/usr/bin/clamscan clamav/usr/bin/freshclam clamav/usr/lib64/* bin/.

echo "-- Cleaning up ClamAV folder --"
sudo rm -rf clamav

cp -R ./s3-antivirus/* bin/.

pushd ./bin
zip -r9 ${LAMBDA_FILE} *
popd

cp bin/${LAMBDA_FILE} .

echo "-- Cleaning up bin folder --"
sudo rm -rf bin

echo "-- Verifying shared libraries --"
mkdir -p clamav
unzip -d clamav ${LAMBDA_FILE}

docker create -i -t -v ${PWD}/clamav:/home/docker --name s3-antivirus-sanitycheck amazonlinux
docker start s3-antivirus-sanitycheck

cleanup() {
    docker stop s3-antivirus-sanitycheck
    docker rm s3-antivirus-sanitycheck
    sudo rm -rf clamav
}

trap 'cleanup' EXIT

docker exec -w /home/docker s3-antivirus-sanitycheck /bin/sh -c "LD_LIBRARY_PATH=. ldd ./clamscan ./freshclam"
docker exec -w /home/docker s3-antivirus-sanitycheck /bin/sh -c "LD_LIBRARY_PATH=. ./clamscan --version"
