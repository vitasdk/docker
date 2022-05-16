# First stage of Dockerfile
FROM ubuntu:latest

RUN apt update && \
        apt install -y software-properties-common && \
        apt update && \
        apt install -y build-essential libssl-dev cmake cmake-data git \
                python2 curl rsync fakeroot texinfo texinfo libtool-bin \
                libarchive-tools autoconf sudo pkg-config sudo xutils-dev

ADD scripts/download_sdk.sh /scripts/download_sdk.sh
ADD scripts/last_built_toolchain.py /scripts/last_built_toolchain.py

RUN cd /scripts && chmod +x *

RUN mkdir -p /sdk

RUN /scripts/download_sdk.sh

ARG USER=vitasdk
ENV HOME /home/$USER

# add new user
RUN adduser $USER \
        && echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER \
        && chmod 0440 /etc/sudoers.d/$USER \
        && mkdir -p $HOME \
        && chown -R $USER $HOME

RUN chown -R $USER /sdk
USER $USER

ENV VITASDK /sdk/vitasdk/
ENV PATH ${VITASDK}/bin:$PATH

WORKDIR $HOME

RUN git clone https://github.com/vitasdk/packages

ENV NVM_DIR "$HOME/.nvm"
ENV NODE_VERSION 14.17.5

# Install nvm with node and npm
RUN curl https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash \
    && . $NVM_DIR/nvm.sh \
    && nvm install $NODE_VERSION \
    && nvm alias default $NODE_VERSION \
    && nvm use default

ENV NODE_PATH $NVM_DIR/v$NODE_VERSION/lib/node_modules
ENV PATH      $NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH

ADD scripts/create-matrix.js /scripts/create-matrix.js

RUN cd packages && node /scripts/create-matrix.js non_dependant | bash
RUN cd packages && node /scripts/create-matrix.js dependant | bash

# Second stage of Dockerfile
FROM ubuntu:latest

RUN apt update && \
    apt install -y software-properties-common && \
    apt update && \
    apt install -y build-essential cmake cmake-data git python2 curl \
        fakeroot libtool-bin libarchive-tools zip && \
    rm -rf /var/lib/apt/lists/*

ENV VITASDK /home/user/vitasdk
ENV PATH ${VITASDK}/bin:$PATH

COPY --from=0 /sdk/vitasdk ${VITASDK}
