FROM fedora:29

RUN yum -y install podman
RUN dnf install -y slirp4netns
RUN dnf install -y shadow-utils
RUN dnf install -y buildah
RUN dnf install -y ruby && gem install bundler

COPY $PWD/Gemfile      /tmp/Gemfile
COPY $PWD/Gemfile.lock /tmp/Gemfile.lock
WORKDIR /tmp
RUN bundle install

COPY $PWD/harness.rb /usr/bin/harness

ENTRYPOINT ["harness"]
