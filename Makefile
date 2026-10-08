SBX_IMAGE := t3-sandbox-sbx
DOCKER_IMAGE := t3-sandbox
BUILD_FLAGS ?=

.PHONY: all sandbox docker

all: sandbox docker

# sbx has its own image store: load the image there, then drop the tarball
# and the Docker copy (the build cache keeps rebuilds fast).
sandbox:
	docker build $(BUILD_FLAGS) -f Dockerfile.sbx -t $(SBX_IMAGE) .
	docker image save $(SBX_IMAGE) -o $(SBX_IMAGE).tar
	sbx template load $(SBX_IMAGE).tar; status=$$?; \
	  rm -f $(SBX_IMAGE).tar; docker image rm $(SBX_IMAGE) >/dev/null; exit $$status

docker:
	docker build $(BUILD_FLAGS) -t $(DOCKER_IMAGE) .
