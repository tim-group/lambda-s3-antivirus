FROM debian:latest

RUN apt update && apt install -y clamav
RUN mkdir /tmp/clamav-work && chown clamav:clamav /tmp/clamav-work
COPY freshclam.conf /etc/local-freshclam.conf
