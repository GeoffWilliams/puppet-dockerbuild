# puppet-dockerbuild
Experimental build docker images built with puppet mounted into a container

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
* This is experimental and ... kinda works
* Drop me a line if interested in helping :D

### What works?
* command line parsing
* can talk to the docker daemon through its ruby api
* specify a base image, optionally the tag too (defaults to latest)
* start the base image, do simples stuff in the Dockerfile (hardcoded for now)
* mount read-only volumes from the host puppet master
* run puppet against requested class
* image committing and tagging

### What doesn't?
* setting the command to something other then ping :)
* port exposure
* probably lots else

### What will NOT EVER work
* ...there is no forever
* service resources - they are well against dockers one-process-per-container \
  'rule' but it is possible to work around this with nasty hacks.  For now I'm
  happy for this to be a limitation that one accepts when moving to docker
* systems that need too much guff from the host, eg privileged containers etc.
  Remember the aim of the game here is to produce light, portable 
  MICRO-services!  Emphasis on micro ;)

## how to run
```shell
./puppet-dockerbuild.rb --base-image ubuntu --role-class apache --output-image blah2
```
Build an image called blah that will be created by doing:
```shell
puppet apply -e 'include apache'
```
In this case I'm just including the main apache class, not a role but you get the idea..

## Troubleshooting
* It doesn't work!
  Read the source code ;-)
* cannot load such file -- mkmf (LoadError)
  ```shell
  sudo apt-get install ruby-dev
  ```
