FROM vitasdk/buildscripts:latest

RUN apk update 

RUN apk add git curl bash

RUN git clone https://github.com/vitasdk/vdpm.git --depth=1 && \
    cd vdpm/ && chmod +x ./*.sh && \
    ./install-all.sh && cd .. && rm -fr vdpm/

# Second stage of Dockerfile
FROM vitasdk/buildscripts:latest  

RUN apk add --no-cache bash make pkgconf curl fakeroot libarchive-tools file xz cmake sudo &&\
    adduser -D user &&\
    echo "export VITASDK=${VITASDK}" > /etc/profile.d/vitasdk.sh && \
    echo 'export PATH=$PATH:$VITASDK/bin'  >> /etc/profile.d/vitasdk.sh
COPY --from=0 --chown=user ${VITASDK} ${VITASDK}
