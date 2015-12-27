require 'sinatra/base'
require 'docker'
require 'logger'
require 'open3'

$dockerbuild_home = File.expand_path(File.dirname(__FILE__))

class DockerBuild

  @@container = nil

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

  def control_container()
    puts "inside control_container()"
    init_docker_api
    if @@container == nil then
      #start
      @image = "geoffwilliams/pe2015.2.3_centos-7_aio-master_public_lowmem_dockerbuild:v0"
      # docker pull
      puts "docker pull #{@image} dockerbuild_home #{$dockerbuild_home}"
      image = Docker::Image.create('fromImage' => @image)
      @@container = Docker::Container.create(
        'Image'     => @image,
        'Cmd'       => "/usr/sbin/init",
        'Mounts'    => [
          {
            'source' => "#{$dockerbuild_home}/build/code",
            'destination' => '/etc/puppetlabs/code',
            'driver' => 'local',
            'mode' => '',
            'RW' => false,
          },
          {
            'source' => "#{$dockerbuild_home}",
            'destination' => '/dockerbuild', 
            'driver' => 'local',
            'mode' => '',
            'RW' => false,
          },
        ],
        'Volumes' => {
          '/etc/puppetlabs/code' => {},
          '/dockerbuild' => {},
        },
        'HostConfig' => {
          'Binds' => [
              "#{$dockerbuild_home}/build/code:/etc/puppetlabs/code",
              "#{$dockerbuild_home}:/dockerbuild",
          ],
        },
      )
      msg = @@container.start({"PublishAllPorts" => true, "Privileged" => true})
      puts "started container"
    else
      # stop
      msg = @@container.stop()
      puts "stopped container"
    end
    @command_output = msg
  end
  
  def container
    @@container
  end

end

class App < Sinatra::Base

  # startup hook
  configure do
    set :port, 9000
    set :dump_errors, true
 
    @@dockerbuild = DockerBuild.new()
    @@dockerbuild.control_container()
  end

  # shutdown hook
  at_exit do
    @@dockerbuild.control_container()
    Sinatra::Application.quit!
  end

  get '/' do
    if @@dockerbuild::container == nil
      @container_status = "stopped"
    else
      @container_status = @@dockerbuild::container.to_s
    end
    erb :index, :locals => { 'container' => @@dockerbuild::container }
  end

  get '/new_image' do
    erb :new_image
  end

  get '/container_log' do
    if @@dockerbuild::container
      value = "currently broken" # @@container.logs
    else
      value = "container not running"
    end
    return value
  end

  get '/refresh_puppet_code' do
    @r10k_config = "#{$dockerbuild_home}/r10k.yaml"
    @r10k_command = "r10k -c #{@r10k_config} deploy environment -pv"
    @command_output = ""
    exit_status = 1
    stdin, stdout, stderr, wait_thr = Open3.popen3(@r10k_command)
    exit_status = wait_thr.value
    @command_output += stdout.read
    @command_output += stderr.read
    if exit_status != 0
      @command_output =  "Failed to execute #{@r10k_command}. Error was #{stderr.read}"
    end
    stdin.close
    stdout.close
    stderr.close

    puts @command_output
    erb :command_complete
  end

  post '/new_image' do
    base_name           = params[:base_image]
    base_image_tag      = params[:base_image_tag]
    environment         = params[:environment]
    role_class          = params[:role_class]
    container_hostname  = params[:container_hostname]
    output_image        = params[:output_image]
    output_tag          = params[:output_tag]
    target_os           = params[:target_os]
    debug               = params[:debug]


    # FIXME validation and sanitation...

    @command_output = @@dockerbuild::container.exec([
      "/dockerbuild/puppet-dockerbuild.rb",
      "--base-name", base_name,
      "--base-image-tag", base_image_tag,
      "--environment", environment,
      "--role-class", role_class,
      "--container-hostname", container_hostname,
      "--output-image", output_image,
      "--output-tag", output_tag,
      "--target-os", target_os,
      "--debug" 
    ])

    erb :command_complete
  end
end

App.run!
