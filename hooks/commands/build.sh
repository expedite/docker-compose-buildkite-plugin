#!/bin/bash

COMPOSE_SERVICE_NAME="$BUILDKITE_PLUGIN_DOCKER_COMPOSE_BUILD"
COMPOSE_SERVICE_DOCKER_IMAGE_NAME="$(docker_compose_container_name "$COMPOSE_SERVICE_NAME")"
DOCKER_IMAGE_REPOSITORY="${BUILDKITE_PLUGIN_DOCKER_COMPOSE_IMAGE_REPOSITORY:-}"

# Returns a friendly image file name like "myproject-app-build-49" than can be
# used as the docker image tag or tar.gz filename
image_file_name() {
  # The project slug env variable includes the org (e.g. "org/project"), so we
  # have to strip the org from the front (e.g. "project")
  local project_name=$(echo "$BUILDKITE_PROJECT_SLUG" | sed 's/^\([^\/]*\/\)//g')

  echo "$project_name-$COMPOSE_SERVICE_NAME-build-$BUILDKITE_BUILD_NUMBER"
}

push_image_to_docker_repository() {
  local tag="$DOCKER_IMAGE_REPOSITORY:$(image_file_name)"

  plugin_prompt_and_must_run docker tag "$COMPOSE_SERVICE_DOCKER_IMAGE_NAME" "$tag"
  plugin_prompt_and_must_run docker push "$tag"
  plugin_prompt_and_must_run docker rmi "$tag"
  echo "+++ :docker: Saving image $COMPOSE_SERVICE_DOCKER_IMAGE_NAME"
  local name="${BUILDKITE_PIPELINE_SLUG}_${BUILDKITE_BRANCH}_${COMPOSE_SERVICE_NAME}"
  local slug=/tmp/docker-cache/$name.tar.gz
  local BUILDKITE_IMAGE_CACHE_BUCKET="clara-docker-cache"
  local images_file=s3://$BUILDKITE_IMAGE_CACHE_BUCKET/$name.images
  local images=$(echo $(docker images -a | grep $(echo $BUILDKITE_JOB_ID | sed 's/-//g') | awk '{print $1}' | xargs -n 1 docker history -q | grep -v '<missing>'))

  if [[ -n $images ]] && ( ! aws s3 ls $images_file || [[ "$images" != $(aws s3 cp $images_file -) ]]) ; then
      rm -rf /tmp/docker-cache
      mkdir -p /tmp/docker-cache

      docker save $images | gzip -c > $slug

      aws s3 cp $slug s3://$BUILDKITE_IMAGE_CACHE_BUCKET/$name.tar.gz
      echo "$images" | aws s3 cp - s3://$BUILDKITE_IMAGE_CACHE_BUCKET/$name.images
  fi

  plugin_prompt_and_must_run buildkite-agent meta-data set "$(build_meta_data_image_tag_key "$COMPOSE_SERVICE_NAME")" "$tag"
}

echo "+++ :docker: Fetching cached docker images"

# see if we are missing any of the images locally, and load them if we are
(
  BUILDKITE_IMAGE_CACHE_BUCKET="clara-docker-cache"
  name="${BUILDKITE_PIPELINE_SLUG}_${BUILDKITE_BRANCH}_${COMPOSE_SERVICE_NAME}"
  backup_name="${BUILDKITE_PIPELINE_SLUG}_master_${COMPOSE_SERVICE_NAME}"
  images_file=s3://$BUILDKITE_IMAGE_CACHE_BUCKET/$name.images
  backup_images_file=s3://$BUILDKITE_IMAGE_CACHE_BUCKET/${backup_name}.images
  if aws s3 ls $images_file; then
      echo "Using cache"
      aws s3 cp s3://$BUILDKITE_IMAGE_CACHE_BUCKET/$name.tar.gz - | gunzip -c | docker load
  elif aws s3 ls $backup_images_file; then
    echo "Using backup cache (master)"
    aws s3 cp s3://$BUILDKITE_IMAGE_CACHE_BUCKET/${backup_name}.tar.gz - | gunzip -c | docker load
  else
    echo "No cache found"
  fi
)

echo "+++ :docker: Building Docker Compose images for service $COMPOSE_SERVICE_NAME"

run_docker_compose build "$COMPOSE_SERVICE_NAME"

echo "~~~ :docker: Listing docker images"

plugin_prompt docker images
docker images | grep buildkite

if [[ ! -z "$DOCKER_IMAGE_REPOSITORY" ]]; then
  echo "~~~ :docker: Pushing image $COMPOSE_SERVICE_DOCKER_IMAGE_NAME to $DOCKER_IMAGE_REPOSITORY"

  push_image_to_docker_repository
fi
