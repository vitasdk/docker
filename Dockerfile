FROM vitasdk/buildscripts:latest

RUN apk update 

RUN apk add git curl bash

RUN git clone https://github.com/vitasdk/vdpm.git --depth=1 && \
    cd vdpm/ && chmod +x ./*.sh && \
    ./install-all.sh && cd .. && rm -fr vdpm/

# Second stage of Dockerfile
FROM vitasdk/buildscripts:latest  

RUN apk add --no-cache bash make pkgconf curl fakeroot libarchive-tools file xz &&\
	adduser -s /bin/bash -D user &&\
	echo 'export VITASDK=/home/user/vitasdk' >> /home/user/.bashrc &&\
	echo 'export PATH=$PATH:$VITASDK/bin' >> /home/user/.bashrc &&\
	ln -s /home/user/.bashrc /home/user/.bash_profile
COPY --from=0 --chown=user ${VITASDK} ${VITASDK}
