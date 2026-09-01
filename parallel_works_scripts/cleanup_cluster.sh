#!/bin/bash

# delete_docker_image: deletes a specific image and related containers, then prunes
delete_docker_image() {
    local repo="$1"
    local tag="$2"
    local image="${repo}:${tag}"

    if [[ -z "$repo" || -z "$tag" ]]; then
        echo "Usage: delete_docker_image <repository> <tag>"
        return 1
    fi

    echo "Looking for containers using image: $image"

    # find and remove all containers using the image
    local containers
    containers=$(docker ps -a --filter ancestor="$image" -q)

    if [[ -n "$containers" ]]; then
        echo "Stopping and removing containers:"
        echo "$containers"
        docker rm -f $containers
    else
        echo "No containers found using image"
    fi

    # remove the image
    echo "Deleting image: $image"
    docker rmi "$image"

    # prune unused data
    echo "Cleaning up dangling images, volumes, and networks..."
    docker system prune -f --volumes

    echo "Done."
}

# delete_all_docker_data: removes all images and performs full cleanup
delete_all_docker_data() {
    echo "Stopping and removing all containers..."
    docker rm -f $(docker ps -aq) 2>/dev/null

    echo "Deleting all Docker images..."
    docker rmi -f $(docker images -q) 2>/dev/null

    echo "Pruning all unused data..."
    docker system prune -a -f --volumes

    echo "Done."
}

# main CLI handler
main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --docker)
            shift
            docker_arg="$1"
            if [[ "$docker_arg" == "all" ]]; then
                delete_all_docker_data
            else
                repo="${docker_arg%%:*}"
                tag="${docker_arg##*:}"
                if [[ "$repo" == "$tag" ]]; then
                    echo "Invalid image format. Use repo:tag"
                    exit 1
                fi
                delete_docker_image "$repo" "$tag"
            fi
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage:"
            echo "  --docker <repo:tag>   Delete a specific Docker image"
            echo "  --docker all          Delete all Docker images and associated data"
            exit 1
            ;;
        esac
    done
}

main "$@"
