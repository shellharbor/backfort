# Development/test tools never enter the production image or its scan.
ARG BACKFORT_IMAGE=backfort:1.4.0-candidate-amd64
FROM ${BACKFORT_IMAGE}
RUN apt-get update \
    && apt-get install --yes --no-install-recommends python3 shellcheck \
    && rm -rf /var/lib/apt/lists/* \
    && mv /usr/local/bin/docker /usr/local/bin/docker-real
COPY docker-fixture-paths.sh /usr/local/bin/docker
RUN chmod 0755 /usr/local/bin/docker
ENTRYPOINT ["/bin/bash"]
