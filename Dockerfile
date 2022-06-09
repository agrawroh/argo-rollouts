# The default obtained on 05/07/2021 from /universe/docker-images/ubuntu/18.04/BUILD
ARG IMAGE_SHA=sha256:a71f06430a77e1134d3cfc9954430d72fd0a9dec840514317b300061e87bb814
# Set Default Build Platform as Linux AMD64
ARG BUILDPLATFORM="linux/amd64"
# Set base image to internal ubuntu image with image sha version generated in the update script.
FROM registry.dev.databricks.com/universe/db-ubuntu-18.04@${IMAGE_SHA} AS final

####################################################################################################
# Builder image
# Initial stage which pulls prepares build dependencies and CLI tooling we need for our final image
# Also used as the image in CI jobs so needs all dependencies
####################################################################################################
FROM --platform=$BUILDPLATFORM golang:1.19 as builder

RUN apt-get update && apt-get install -y \
    wget \
    ca-certificates && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Install golangci-lint
RUN curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin v1.49.0 && \
    golangci-lint linters

COPY .golangci.yml ${GOPATH}/src/dummy/.golangci.yml

RUN cd ${GOPATH}/src/dummy && \
    touch dummy.go \
    golangci-lint run

####################################################################################################
# Argo Rollouts UI Docker Image
####################################################################################################
FROM --platform=$BUILDPLATFORM docker.io/library/node:12.18.4 as argo-rollouts-ui

WORKDIR /src
ADD ["ui/package.json", "ui/yarn.lock", "./"]

RUN yarn install --network-timeout 300000

ADD ["ui/", "."]

ARG ARGO_VERSION=latest
ENV ARGO_VERSION=$ARGO_VERSION
RUN NODE_ENV='production' yarn build

####################################################################################################
# Rollout Controller Build stage which performs the actual build of argo-rollouts binaries
####################################################################################################
FROM --platform=$BUILDPLATFORM golang:1.19 as argo-rollouts-build

WORKDIR /go/src/github.com/argoproj/argo-rollouts

# Copy only go.mod and go.sum files. This way on subsequent docker builds if the
# dependencies didn't change it won't re-download the dependencies for nothing.
COPY go.mod go.sum ./
RUN go mod download

# Copy UI files for plugin build
COPY --from=argo-rollouts-ui /src/dist/app ./ui/dist/app

# Perform the build
COPY . .

# stop make from trying to re-build this without yarn installed
RUN touch ui/dist/node_modules.marker && \
    mkdir -p ui/dist/app && \
    touch ui/dist/app/index.html && \
    find ui/dist

ARG TARGETOS
ARG TARGETARCH
ARG MAKE_TARGET="controller plugin"
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH make ${MAKE_TARGET}

####################################################################################################
# Kubectl Argo Rollouts Plugin Docker Image
####################################################################################################
FROM docker.io/library/ubuntu:20.10 as kubectl-argo-rollouts

COPY --from=argo-rollouts-build /go/src/github.com/argoproj/argo-rollouts/dist/kubectl-argo-rollouts /bin/kubectl-argo-rollouts

USER 999

WORKDIR /home/argo-rollouts

ENTRYPOINT ["/bin/kubectl-argo-rollouts"]

CMD ["dashboard"]

####################################################################################################
# Final Argo Docker Image
####################################################################################################
FROM final

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get autoclean -y \
    && apt-get install -y rsyslog \
    && apt-get install -y ca-certificates \
    && apt-get install -y logrotate \
    && apt-get autoremove -y \
    && apt-get clean \
    && rm -rf /tmp/* /var/tmp/* \
    && rm -rf /var/lib/apt/lists/*

COPY --from=argo-rollouts-build /go/src/github.com/argoproj/argo-rollouts/dist/rollouts-controller /bin/
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
