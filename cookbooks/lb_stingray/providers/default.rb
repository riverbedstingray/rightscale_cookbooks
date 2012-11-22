# 
# Cookbook Name:: lb_stingray
#
# Copyright Riverbed, Inc. All rights reserved.
#
include RightScale::LB::Helper

action :install do

    version = "90"
    arch = "x86_64"

    # Read rightlink tag in order to find out whether we need to install a gold version.
    if node[:lb_stingray][:generic_binary] == "false" then
        packagename = "ZeusTM_#{version}_Linux-#{arch}-Gold"
    else
        packagename = "ZeusTM_#{version}_Linux-#{arch}"
    end

    s3bucket = "http://s3.amazonaws.com/stingray-rightscale-90-a57a56ee8b4936501ffa85c76fa3dc9e/"

    # The temporary directory that the binary package will be extracted to.
    directory "/tmp/#{packagename}" do
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
    end

    # Replay file for non-interactive installation of Stingray.
    template "/tmp/install_replay" do
        not_if { ::File.exists?("/opt/riverbed/zxtm") }
        cookbook "stingray"
        mode "0644"
        source "install.erb"
        variables(
        :accept_license => "y",
        :path => "/opt/riverbed"
        )
    end

    # Unpack tarball and install software package
    execute "deploy_binaries" do
        creates "/opt/riverbed"
        cwd "/tmp"
        command "\
        tar xzvf #{packagename}.tgz &&
        #{packagename}/zinstall --replay-from=/tmp/install_replay"
        notifies :delete, resources(
            :file => "/tmp/#{packagename}.tgz",
            :directory => "/tmp/#{packagename}",
            :template => "/tmp/install_replay"
        ), :delayed
    end

    # Add RS-specific tunings.
    # FIXME: Do something about this - use zcli?
    template "/opt/riverbed/zxtm/conf/settings.cfg" do
        not_if { ::File.exists?("/opt/riverbed/rc.d/S20zxtm") }
        backup false
        cookbook "stingray"
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

    template "/tmp/new_cluster_replay" do
        license_path=::File.exists?("/tmp/stingray-license.txt") ? "/tmp/stingray-license.txt" : ""
        not_if { ::File.exists?("/opt/riverbed/rc.d/S20zxtm") }
        backup false
        cookbook "stingray"
        source "new_cluster.erb"
        mode "0644"
        variables(
            :accept_license => "y",
            :admin_password => node[:lb_stingray][:admin_pass],
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
            :template => "/tmp/new_cluster_replay"
        )
    end

    # Create /etc/stingray directory.
    directory "/etc/stingray/#{node[:lb][:service][:provider]}.d" do
        owner "nobody"
        group "nogroup"
        mode 0755
        recursive true
        action :create
    end

    # Install script that reads server files and invokes zcli to configure the
    # pools.
    cookbook_file "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-wrapper.sh" do
        owner "nobody"
        group "nogroup"
        mode 0755
        source "stingray-wrapper.sh"
        cookbook "lb_stingray"
    end
    
    # Create the zeus service.
    service "zeus" do
        action :nothing
    end

    if node["cloud"]["provider"] == "ec2" then

        file "/opt/riverbed/zxtm/.EC2" do
            action :create
        end

        gs_name = "/opt/riverbed/zxtm/conf/zxtms/#{node["ec2"]["hostname"]}"

        # Create a global settings file.
        # FIXME: Use zcli for this.
        template gs_name do
            source "global_settings_file"
            cookbook "lb_stingray"
            variables(
                :ec2_availability_zone => node["ec2"]["placement"]["availability_zone"],
                :ec2_instanceid => node["ec2"]["instance_id"],
                :external_ip => "EC2"
            )
            notifies :restart, resources(:service => "zeus")
        end

    end

end

action :add_vhost do

    # Execute the wrapper.
    execute "wrapper" do
        command "/etc/stingray/#{node[:lb][:service][:provider]}.d/stingray-wrapper.sh"
        action :nothing
    end

    # Create a configuration directory for this pool.
    directory "/etc/stingray/services/#{new_resource.pool_name}" do
        action :create
        notifies :run, resources( :execute => "wrapper" )
    end
    
    # Update tags to let RS know we are a load-balancer for this pool.
    right_link_tag "loadbalancer:#{new_resource.pool_name}=lb"

end

action :attach do

    pool_name = new_resource.pool_name
    backend_id = new_resource.backend_id
    session_sticky = new_recource.sticky

    log "  Attaching #{backend_id} to #{pool_name}" 

    execute "wrapper" do
        command "/etc/stingray/stingray-wrapper.sh"
        action :nothing
    end

    # Create configuration file from template
    template ::File.join("/etc/stingray/#{node[:lb][:service][:provider]}.d", pool_name, "config") do
        source "pool.erb"
        cookbook "lb_stingray"
        variables ([ :session_sticky => session_sticky ])
    end

    template ::File.join("/etc/stingray/#{node[:lb][:service][:provider]}.d", pool_name, "servers",  backend_id) do
        source  "backend.erb"
        cookbook "lb_stingray"
        variables ([
            :backend_ip => new_resource.backend_ip,
            :backend_port => new_resource.backend_port
        ])
        notifies :run, resources(:execute => "wrapper")
    end

end

action :detach do

    pool_name = new_resource.pool_name
    backend_id = new_resource.backend_id

    log "  Detaching #{backend_id} from #{pool_name}"

    # Imports the config into Stingray's config system.
    execute "wrapper" do
        command "/etc/stingray/stingray-wrapper.sh"
        action :nothing
    end

    # Delete the backend's config file.
    file ::File.join("/etc/stingray/#{node[:lb][:service][:provider]}.d", pool_name, backend_id) do
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
            :pools => pool_name
        }
        recipients_tags "loadbalancer:#{pool_name}=lb"
    end

end

action :detach_request do

    # Just maybe - if we use the same signature as HAProxy, we won't need to
    # include lb_stingray in the rightscale_cookbook repo.

    pool_name = new_resource.pool_name

    log " Detach request for #{new_resource.backend_id} / #{pool_name}"

    remote_recipe "Detach me from load balancer" do
        recipe "lb::handle_detach"
        attributes :remote_recipe => {
            :backend_id => new_resource.backend_id,
            :pools => pool_name
        }
        recipients_tags "loadbalancer:#{pool_name}=lb"
    end

end

action :restart do

    service "zeus" do
        action :restart
    end

end

action :setup_monitoring do

    # FIXME: Do something here.
    log "Set up monitoring."

end
