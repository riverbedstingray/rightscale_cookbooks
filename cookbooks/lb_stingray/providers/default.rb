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

    # Read in the MD5 hash (binary_hash attribute) of the software binary.  This is used in the 
    #   S3 path and to validate the download.
    binary_hash = node[:lb_stingray][:binary_hash]

    # Hard-code architecture
    arch = "x86_64"

    # Read rightlink tag in order to find out whether we need to install a gold version.
    if node[:lb_stingray][:generic_binary] == "false" then
        packagename = "ZeusTM_#{version}_Linux-#{arch}-Gold"
    else
        packagename = "ZeusTM_#{version}_Linux-#{arch}"
    end

    # Set the URL of the installation file location in S3
    s3bucket = "http://s3.amazonaws.com/stingray-rightscale-#{version}-#{binary_hash}/"

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

    # Install script that reads server files and invokes zcli to configure the
    # pools.
    cookbook_file "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-wrapper.sh" do
        mode 0755
        source "stingray-wrapper.sh"
        cookbook "lb_stingray"
    end

    # Create the zeus service.
    execute "restart zeus" do
        command "/etc/init.d/zeus restart"
        action :nothing
    end

    if node["cloud"]["provider"] == "ec2" then

        cookbook_file "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-ec2ify.sh" do
            mode 0755
            source "stingray-ec2ify.sh"
            cookbook "lb_stingray"
        end

        file "/opt/riverbed/zxtm/.EC2" do
            action :create
        end

        # Create a global settings file.
        execute "ec2ify global settings" do
            command "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-ec2ify.sh \
                #{node["ec2"]["placement"]["availability_zone"]} \
                #{node["ec2"]["instance_id"]}"
            action :run
            notifies :run, resources(:execute => "restart zeus")
        end

    end

end

action :add_vhost do

    # Execute the wrapper.
    execute "wrapper" do
        command "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-wrapper.sh"
        action :nothing
    end
    
    # Create a configuration file for this pool.
    template "/etc/stingray/#{node[:lb][:service][:provider]}.d/services/#{new_resource.pool_name}/config" do
       source "pool.erb"
       cookbook "lb_stingray"
       action :nothing
       variables( :session_sticky => new_resource.session_sticky )
       notifies :run, resources( :execute => "wrapper" )
    end

    # Create a configuration directory for this pool.
    directory "/etc/stingray/#{node[:lb][:service][:provider]}.d/services/#{new_resource.pool_name}/servers" do
        recursive true
        action :create
        notifies :create, resources( :template => "/etc/stingray/#{node[:lb][:service][:provider]}.d/services/#{new_resource.pool_name}/config" )
    end
    
    # Update tags to let RS know we are a load-balancer for this pool.
    right_link_tag "loadbalancer:#{new_resource.pool_name}=lb"

end

action :attach do

    pool_name = new_resource.pool_name
    backend_id = new_resource.backend_id

    log "  Attaching #{backend_id} to #{pool_name}" 

    execute "wrapper" do
        command "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-wrapper.sh"
        action :nothing
    end

    template ::File.join("/etc/stingray/#{node[:lb][:service][:provider]}.d/services", pool_name, "servers",  backend_id) do
        source  "backend.erb"
        cookbook "lb_stingray"
        variables( :backend_ip => new_resource.backend_ip, :backend_port => new_resource.backend_port )
        notifies :run, resources(:execute => "wrapper")
    end

end

action :detach do

    pool_name = new_resource.pool_name
    backend_id = new_resource.backend_id

    log "  Detaching #{backend_id} from #{pool_name}"

    # Imports the config into Stingray's config system.
    execute "wrapper" do
        command "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-wrapper.sh"
        action :nothing
    end

    # Delete the backend's config file.
    file ::File.join("/etc/stingray/#{node[:lb][:service][:provider]}.d/services", pool_name, "servers" , backend_id) do
        action :delete
        backup false
        notifies :run, resources(:execute => "wrapper")
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
