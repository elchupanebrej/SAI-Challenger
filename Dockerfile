FROM debian:buster-slim

MAINTAINER andriy.kokhan@gmail.com

RUN echo "deb [arch=amd64] http://debian-archive.trafficmanager.net/debian/ buster main contrib non-free" >> /etc/apt/sources.list && \
        echo "deb-src [arch=amd64] http://debian-archive.trafficmanager.net/debian/ buster main contrib non-free" >> /etc/apt/sources.list && \
        echo "deb [arch=amd64] http://debian-archive.trafficmanager.net/debian-security/ buster/updates main contrib non-free" >> /etc/apt/sources.list && \
        echo "deb-src [arch=amd64] http://debian-archive.trafficmanager.net/debian-security/ buster/updates main contrib non-free" >> /etc/apt/sources.list && \
        echo "deb [arch=amd64] http://debian-archive.trafficmanager.net/debian buster-backports main" >> /etc/apt/sources.list

## Make apt-get non-interactive
ENV DEBIAN_FRONTEND=noninteractive

# Install generic packages
RUN apt-get -o Acquire::Check-Valid-Until=false update && apt-get install -y \
        apt-utils \
        vim \
        curl \
        wget \
        iproute2 \
        unzip \
        git \
        procps \
        build-essential \
        graphviz \
        doxygen \
        aspell \
        python3-pip \
        rsyslog \
        supervisor

# Add support for supervisord to handle startup dependencies
RUN pip3 install supervisord-dependent-startup==1.4.0

# Install dependencies
RUN apt-get install -y redis-server libhiredis0.14 python3-redis

# Install sonic-swss-common & sonic-sairedis building dependencies
RUN apt-get install -y \
        make libtool m4 autoconf dh-exec debhelper automake cmake pkg-config \
        libhiredis-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev swig3.0 \
        libpython2.7-dev libgtest-dev libgmock-dev libboost-dev autoconf-archive

RUN apt-get install -y \
        libnl-3-dev libnl-genl-3-dev libnl-route-3-dev libnl-nf-3-dev libzmq3-dev

COPY sai.env /
RUN git clone --recursive https://github.com/Azure/sonic-swss-common \
        && cd sonic-swss-common \
        && . /sai.env \
        && git checkout ${SWSS_COMMON_ID} \
        && ./autogen.sh && ./configure && dpkg-buildpackage -us -uc -b \
        && cd .. \
        && dpkg -i libswsscommon_1.0.0_amd64.deb \
        && dpkg -i libswsscommon-dev_1.0.0_amd64.deb \
        && rm -rf sonic-swss-common \
        && rm -f *swsscommon*

WORKDIR /sai

# Install SAI attributes metadata JSON generator
COPY scripts/gen_attr_list /sai/gen_attr_list
RUN apt-get install -y nlohmann-json-dev

# Install ptf_nn_agent dependencies
RUN apt-get install -y libffi-dev \
        && wget https://github.com/nanomsg/nanomsg/archive/1.0.0.tar.gz \
        && tar xvfz 1.0.0.tar.gz \
        && cd nanomsg-1.0.0 \
        && mkdir -p build \
        && cd build \
        && cmake .. \
        && make install \
        && ldconfig \
        && cd ../.. \
        && rm -rf 1.0.0.tar.gz nanomsg-1.0.0 \
        && pip3 install nnpy

# Update Redis configuration:
# - Enable keyspace notifications as per sonic-swss-common/README.md
# - Do not daemonize redis-server since supervisord will manage it
# - Do not save Redis DB on disk
RUN sed -ri 's/^# unixsocket/unixsocket/' /etc/redis/redis.conf \
        && sed -ri 's/^unixsocketperm .../unixsocketperm 777/' /etc/redis/redis.conf \
        && sed -ri 's/redis-server.sock/redis.sock/' /etc/redis/redis.conf \
        && sed -ri 's/notify-keyspace-events ""/notify-keyspace-events AKE/' /etc/redis/redis.conf \
        && sed -ri 's/^daemonize yes/daemonize no/' /etc/redis/redis.conf \
        && sed -ri 's/^save/# save/' /etc/redis/redis.conf

# Disable kernel logging support
RUN sed -ri '/imklog/s/^/#/' /etc/rsyslog.conf

# Setup supervisord
COPY scripts/veth-create.sh    /usr/bin/veth-create.sh
COPY scripts/redis_start.sh    /usr/bin/redis_start.sh
COPY configs/supervisord.conf  /etc/supervisor/conf.d/supervisord.conf

# Install PTF dependencies
RUN pip3 install scapy

# Install ptf_nn_agent and PTF helpers (required by sai_dataplane.py)
COPY ptf/ptf_nn/ptf_nn_agent.py      /ptf/ptf_nn/ptf_nn_agent.py
COPY ptf/setup.py                    /ptf/setup.py
COPY ptf/README.md                   /ptf/README.md
COPY ptf/src/ptf/*.py                /ptf/src/ptf/
COPY ptf/src/ptf/platforms/*.py      /ptf/src/ptf/platforms/
COPY ptf/requirements.txt            /ptf/requirements.txt

RUN echo "#mock" > /ptf/ptf \
        && pip3 install /ptf

# Install SAI Challenger CLI dependencies
RUN pip3 install click==8.0
RUN echo ". /sai-challenger/scripts/sai-cli-completion.sh" >> /root/.bashrc

RUN pip3 install pytest pytest_dependency pytest-html

WORKDIR /sai-challenger/tests

CMD ["/usr/bin/supervisord"]

