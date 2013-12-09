# 
# Cookbook Name:: lb_stingray
# Provider:: default
#
# Copyright Riverbed, Inc. All rights reserved.
#

include RightScale::LB::Helper

action :install do

    # Read in pretty version of the version number (include "." so as not to confuse people!)
    full_version = node[:lb_stingray][:software_version]


    # Check to ensure we've received a valid version number and bail out if not.
    if not full_version =~ /^[0-9]{1,2}\.[0-9](r[1-9]){0,1}$/
        raise "An invalid version number was provided. Installation aborted."
    end 

    # Convert to the version number we actually use
    version = full_version.gsub(".", "")

    # Read in the MD5 hash (path_hash attribute) of the software binary.  This is used in the S3 path.
    path_hash = node[:lb_stingray][:path_hash]

    # Hard-code architecture
    arch = "x86_64"

    # Read rightlink tag in order to find out whether we need to install a gold version.
    if node[:lb_stingray][:generic_binary] == "false" then
        packagename = "ZeusTM_#{version}_Linux-#{arch}-Gold"
    else
        packagename = "ZeusTM_#{version}_Linux-#{arch}"
    end

    # Set the URL of the installation file location in S3
    s3bucket = "http://s3.amazonaws.com/stingray-rightscale-#{version}-#{path_hash}/"

    # The temporary directory that the binary package will be extracted to.
    directory "/tmp/ZeusTM_#{version}_Linux-#{arch}" do
       recursive true
       action :nothing
    end

    file "/tmp/#{packagename}.tgz" do
      action :nothing
    end

    # Fetch the binary package from the s3 bucket.
    execute "Download Stingray Binaries" do
       creates "/tmp/#{packagename}.tgz"
       cwd "/tmp"
       # Resume partial transfers, print no console output.
       command "wget --continue --quiet #{s3bucket}#{packagename}.tgz"
       # TODO: check the MD5 hash of the downloaded file against the expected value and EXPLODE if necessary
    end

    # Replay file for non-interactive installation of Stingray.
    template "/tmp/install_replay" do
        not_if { ::File.exists?("/opt/riverbed/zxtm") }
        cookbook "lb_stingray"
        mode "0644"
        source "install.erb"
        variables( :accept_license => "accept", :path => "/opt/riverbed" )
    end

    # Unpack tarball and install software package
    if node["cloud"]["provider"] == "ec2" then
        execute "deploy_binaries" do
            creates "/opt/riverbed"
            cwd "/tmp"
            command "\
            tar xzvf #{packagename}.tgz && ZeusTM_#{version}_Linux-#{arch}/zinstall --ec2 --replay-from=/tmp/install_replay"
            notifies :delete, resources(
                :file => "/tmp/#{packagename}.tgz",
                :directory => "/tmp/ZeusTM_#{version}_Linux-#{arch}",
                :template => "/tmp/install_replay"
            ), :delayed
        end
    else
        execute "deploy_binaries" do
            creates "/opt/riverbed"
            cwd "/tmp"
            command "\
            tar xzvf #{packagename}.tgz && ZeusTM_#{version}_Linux-#{arch}/zinstall --replay-from=/tmp/install_replay"
            notifies :delete, resources(
                :file => "/tmp/#{packagename}.tgz",
                :directory => "/tmp/ZeusTM_#{version}_Linux-#{arch}",
                :template => "/tmp/install_replay"
            ), :delayed
        end
    end

    # Add RS-specific tunings.
    # FIXME: Do something about this - use zcli?
    template "/opt/riverbed/zxtm/conf/settings.cfg" do
        not_if { ::File.exists?("/opt/riverbed/rc.d/S20zxtm") }
        backup false
        cookbook "lb_stingray"
        source "settings.erb"
        mode "0644"
        variables(
            :controlallow => "127.0.0.1",
            :java_enabled => node[:lb_stingray][:java_enabled],
            :flipper_unicast => "9090",
            :errorlog => "%zeushome%/zxtm/log/errors",
            :flipper_autofailback =>  ( node["cloud"]["provider"] == "ec2" ) ? "No" : "Yes",
            :flipper_frontend_check_addrs => ( node["cloud"]["provider"] == "ec2" ) ? "" : "%gateway%",
            :flipper_heartbeat_method => ( node["cloud"]["provider"] == "ec2" ) ? "unicast" : "multicast",
            :flipper_monitor_interval => ( node["cloud"]["provider"] == "ec2" ) ? "2000" : "500",
            :flipper_monitor_timeout => ( node["cloud"]["provider"] == "ec2" ) ? "15" : "5"
        )
    end

	file "/tmp/stingray-license.txt" do
		action :nothing
	end

    template "/tmp/new_cluster_replay" do
        license_path=::File.exists?("/tmp/stingray-license.txt") ? "/tmp/stingray-license.txt" : ""
        not_if { ::File.exists?("/opt/riverbed/rc.d/S20zxtm") }
        backup false
        cookbook "lb_stingray"
        source "new_cluster.erb"
        mode "0644"
        variables(
            :accept_license => "accept",
            :admin_password => node[:lb_stingray][:password],
            :license_path => license_path
        )
    end

    # Initialize instance
    execute "new_cluster" do
        creates "/opt/riverbed/rc.d/S20zxtm"
        cwd "/opt/riverbed/zxtm"
        command "./configure --replay-from=/tmp/new_cluster_replay"
        notifies :delete,
        resources(
            :template => "/opt/riverbed/zxtm/conf/settings.cfg",
            :template => "/tmp/new_cluster_replay",
			:file => "/tmp/stingray-license.txt"
        )
    end

    # Create /etc/stingray/lb_stingray directory.
    directory "/etc/stingray/#{node[:lb][:service][:provider]}.d" do
        recursive true
        action :create
    end
    
    # Create the zeus service.
    execute "restart zeus" do
        command "/etc/init.d/zeus restart"
    end
    


end

action :add_vhost do
    # Generate zcli Script to create vserver,pool, and services
    # Get default pool name
    pool = new_resource.pool_name
    
    # Add Entry to create the pool
    zcli_script = "pool.addPool [\"#{pool}\"], [\"\"]\n"

    # Add Entry to create virtual server on default port, Add node, and enable virtual server
    zcli_script << "VirtualServer.addVirtualServer [\"#{pool}\"], { \"default_pool\": \"#{pool}\", \"port\": 80, \"protocol\": \"http\" }\n"
    zcli_script << "VirtualServer.setNote [\"#{pool}\"], [\"Created by RightScale - do not modify.\"]\n"
    zcli_script << "VirtualServer.setEnabled [\"#{pool}\"], [ \"true\" ]\n"
    
    #Verify Access to Node Attributes, and log what the next action is
    log "Stickiness='#{node[:lb][:session_stickiness]}'"

    # If the stickiness input is set, enable stickiness
    Chef::Log.info("Checking StickyPolicy")
    if node[:lb][:session_stickiness] == "true"
      Chef::Log.info("Stickiness enabled. Adding")
      #Add Entry for the Catalog Persistence
      zcli_script << "Catalog.Persistence.addPersistence [\"#{pool}-sticky\"]\n"
      zcli_script << "Catalog.Persistence.setNote [\"#{pool}-sticky\"], [\"Created by RightScale - do not modify.\"]\n"
      
      # Add entry to set persistence on pool
      zcli_script << "Pool.setPersistence [\"#{pool}\"], [\"#{pool}-sticky\"]\n"
    end
    
    # Create the script file from the zcli_script that has been updated with configuration options
    file "/opt/riverbed/#{pool}-create" do
      content zcli_script
      mode "666"
      action :create
    end
    
    # Run the newly created script with the zcli
    execute "SetupServices" do
        command "/opt/riverbed/zxtm/bin/zcli /opt/riverbed/#{pool}-create"
    end
  
  
  
    # Update tags to let RS know we are a load-balancer for this pool.
    right_link_tag "loadbalancer:#{new_resource.pool_name}=lb"

end

action :attach do
    
    # Gather Resources for the Attach: Pool, IP, Port, ID. Each needed to create reference cache store
    pool_name = new_resource.pool_name
    backend_id = new_resource.backend_id
    backend_ip = new_resource.backend_ip
    backend_port = new_resource.backend_port
    
    #Log to audit entries what we detected and are adding
    log "  Attaching #{backend_id} - #{backend_ip}:#{backend_port}, to #{pool_name}" 
    
    # Block to create script file, local cache, and execute script
    ruby_block "attach" do
      block do
        #--------
        # Gem for pstore
        require 'pstore'
    
        # Create PSStore for Local Cache
        store = PStore.new("/opt/riverbed/configuration.store")
    
        #Initial Read from Store
        Chef::Log.info("Reading from local store")
        store.transaction(true) do
          @pool = store["#{pool_name}"]
        end
        Chef::Log.info("Read from Cache")

        # Create Default Hash if First Run or empty
        Chef::Log.info("Checking what was read from local store")
        if @pool.to_s.empty?
          Chef::Log.info("No Configuration Found, creating default hash")
          @pool = Hash.new
        end
        Chef::Log.info("Attaching node")
        
        # Create Add Node Script file for zcli    
        node = "Pool.addNodes [ \"#{pool_name}\" ], [ \"#{backend_ip}:#{backend_port}\" ]"
        Chef::Log.info("Generated '#{node}'")
        
        # Write Script File
        Chef::Log.info("Writing Script File for zcli:\n\'#{node}'")
        ::File.open("/opt/riverbed/modify-node", 'w') { |file| file.write(node) }

        # Execute Script File
        Chef::Log.info("Running zcli")
        system("/opt/riverbed/zxtm/bin/zcli /opt/riverbed/modify-node")
        
        # Add new node to the pool hash to be saved
        @pool["#{backend_id}"] = Hash[
          :ip   => "#{backend_ip}",
          :port => "#{backend_port}"
        ]

        #Update local cache store
        Chef::Log.info("Updating local Store")
        store.transaction do
          store["#{pool_name}"] = @pool
          store.commit
        end
    
        # Wrap up
        Chef::Log.info("Finished")
        #----------
      end
    end
end

action :detach do
    # Gather Resources for the Attach: Pool, IP, Port, ID. Each needed to create reference cache store
    pool_name = new_resource.pool_name
    backend_id = new_resource.backend_id
    backend_port = new_resource.backend_port
    
    # Block to create script file, local cache, and execute script
    ruby_block "detatch" do
      block do
        #--------
        # Gem for pstore
        require 'pstore'
        
        # Create PSStore for Local Cache
        store = PStore.new("/opt/riverbed/configuration.store")
    
        #Initial Read from Store
        Chef::Log.info("Reading from local store")
        store.transaction(true) do
          @pool = store["#{pool_name}"]
        end
        Chef::Log.info("Read from Cache")

        # Create Default Hash if First Run or empty
        Chef::Log.info("Checking what was read from local store")
        if @pool.to_s.empty?
          Chef::Log.info("No Configuration Found, creating default hash")
          @pool = Hash.new
        end
       
       # Get Info from Local Cache about what node we are removing
       Chef::Log.info("Detatching node")
       ip = @pool["#{backend_id}"][:ip]
       port = @pool["#{backend_id}"][:port]
       
       # Generate Script for zcli
       node = "Pool.removeNodes [ \"#{pool_name}\" ], [ \"#{ip}:#{port}\" ]"
       Chef::Log.info("Generated '#{node}'")
       
       # Write Script file for zcli
       Chef::Log.info("Writing Script File for zcli:\n\'#{node}'")
       ::File.open("/opt/riverbed/modify-node", 'w') { |file| file.write(node) }
       
      # Execute the newly created script file
      Chef::Log.info("Running zcli")
      system("/opt/riverbed/zxtm/bin/zcli /opt/riverbed/modify-node")
         
      # Remove node that we are removing from the local cache
      @pool.delete("#{backend_id}")
      
      #Update local cache/store
      Chef::Log.info("Updating local Store")
      store.transaction do
        store["#{pool_name}"] = @pool
        store.commit
      end

      Chef::Log.info("Finished")
      #----------
    end
end



end

action :attach_request do

    pool_name = new_resource.pool_name

    log "  Attach request for #{new_resource.backend_id} / #{new_resource.backend_ip} / #{pool_name}"

    remote_recipe "Attach me to load balancer" do
        recipe "lb::handle_attach"
        attributes :remote_recipe => {
            :backend_ip => new_resource.backend_ip,
            :backend_id => new_resource.backend_id,
            :backend_port => new_resource.backend_port,
            :pools => [ "#{pool_name}" ]
        }
        recipients_tags "loadbalancer:#{pool_name}=lb"
    end

end

action :detach_request do

    pool_name = new_resource.pool_name

    log " Detach request for #{new_resource.backend_id} / #{pool_name}"

    remote_recipe "Detach me from load balancer" do
        recipe "lb::handle_detach"
        attributes :remote_recipe => {
            :backend_ip => new_resource.backend_ip,
            :backend_id => new_resource.backend_id,
            :pools => [ "#{pool_name}" ]
        }
        recipients_tags "loadbalancer:#{pool_name}=lb"
    end

end

action :restart do

    execute "restart stingray" do
        command "/etc/init.d/zeus restart"
        action :run
    end

end

action :setup_monitoring do

    # FIXME: Do something here.
    log "Set up monitoring."

end
