# cat Dockerfile | oc new-build -D - --name=certbot
FROM docker.io/python:3.12-alpine
ENV PYTHONUNBUFFERED=1
ARG APP_ROOT=/usr/local/bin
WORKDIR ${APP_ROOT}

# Install Prerequisites
RUN apk add --no-cache bash gcompat py3-setuptools \
 && rm -rf /var/cache/apk/*

# Install Certbot
RUN apk add --no-cache --virtual certbot-build gcc libc-dev libffi-dev openssl-dev \
 && pip install --no-cache-dir --upgrade pip setuptools wheel \
 && pip install --no-cache-dir 'certbot>=3,<4' \
 && certbot --version \
 && certbot --help paths \
 && apk del certbot-build \
 && rm -rf /var/cache/apk/*

# Install Openshift CLI
RUN apk add --no-cache --virtual oc-build curl tar \
 && curl -sfL https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.18/openshift-client-linux.tar.gz | tar -zxvf - -C ${APP_ROOT} \
 && apk del oc-build \
 && rm -rf /var/cache/apk/*

# Copy Scripts & Setup Folders
COPY entrypoint.sh ${APP_ROOT}/entrypoint.sh
RUN chmod ugo+x ${APP_ROOT}/entrypoint.sh \
 && mkdir -p /var/log/letsencrypt \
 && chgrp -R 0 /var/log/letsencrypt \
 && chmod -R ugo+rwX /var/log/letsencrypt \
 && mkdir -p /var/lib/letsencrypt \
 && chgrp -R 0 /var/lib/letsencrypt \
 && chmod -R ugo+rwX /var/lib/letsencrypt \
 && mkdir -p /etc/letsencrypt \
 && chgrp -R 0 /etc/letsencrypt \
 && chmod -R ugo+rwX /etc/letsencrypt

CMD [ "./entrypoint.sh" ]
