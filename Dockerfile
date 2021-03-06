## -*- docker-image-name: "armbuild/scw-app-cozy:latest" -*-
FROM armbuild/scw-distrib-ubuntu:trusty
MAINTAINER Scaleway <opensource@scaleway.com> (@scaleway)


# Prepare rootfs for image-builder
RUN /usr/local/sbin/builder-enter


# Install Cozy tools and dependencies.
RUN echo "deb http://ppa.launchpad.net/nginx/stable/ubuntu trusty main" >> /etc/apt/sources.list \
 && apt-key adv --keyserver keyserver.ubuntu.com --recv-keys C300EE8C \
 && apt-get update -q \
 && apt-get upgrade -q -y \
 && apt-get install -q -y \
    build-essential \
    couchdb \
    curl \
    git \
    imagemagick \
    language-pack-en \
    libssl-dev \
    libxml2-dev \
    libxslt1-dev \
    lsof \
    nginx \
    postfix \
    pwgen \
    python-dev \
    python-pip \
    python-setuptools \
    python-software-properties \
    software-properties-common \
    sqlite3 \
    wget \
 && apt-get clean
RUN update-locale LANG=en_US.UTF-8
RUN pip install \
  supervisor \
  virtualenv


# Install Node and NPM
ENV NODE_VERSION 0.10.38
ENV NPM_VERSION 2.11.1
RUN curl -SLO "http://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION.tar.gz"
RUN tar -xzf "node-v$NODE_VERSION.tar.gz"
RUN cd node-v$NODE_VERSION; ./configure --without-snapshot
RUN cd node-v$NODE_VERSION; make
RUN cd node-v$NODE_VERSION; ./node -e 'console.log("OK");'
RUN cd node-v$NODE_VERSION; make install
RUN rm -rf node-v$NODE_VERSION node-v$NODE_VERSION.tar.gz
RUN npm install -g npm@"$NPM_VERSION" && npm cache clear


# Install CoffeeScript, Cozy Monitor and Cozy Controller via NPM.
RUN npm install -g \
  coffee-script \
  cozy-controller \
  cozy-monitor


# Create Cozy users, without home directories.
RUN useradd -M cozy \
 && useradd -M cozy-data-system \
 && useradd -M cozy-home


# Configure CouchDB.
RUN mkdir /etc/cozy \
 && chown -hR cozy /etc/cozy
RUN pwgen -1 > /etc/cozy/couchdb.login \
 && pwgen -1 >> /etc/cozy/couchdb.login \
 && chown cozy-data-system /etc/cozy/couchdb.login \
 && chmod 640 /etc/cozy/couchdb.login
RUN mkdir /var/run/couchdb \
 && chown -hR couchdb /var/run/couchdb \
 && su - couchdb -c 'couchdb -b' \
 && sleep 5 \
 && while ! curl -s 127.0.0.1:5984; do sleep 5; done \
 && curl -s -X PUT 127.0.0.1:5984/_config/admins/$(head -n1 /etc/cozy/couchdb.login) -d "\"$(tail -n1 /etc/cozy/couchdb.login)\""


# Configure Supervisor.
ADD supervisor/supervisord.conf /etc/supervisord.conf
RUN mkdir -p /var/log/supervisor \
 && chmod 777 /var/log/supervisor \
 && /usr/local/bin/supervisord -c /etc/supervisord.conf


# Install Cozy Indexer.
RUN mkdir -p /usr/local/cozy-indexer \
 && cd /usr/local/cozy-indexer \
 && git clone https://github.com/cozy/cozy-data-indexer.git \
 && cd /usr/local/cozy-indexer/cozy-data-indexer \
 && virtualenv --quiet /usr/local/cozy-indexer/cozy-data-indexer/virtualenv \
 && . ./virtualenv/bin/activate \
 && pip install -r /usr/local/cozy-indexer/cozy-data-indexer/requirements/common.txt \
 && chown -R cozy:cozy /usr/local/cozy-indexer


# Start up background services and install the Cozy platform apps.
ENV NODE_ENV production
RUN su - couchdb -c 'couchdb -b' \
 && sleep 5 \
 && while ! curl -s 127.0.0.1:5984; do sleep 5; done \
 && /usr/local/lib/node_modules/cozy-controller/bin/cozy-controller & sleep 5 \
 && while ! curl -s 127.0.0.1:9002; do sleep 5; done \
 && cd /usr/local/cozy-indexer/cozy-data-indexer \
 && . ./virtualenv/bin/activate \
 && /usr/local/cozy-indexer/cozy-data-indexer/virtualenv/bin/python server.py & sleep 5 \
 && while ! curl -s 127.0.0.1:9102; do sleep 5; done \
 && cozy-monitor install data-system \
 && cozy-monitor install home \
 && cozy-monitor install proxy


# Configure Nginx and check its configuration by restarting the service.
ADD nginx/nginx.conf /etc/nginx/nginx.conf
ADD nginx/cozy /etc/nginx/sites-available/cozy
ADD nginx/cozy-ssl /etc/nginx/sites-available/cozy-ssl
RUN chmod 0644 /etc/nginx/sites-available/cozy /etc/nginx/sites-available/cozy-ssl \
 && rm /etc/nginx/sites-enabled/default \
 && ln -s /etc/nginx/sites-available/cozy /etc/nginx/sites-enabled/cozy
RUN nginx -t


# Configure Postfix with default parameters.
# TODO: Change mydomain.net?
RUN echo "postfix postfix/mailname string mydomain.net" | debconf-set-selections \
 && echo "postfix postfix/main_mailer_type select Internet Site" | debconf-set-selections \
 && echo "postfix postfix/destinations string mydomain.net, localhost.localdomain, localhost " | debconf-set-selections \
 && postfix check


# Import Supervisor configuration files.
ADD supervisor/cozy-controller.conf /etc/supervisor/conf.d/cozy-controller.conf
ADD supervisor/cozy-indexer.conf /etc/supervisor/conf.d/cozy-indexer.conf
ADD supervisor/cozy-init.conf /etc/supervisor/conf.d/cozy-init.conf
ADD supervisor/couchdb.conf /etc/supervisor/conf.d/couchdb.conf
ADD supervisor/nginx.conf /etc/supervisor/conf.d/nginx.conf
ADD supervisor/postfix.conf /etc/supervisor/conf.d/postfix.conf
ADD cozy-init /etc/init.d/cozy-init
RUN chmod 0644 /etc/supervisor/conf.d/*


# Clean APT cache for a lighter image.
RUN apt-get clean \
 && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*


EXPOSE 80 443


# Clean rootfs from image-builder
RUN /usr/local/sbin/builder-leave
