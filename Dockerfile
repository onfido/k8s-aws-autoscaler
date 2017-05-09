FROM alpine:3.5

RUN apk add --update curl bash jq python py-pip bc \
    && pip install --upgrade pip \
    && pip install awscli \
    && rm -rf /var/cache/apk/*

RUN cd /usr/local/bin \
    && curl -O https://storage.googleapis.com/kubernetes-release/release/v1.6.2/bin/linux/amd64/kubectl \
    && chmod 755 /usr/local/bin/kubectl

COPY autoscale.sh /bin/autoscale.sh
RUN chmod +x /bin/autoscale.sh

CMD ["bash", "/bin/autoscale.sh"]
