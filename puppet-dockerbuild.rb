#!/usr/bin/env ruby

require 'getoptlong'
require 'docker'
require 'excon'
require 'logger'

def show_usage()
  puts <<-EOF
    puppet_dockerbuild.rb --base-image BASE_IMAGE \\ 
                          --base-image-tag BASE_IMAGE_TAG \\
                          --environment ENVIRONMENT \\  
                          --role-class ROLE_CLASS \\ 
                          --output-image DOCKER_IMAGE \\  
                          --output-tag TAG \\ 
    
    BASE_IMAGE
      Docker image to download and build inside

    BASE_IMAGE_TAG
      Base image tag number.  Defaults to latest

    ENVIRONMENT
      puppet environment to build for

    ROLE_CLASS
      Role class to install with puppet

    DOCKER_IMAGE
      Final image name

    TAG
      Final image tag
  EOF
end

def parse_command_line()
  opts = GetoptLong.new(
    [ '--base-image',         GetoptLong::REQUIRED_ARGUMENT ],
    [ '--base-image-tag',     GetoptLong::REQUIRED_ARGUMENT ],
    [ '--environment',        GetoptLong::REQUIRED_ARGUMENT ],
    [ '--role-class',         GetoptLong::REQUIRED_ARGUMENT ],
    [ '--container-hostname', GetoptLong::REQUIRED_ARGUMENT ],
    [ '--output-image',       GetoptLong::REQUIRED_ARGUMENT ],
    [ '--output-tag',         GetoptLong::REQUIRED_ARGUMENT ],
    [ '--help',               GetoptLong::NO_ARGUMENT ],
    [ '--debug',              GetoptLong::NO_ARGUMENT ],
  )

  opts.each do |opt,arg|
    case opt
    when '--base-image'
      @base_image = arg
    when '--base-image-tag'
      @base_image_tag = arg
    when '--environment'
      @environment = arg
    when '--role-class'
      @role_class = arg
    when '--container-hostname'
      @container_hostname = arg
    when '--output-image'
      @output_image = arg
    when '--output-tag'
      @output_tag = arg
    when '--help'
      show_usage()
    when '--debug'
      @debug = true
    end
  end
  if @base_image and @role_class and @output_image then
    if @base_image_tag.nil? then
      @base_image_tag = "latest"
    end

    if @output_tag.nil? then
      @output_tag = "latest"
    end

    if @container_hostname.nil? then
      @container_hostname = "localhost.localdomain"
    end
    true
  else
    false
  end
end

def init_docker_api
  # increase the http timeouts as provisioning images can be slow
  #default_docker_options = { :write_timeout => 300, :read_timeout => 300 }.merge(::Docker.options || {})
  # Merge docker options from the entry in hosts file
  #::Docker.options = default_docker_options.merge(@options[:docker_options] || {})
  # assert that the docker-api gem can talk to your docker
  # enpoint.  Will raise if there is a version mismatch
  begin
    ::Docker.validate_version!
  rescue Excon::Errors::SocketError => e
    raise "Docker instance not connectable.\nError was: #{e}\nIf you are on OSX, you might not have Boot2Docker setup correctly\nCheck your DOCKER_HOST variable has been set"
  end

  @logger = Logger.new(STDOUT)
  @logger.level = Logger::INFO
  ::Docker.logger = @logger
end

def dockerfile
  "FROM #{@base_image}:#{@base_image_tag}
   CMD ping localhost # keep container from dying is there a nicer way?...
  "
end

def run_puppet(container)
  command = [
    "/opt/puppetlabs/puppet/bin/puppet",
    "apply",
    "-e",
    "include #{@role_class}",
  ]

  # needed to prevent timeouts from container.exec()
  Excon.defaults[:write_timeout] = 1000
  Excon.defaults[:read_timeout] = 1000

  puppet_out = container.exec(command) { | stream, chunk |
    puts "#{stream}: #{chunk}"
  }

end

def build_image
  init_docker_api
  image = ::Docker::Image.build(dockerfile(), { :rm => true })

  hostconfig = {}
  hostconfig['Binds'] = [
    '/etc/puppetlabs:/etc/puppetlabs:ro',
    '/opt/puppetlabs:/opt/puppetlabs:ro',
  ] 
  container_opts = {
    'Image'     => image.id,
    'Hostname'  => @container_hostname,
    'Volumes'   => {
        "/etc/puppetlabs"               => {},
        "/opt/puppetlabs"               => {},
        "/opt/puppetlabs/puppet/cache"  => {},
        "/etc/puppetlabs/puppet/ssl"    => {},
    },
    'HostConfig' => hostconfig, 
  }
  container = ::Docker::Container.create(container_opts)
  container.start({"PublishAllPorts" => true, "Privileged" => true})

  # run puppet apply
  run_puppet(container)

  # commit/save container to be an image
  image = container.commit
  image_opts = {
    'repo'  => @output_image,
    'tag'   => @output_tag,
  }
  image.tag(image_opts)

  # delete container (image will be left intact)
  if @debug
    puts "finished build, container #{container.id} left on system"
  else
    container.delete(:force => true)
  end
end

def main
  if parse_command_line
    puts "bulding!"
    build_image
  else
    puts "missing argument"
    show_usage
  end
end

main
