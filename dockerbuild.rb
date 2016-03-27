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
require 'net/http'
require 'json'


class DockerBuild
    
    def initialize
        @status = "queued"
        @output = []
        @start_time = nil
        @end_time = nil       
        @pushed = false
        @final_name = ""
        @final_tag = ""
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

        container.exec(command) { | stream, chunk |
            @output.push("#{stream}: #{chunk}")
        }
        
    end
    
    # verify image + tag exist in remote repository
    # doesn't work with docker hub yet, just the registry
    # image
    def verify_remote_image_tag(registry, image, tag)
        uri = URI("http://#{registry}/v2/#{image}/tags/list")
        begin
            res = Net::HTTP.get_response(uri)
            if res.code == "200"
                json = JSON.parse(res.body)
                if json.has_key?("tags")
                    if json["tags"].include?(tag)
                        status = true
                        message = "remote image and tag exist"
                    else
                        status = false
                        message = "remote image exists but new tag missing"
                    end
                else
                    status = false
                    message = "remote image does not list any tags"
                end
            else
                status = false
                message = "remote image does not exist"
            end
        rescue SocketError
            status = false
            message = "error connecting to #{registry}"
        end
        
        return status, message
    end

    def remove_old_image(prefix, image, tag)
        # if image + tag already exists, we must remove it to avoid leaving
        # a stray tag
        
        target = "#{prefix}/#{image}:#{tag}"
        images = ::Docker::Image.all

        found = false
        i = 0
        while i < images.length and ! found
            image = images[i]
            repo_tags = image.info["RepoTags"]
            if repo_tags.include?(target)
               found = true
               image.remove
            end
            i += 1
        end
    end
        
    def build_image(
        logger,
        base_image,
        base_image_tag,
        environment,
        role_class,
        container_hostname,
        output_image,
        output_tag,
        target_os,
        prefix,
        push_image,
        remove_container
    )

        @start_time = Time.now()
        
        if prefix.nil? || prefix.empty?
            @final_name = output_image
            prefix_valid = false
        else
            @final_name = prefix + "/" + output_image
            prefix_valid = true
        end
        @final_tag = output_tag

        while App.refreshing?
           sleep(0.1) 
        end
        
        App.register_build        
        
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
            'repo'  => @final_name,
            'tag'   => @final_tag,
            'force' => true,
        }
        
        @status = "tagging image"
        remove_old_image(prefix, output_image, output_tag)
        image.tag(image_opts)

        # delete container (image will be left intact)
        @status = "cleaning up container"
        if remove_container
            container.delete(:force => true)
        else
            puts "finished build, container #{container.id} left on system"
        end

        if push_image and prefix_valid
            # also push the image :D
            @status = "pushing"
            
            # image.push seems to fail silently on error, so verify the ID
            # exists in the remote repository after push
            image.push
            push_status, push_message = verify_remote_image_tag(
                prefix, output_image, output_tag
            )
            
            if push_status
                @pushed = true
            else
                @pushed = "error pushing (#{push_message})"
            end
        end
        
        @end_time = Time.now()
        @status = "finished"
        puts("leaving build_image() -puts")
        App.complete_build
    end
    
    def status
        @status
    end
    
    def output
        @output
    end
    
    def output_html
        a2h = Ansi::To::Html.new(@output.join(""))
        a2h.to_html()
    end
    
    def stat
       [@start_time, (@end_time||Time.now()) - @start_time, @end_time] 
    end
    
    def pushed
        @pushed
    end
    
    def final_name
        @final_name
    end
    
    def final_tag
        @final_tag
    end
    
    def type
        "image"
    end
end

class SystemSettings
    def initialize
         begin
            @@settings = JSON.parse(File.read("./settings.json"))
            settings_updated
        rescue Errno::ENOENT
            @@settings = {
                "registry_ip"       => "",
                "insecure_registry" => ""
            }
        end       
    end
    
    def settings_updated

        if @@settings["insecure_registry"]
            registry_hostname = @@settings["insecure_registry"].split(/:/)[0]

            settings_pp = <<EOF
class { "docker":
    extra_parameters => "--insecure-registry #{@@settings['insecure_registry']}",
}
EOF

            if @@settings["registry_ip"]
                settings_pp += <<EOF
host { "#{registry_hostname}":
    ensure => present,
    ip      => "#{@@settings["registry_ip"]}",
    notify  => Service["docker"],
}
EOF
            end

        system("puppet apply -e '#{settings_pp}'")
        end
    end
    
    def update(settings)
        @@settings = settings
        save
        settings_updated
    end
    
    def save
        File.open("./settings.json","w") do |f|
            f.write(@@settings.to_json)
        end
    end
    
    def settings
        @@settings
    end
    
end

class RefreshPuppetCode
    def initialize
        @status = "queued"
        @output = []
        @start_time = nil
        @end_time = nil       
        @pushed = false
        @final_name = ""
        @final_tag = ""
    end
    
    def refresh
        @start_time = Time.now
        App.refreshing(true)
        
        # wait for any active build threads to finish
        while App.building > 0
           sleep(1) 
        end
        @status = "running"
        r10k_command = "cd /tmp && r10k deploy environment -pv 2>&1"

        exit_status = 1
        
        # r10k will fail if executed from dockerbuild directory for some
        # reason - seems to happen if checked out git code is in a subdir
        #pwd = Dir.pwd
        #Dir.chdir("/root")
        Open3.popen3(r10k_command) do |stdin, stdout, stderr, wait_thr|
            while line = stdout.gets
                @output.push(line)
            end
            exit_status = wait_thr.value
            if exit_status != 0
                @output.push("Failed to execute #{r10k_command}")
            end
        end
        #Dir.chdir(pwd)
        
        @end_time = Time.now
        @status = "finished"
        
        App.refreshing(false)
    end
    
    def status
        @status
    end
    
    def output
        @output
    end
    
    def output_html
        a2h = Ansi::To::Html.new(@output.join(""))
        a2h.to_html()
    end
    
    def stat
       [@start_time, (@end_time||Time.now()) - @start_time, @end_time] 
    end
    
    def type
        "refresh"
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
        # you cannot access any methods in *this* class here because
        # the class is not yet ready.  Must externalise to separate
        # class if method calls are needed
        @@system_settings = SystemSettings.new()

        # how many images are currently building (live threads)
        @@building = 0
        
        # was a refresh requested?  True until it is complete
        @@refreshing = false
    end

    def self.register_build
        @@semaphore.synchronize {
            @@building += 1
        }
    end
    
    def self.complete_build
        @@semaphore.synchronize {
            @@building -= 1
        }
    end
    
    def self.building
        @@semaphore.synchronize {
            @@building
        }
    end
    
    def self.refreshing(status) 
        @@semaphore.synchronize {
            @@refreshing = status
        }        
    end
    
    def self.refreshing?
        @@semaphore.synchronize {
            @@refreshing
        }
    end
    
    # shutdown hook
    at_exit do
        #@@dockerbuild.control_container()
        Sinatra::Application.quit!
    end

    get '/role_classes' do
        c = {}
        pwd = Dir.pwd
        Dir.chdir("/etc/puppetlabs/code/environments")

        # only match classes in role(s) and profile(s) modules
        # plus ready roles and ready profiles
        Dir.glob("**/{role,roles,r_role,profile,profiles,r_profile}/manifests/**/*.pp")  { |f| 

            # The environment is the first directory
            environment = f.split("/")[0]
            if ! c.has_key?(environment)
                c[environment] = []
            end
            
            # directory immediately before 'manifests' is the module name, everything
            # after 'manifests' forms the rest of the class name
            env_mod, file_part = f.match(/([^\/]+)\/manifests\/(.*)$/).captures
            
            # fix the module name
            m_name = env_mod.sub("/","::")
            
            # if the was manifests/init.pp then our classname is just the name
            # of the module.  We already have this so just discard the file_part
            # entirely
            c_name = file_part.sub(/init\.pp$/,"")

            if ! c_name.empty?
                c_name = "::" + c_name.gsub(/\//,"::").sub(/\.pp$/,"")
            end
            c[environment].push(m_name + c_name)
        }
        Dir.chdir(pwd)
        JSON.generate(c)        
    end

    get '/' do
        erb :index, :locals => {  }
    end

    get '/new_image' do
        erb :new_image
    end

    get '/refresh_puppet_code' do
        job_id="error"
        thread = Thread.new {
            r = ::RefreshPuppetCode.new()
            @@semaphore.synchronize {
                job_id = @@jobs.length
                @@jobs.push(r)
            }
            r.refresh
        }
        thread.abort_on_exception = true
        # wait for the above thread to add the dockerbuild instance to array of jobs 
        # if we don't wait here, we will get whatever we initialised job_id to
        sleep(0.1)
        "started job #{job_id}"
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
        prefix              = params[:prefix]
        push_image          = params[:push_image]
        remove_container    = params[:remove_container]

        errors = []
        if base_image.nil? || base_image.empty? 
            errors.push("base_image")
        end
        if base_image_tag.nil? || base_image_tag.empty?
            errors.push("base_image_tag")
        end
        if environment.nil? || environment.empty?
            errors.push("environment")
        end
        if role_class.nil? || role_class.empty?
            errors.push("role_class")
        end
        if container_hostname.nil? || container_hostname.empty?
            errors.push("container_hostname")
        end
        if output_image.nil? || output_image.empty?
            errors.push("output_image")
        end
        if output_tag.nil? || output_tag.empty?
            errors.push("output_tag")
        end
        if target_os.nil? || target_os.empty?
            errors.push("target_os")
        end

        if errors.empty?
            job_id = "error"

            thread = Thread.new {
                d = ::DockerBuild.new()
                @@semaphore.synchronize {
                    job_id = @@jobs.length
                    @@jobs.push(d)
                }
                d.build_image(
                    logger,
                    base_image,
                    base_image_tag,
                    environment,
                    role_class,
                    container_hostname,
                    output_image,
                    output_tag,
                    target_os,
                    prefix,
                    push_image,
                    remove_container
                 )

            }
            thread.abort_on_exception = true
            # wait for the above thread to add the dockerbuild instance to array of jobs 
            # if we don't wait here, we will get whatever we initialised job_id to
            sleep(0.1)
            "started job #{job_id}"
        else
            "errors encountered on fields " + errors.join("\n")
        end
        #erb :command_complete

    end
    
    # /status
    get '/status' do
        erb :status, :locals => {
            'jobs'          => @@jobs, 
            'building'      => @@building, 
            'refreshing'    => @@refreshing
        }
    end


    get '/settings' do
        erb :settings, :locals => {'settings' => @@system_settings.settings}
    end
    
    post '/settings' do
        settings = {
            "insecure_registry" => params[:insecure_registry],
            "registry_ip"       => params[:registry_ip]
        }
        @@system_settings.update(settings)
        "settings saved" 
    end
    
end



    
    
def main()
    App.run!    
end

main()