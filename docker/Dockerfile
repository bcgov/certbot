# cat Dockerfile | oc new-build -D - --name=certbot
ARG PYTHON_VERSION=3.12-alpine
FROM docker.io/python:${PYTHON_VERSION}

ARG CERTBOT_VERSION=3
ARG OCP_VERSION=stable-4.18
ARG APP_ROOT=/usr/local/bin

ENV PYTHONUNBUFFERED=1
WORKDIR ${APP_ROOT}

# Install Prerequisites
RUN apk add --no-cache bash gcompat py3-setuptools \
 && rm -rf /var/cache/apk/*

# Install Certbot
# CERTBOT_VERSION: Major version constraint for Certbot (e.g., "3" for 3.x)
RUN apk add --no-cache --virtual certbot-build gcc libc-dev libffi-dev openssl-dev \
 && pip install --no-cache-dir --upgrade pip setuptools wheel \
 && pip install --no-cache-dir "certbot>=${CERTBOT_VERSION},<$((CERTBOT_VERSION+1))" \
 && certbot --version \
 && certbot --help paths \
 && apk del certbot-build \
 && rm -rf /var/cache/apk/*

# Install Openshift CLI
# OCP_VERSION: OpenShift client stream (e.g., "stable-4.18", "stable-4.19")
RUN apk add --no-cache --virtual oc-build curl tar \
 && curl -sfL "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${OCP_VERSION}/openshift-client-linux.tar.gz" | tar -zxvf - -C ${APP_ROOT} \
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
