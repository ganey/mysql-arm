FROM debian:buster-slim

RUN groupadd -r mysql && useradd -r -g mysql mysql

RUN apt-get update && apt-get install -y --no-install-recommends gnupg dirmngr && rm -rf /var/lib/apt/lists/*

# add gosu for easy step-down from root
# https://github.com/tianon/gosu/releases
ENV GOSU_VERSION 1.14
RUN set -eux; \
	savedAptMark="$(apt-mark showmanual)"; \
	apt-get update; \
	apt-get install -y --no-install-recommends ca-certificates wget; \
	rm -rf /var/lib/apt/lists/*; \
	dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
	wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
	wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
	gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
	apt-mark auto '.*' > /dev/null; \
	[ -z "$savedAptMark" ] || apt-mark manual $savedAptMark > /dev/null; \
	apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
	chmod +x /usr/local/bin/gosu; \
	gosu --version; \
	gosu nobody true

RUN mkdir /docker-entrypoint-initdb.d && mkdir /etc/mysql && mkdir /etc/mysql/conf.d

RUN set -eux; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		openssl \
# FATAL ERROR: please install the following Perl modules before executing /usr/local/mysql/scripts/mysql_install_db:
# File::Basename
# File::Copy
# Sys::Hostname
# Data::Dumper
		perl \
		xz-utils \
		zstd \
	; \
	rm -rf /var/lib/apt/lists/*

RUN set -eux; \
# gpg: key 3A79BD29: public key "MySQL Release Engineering <mysql-build@oss.oracle.com>" imported
	key='859BE8D7C586F538430B19C2467B942D3A79BD29'; \
	export GNUPGHOME="$(mktemp -d)"; \
	gpg --batch --keyserver keyserver.ubuntu.com --recv-keys "$key"; \
	mkdir -p /etc/apt/keyrings; \
	gpg --batch --export "$key" > /etc/apt/keyrings/mysql.gpg; \
	gpgconf --kill all; \
	rm -rf "$GNUPGHOME"

ENV MYSQL_MAJOR 5.7

# now build from source
RUN echo "deb http://ftp.uk.debian.org/debian buster main" >> /etc/apt/sources.list

# build in single step so image doesn't end up really big
RUN set -eux; \
    apt-get update; \
    apt-get install cmake bison gcc wget unzip g++ libssl-dev libncurses-dev pkg-config libatomic1 -y; \
    wget "https://github.com/mysql/mysql-server/archive/refs/heads/${MYSQL_MAJOR}.zip" -O /tmp/mysql.zip && cd /tmp && unzip mysql.zip; \
    wget "http://sourceforge.net/projects/boost/files/boost/1.59.0/boost_1_59_0.tar.gz" -O /tmp/boost.tar.gz && cd /tmp && tar -xvf boost.tar.gz && mv boost_1_59_0 boost; \
    cd /tmp/mysql-server-${MYSQL_MAJOR} && cmake . -DCMAKE_INSTALL_PREFIX=/usr/local/mysql \
                     -DMYSQL_DATADIR=/var/lib/mysql \
                     -DSYSCONFDIR=/etc \
                     -DEXTRA_CHARSETS=all \
                     -DENABLE_DOWNLOADS=1 \
                     -DWITH_BOOST=/tmp/boost \
                     -DWITH_SSL=system; \
    cd /tmp/mysql-server-${MYSQL_MAJOR} && make && make install; \
    apt-get remove cmake bison gcc wget unzip g++ libssl-dev pkg-config -y; \
    # cleanup
    apt-get purge -y --auto-remove; \
    rm -Rf /tmp/*

# the "/var/lib/mysql" stuff here is because the mysql-server postinst doesn't have an explicit way to disable the mysql_install_db codepath besides having a database already "configured" (ie, stuff in /var/lib/mysql/mysql)
# also, we set debconf keys to make APT a little quieter
RUN set -eux; \
# comment out a few problematic configuration values
	find /etc/mysql/ -name '*.cnf' -print0 \
		| xargs -0 grep -lZE '^(bind-address|log)' \
		| xargs -rt -0 sed -Ei 's/^(bind-address|log)/#&/' \
# don't reverse lookup hostnames, they are usually another container
	&& echo '[mysqld]\nskip-host-cache\nskip-name-resolve' > /etc/mysql/conf.d/docker.cnf \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/lib/mysql && mkdir -p /var/lib/mysql /var/run/mysqld \
	&& chown -R mysql:mysql /var/lib/mysql /var/run/mysqld \
# ensure that /var/run/mysqld (used for socket and lock files) is writable regardless of the UID our mysqld instance ends up having at runtime
	&& chmod 1777 /var/run/mysqld /var/lib/mysql

# remove stuff we don't need
#RUN apt-get remove cmake bison gcc wget unzip g++ libssl-dev pkg-config -y
#
## cleanup
#RUN apt-get purge -y --auto-remove
#RUN rm -Rf /tmp/*

ENV PATH="/usr/local/mysql/bin:$PATH"

VOLUME /var/lib/mysql

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
RUN ln -s usr/local/bin/docker-entrypoint.sh /entrypoint.sh # backwards compat
ENTRYPOINT ["docker-entrypoint.sh"]

EXPOSE 3306 33060
CMD ["mysqld"]
