#!/usr/bin/env bash
set -e
LAMBDA_FILE="lambda.zip"

rm -f ${LAMBDA_FILE}

cleanup() {
    echo "-- Cleaning up --"
    docker stop s3-antivirus-builder || true
    docker rm s3-antivirus-builder || true
    docker stop s3-antivirus-sanitycheck || true
    docker rm s3-antivirus-sanitycheck || true
    rm -rf bin clamav clamav_check
}
trap 'cleanup' EXIT

echo "-- Downloading AmazonLinux container --"
mkdir -p clamav
docker pull amazonlinux
docker create -it --network host -v ${PWD}/clamav:/home/docker  --name s3-antivirus-builder amazonlinux
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
docker exec -w /home/docker s3-antivirus-builder /bin/sh -c "chmod -R a+w ."

echo "-- Copying the executables and required libraries --"
mkdir ./bin
cp clamav/usr/bin/clamscan clamav/usr/bin/freshclam clamav/usr/lib64/* bin/.
cp -R ./s3-antivirus/* bin/.
pushd ./bin
zip -r9 ${LAMBDA_FILE} *
popd
cp bin/${LAMBDA_FILE} .

echo "-- Verifying shared libraries --"
mkdir -p clamav_check
unzip -d clamav_check ${LAMBDA_FILE}

docker create -it --network host -v ${PWD}/clamav_check:/home/docker --name s3-antivirus-sanitycheck amazonlinux
docker start s3-antivirus-sanitycheck

docker exec -w /home/docker s3-antivirus-sanitycheck /bin/sh -c "LD_LIBRARY_PATH=. ldd ./clamscan ./freshclam"
docker exec -w /home/docker s3-antivirus-sanitycheck /bin/sh -c "LD_LIBRARY_PATH=. ./clamscan --version"
