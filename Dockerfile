FROM --platform=linux/amd64 ubuntu:20.04

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential libz-dev

ADD . /velvet
WORKDIR /velvet
RUN make -j8
