FROM vitasdk/buildscripts:latest

RUN apk update 

RUN apk add git curl bash

RUN git clone https://github.com/vitasdk/vdpm.git --depth=1 && \
    cd vdpm/ && chmod +x ./*.sh && \
    ./install-all.sh && cd .. && rm -fr vdpm/

# Second stage of Dockerfile
FROM vitasdk/buildscripts:latest  

COPY --from=0 ${VITASDK} ${VITASDK}

ARG USER=vitasdk
ENV HOME /home/$USER

# install sudo as root
RUN apk add --no-cache sudo

# add new user
RUN adduser -D $USER \
        && echo "$USER ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/$USER \
        && chmod 0440 /etc/sudoers.d/$USER

USER $USER
WORKDIR $HOME