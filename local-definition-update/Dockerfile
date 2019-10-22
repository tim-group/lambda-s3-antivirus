FROM debian:latest

RUN apt-get update && apt-get install -y clamav
RUN mkdir /tmp/clamav-work && chown clamav:clamav /tmp/clamav-work
COPY freshclam.conf /etc/local-freshclam.conf
