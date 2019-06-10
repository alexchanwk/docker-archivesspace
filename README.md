[![Build Status](https://travis-ci.org/alexchanwk/docker-archivesspace.svg?branch=master)](https://travis-ci.org/alexchanwk/docker-archivesspace)

# docker-archivesspace

An ArchivesSpace container with a MySQL container
  
## Notes:

1. Command for backup `docker ps -a | grep <app container name> | cut -d" " -f1 | xargs -I{} docker exec {} /backup.sh`