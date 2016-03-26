#!/usr/bin/env ruby
# Web Service + CLI
#
# Docker-in-Docker building

require 'sinatra/base'
require 'docker'
require 'logger'
require 'open3'
require 'getoptlong'
require 'docker'
require 'excon'
require 'logger'
require 'ansi-to-html'


class DockerBuild
    
    def initialize
        @@debug = false
        @status = "ready"
        @puppet_output = []
        @start_time = nil
        @end_time = nil        
    end
    
    def init_docker_api
        # increase the http timeouts as provisioning images can be slow
        #default_docker_options = { :write_timeout => 300, :read_timeout => 300 		}.merge(::Docker.options || {})
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

    def dockerfile(
        target_os,
        base_image,
        base_image_tag
    )
        
        systemd = "/lib/systemd/systemd"
        case target_os 
        when "debian"
            update = "apt-get update"
  		when "redhat"
            update = "yum clean all"
        else
            abort("Unknown target os: #{target_os}")
        end

        "FROM #{base_image}:#{base_image_tag}
        RUN #{update}
        CMD #{systemd}
        "
    end

    def run_puppet(container, role_class)
        command = [
            "/opt/puppetlabs/puppet/bin/puppet",
            "apply",
            "-e",
            "include #{role_class}",
        ]

        # needed to prevent timeouts from container.exec()
        Excon.defaults[:write_timeout] = 1000
        Excon.defaults[:read_timeout] = 1000

        @puppet_output = container.exec(command) { | stream, chunk |
            puts "#{stream}: #{chunk}"
        }

    end

    def build_image(
#        logger,
       base_image,
        base_image_tag,
        environment,
        role_class,
        container_hostname,
        output_image,
        output_tag,
        target_os
    )
        puts("inside build_image() - puts")
        @start_time = Time.now()
        @status = "starting build"
    #    logger.info("inside build_image()...!")
        puts("test message - should be after logger message")
        init_docker_api
        @status = "preparing container"
        image = ::Docker::Image.build(
            dockerfile(
                target_os,
                base_image,
                base_image_tag,
            ), 
            { :rm => true }
        )

        hostconfig = {}
        hostconfig['Binds'] = [
            '/etc/puppetlabs:/etc/puppetlabs:ro',
            '/opt/puppetlabs:/opt/puppetlabs:ro',
        ] 
        container_opts = {
            'Image'     => image.id,
            'Hostname'  => container_hostname,
            'Volumes'   => {
                "/etc/puppetlabs"               => {},
                "/opt/puppetlabs"               => {},
                "/opt/puppetlabs/puppet/cache"  => {},
                "/etc/puppetlabs/puppet/ssl"    => {},
            },
            'HostConfig' => hostconfig, 
        }
        container = ::Docker::Container.create(container_opts)

        @status = "starting container"
        container.start({"PublishAllPorts" => true, "Privileged" => true})

        # run puppet apply
        @status = "running puppet"
        run_puppet(container, role_class)

        # commit/save container to be an image
        @status = "committing image"
        image = container.commit
        image_opts = {
            'repo'  => output_image,
            'tag'   => output_tag,
            'force' => true,
        }
        
        @status = "tagging image"
        image.tag(image_opts)

        # delete container (image will be left intact)
        @status = "cleaning up container"
        if @@debug
            puts "finished build, container #{container.id} left on system"
        else
            container.delete(:force => true)
        end
   #     logger.info("...leaving build_image()")
        
        @end_time = Time.now()
        @status = "finished"
        puts("leaving build_image() -puts")
        
    end
    
    def status
        @status
    end
    
    def puppet_output
        @puppet_output
    end
    
    def puppet_output_html
        a2h = Ansi::To::Html.new(@puppet_output.join("\n"))
        a2h.to_html()
    end
    
    def stat
       [@start_time, (@end_time||Time.now()) - @start_time, @end_time] 
    end
end


class App < Sinatra::Base

  # startup hook
  configure do
    set :bind, '0.0.0.0'
    set :port, 9000
    set :dump_errors, true

    @@jobs = []    
    @@semaphore = Mutex.new

    enable :logging
  end

  # shutdown hook
  at_exit do
    #@@dockerbuild.control_container()
    Sinatra::Application.quit!
  end

  def get_environments
    pwd = Dir.pwd
    Dir.chdir("/etc/puppetlabs/code/environments")
    @environments = Dir.glob('*').reject {|e| !File.directory?(e)}
    Dir.chdir(pwd)
    puts "Environments loaded: #{@environments}"
  end

  get '/' do
    #if @@dockerbuild::container == nil
    #  @container_status = "stopped"
    #else
    #  @container_status = @@dockerbuild::container.to_s
    #end
    erb :index, :locals => {  }
  end

  get '/new_image' do
    get_environments
    erb :new_image
  end

#  get '/container_log' do
    #if @@dockerbuild::container
    #  value = "currently broken" # @@container.logs
    #else
    #  value = "container not running"
    #end
#    return value
#  end

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
        logger.info "creating new docker image"
        base_image          = params[:base_image]
        base_image_tag      = params[:base_image_tag]
        environment         = params[:environment]
        role_class          = params[:role_class]
        container_hostname  = params[:container_hostname]
        output_image        = params[:output_image]
        output_tag          = params[:output_tag]
        target_os           = params[:target_os]
        debug               = params[:debug]


        # FIXME validation and sanitation...
        #@command_output = @@dockerbuild::container.exec([
        #  "/dockerbuild/puppet-dockerbuild.rb",
        #  "--base-name", base_name,
        #  "--base-image-tag", base_image_tag,
        #  "--environment", environment,
        #  "--role-class", role_class,
        #  "--container-hostname", container_hostname,
        #  "--output-image", output_image,
        #  "--output-tag", output_tag,
        #  "--target-os", target_os,
        #  "--debug" 
        #])
        
        job_id = "error"

        thread = Thread.new {
            d = ::DockerBuild.new()
            @@semaphore.synchronize {
                job_id = @@jobs.length
                @@jobs.push(d)
            }
            d.build_image(
 #                logger,
                base_image,
                base_image_tag,
                 environment,
                role_class,
                container_hostname,
                output_image,
                output_tag,
                target_os,
             )

        }
        # wait for the above thread to add the dockerbuild instance to array of jobs 
        # if we don't wait here, we will get whatever we initialised job_id to
        sleep(0.1)
        "started job #{job_id}"
        #erb :command_complete

    end
    
    # /status
    get '/status' do
        erb :status, :locals => {'jobs' => @@jobs}
    end
end



    
    
def main()
    App.run!    
end

main()