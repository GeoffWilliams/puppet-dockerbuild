# puppet-dockerbuild
nothing here yet! ;-)  this is an experiment to see if I can build docker images with puppet mounted into a container

## Prerequisites
* Docker `curl -sSL https://get.docker.com/ | sh`
* Puppet Enterprise `cd /vagrant/pe && sudo ./puppet-enterprise-installer -a answers/all-in-one.answers.txt`
* Somewhere to run the above 2 systems.  Vagrant is good for debugging, eventual target is a huge docker container with PE installed in it.  Here's one I made earlier:  https://github.com/GeoffWilliams/puppet_docker_images

### fixme - bundler + gemfile
```shell
gem install excon
sudo apt-get install ruby-dev
gem install docker-api
```

## Status
* This is experimental and doesn't work yet!
* Drop me a line if interested in helping :D

### What works?
* command line parsing
* can talk to the docker daemon through its ruby api
* specify a base image, optionally the tag too (defaults to latest)
* start the base image, do simples stuff in the Dockerfile (hardcoded for now)

### What doesn't?
* mounting volumes
* running puppet
* tagging/naming images
* ...basically anything useful

### What will NOT EVER work
* ...there is no forever
* service resources - they are well against dockers one-process-per-container \
  'rule' but it is possible to work around this with nasty hacks.  For now I'm
  happy for this to be a limitation that one accepts when moving to docker
* systems that need too much guff from the host, eg privileged containers etc.
  Remember the aim of the game here is to produce light, portable 
  MICRO-services!  Emphasis on micro ;)


## Troubleshooting
* It doesn't work!
  Of course it doesn't, I only started writing it a few hours ago
* cannot load such file -- mkmf (LoadError)
  ```shell
  sudo apt-get install ruby-dev
  ```
