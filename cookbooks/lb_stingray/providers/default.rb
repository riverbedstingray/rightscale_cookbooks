include RightScale::LB::Helper

action :install do

    # Figure out what to do about installing a Stingray package?

    # Create /etc/stingray directory.
    directory "/etc/stingray/#{node[:lb][:service][:provider]}.d" do
        owner "nobody"
        group "nogroup"
        mode 0755
        recursive true
        action :create
    end

    # Install script that reads server files and invokes zcli to configure the
    # services.

    cookbook_file "/etc/stingray/stingray-wrapper.sh" do
        owner "nobody"
        group "nogroup"
        mode 0755
        source "stingray-zcli-wrapper.sh"
        cookbook "lb_stingray"
    end

    if node["cloud"]["provider"] == "ec2" then
        file "/opt/riverbed/zxtm/.EC2" do
            backup false
            action :create
        end

        gs_name = "/opt/riverbed/zxtm/conf/zxtms/#{node["ec2"]["hostname"]}"

        # Create a global settings file.  FIXME: This needs to pull a template
        # instead of creating a new resource.
        # This should also notify the zeus service to restart.
        stingray_global_settings gs_name do
            ec2_availability_zone node["ec2"]["placement"]["availability_zone"]
            ec2_instanceid node["ec2"]["instance_id"]
            external_ip "EC2"
            action :configure
        end

        service "zeus" do
            action :restart
        end

    end

end

action :add_vhost do

    # Create a config directory for this vhost.

    # Create config file from template
    # Contains: max_conn_per_node, session_sticky.

    # Create a directory for server configs.
    
    # Update tags to let RS know we are a load-balancer for this vhost.
    right_link_tag "loadbalancer:#{new_resource.vhost_name}=lb"

end

action :attach do

    vhost_name = new_resource.vhost_name


end

action :detach do

    pool_name = new_resource.pool_name
    backend_id = new_resource.backend_id

    log "  Detaching #{backend_id} from #{pool_name}"

    # Restart Zeus?  Not sure we need this.
    service "zeus" do
        supports :reload => true, :restart => true, :status => false, :start => true, :stop => true
        action :nothing
    end

    # Imports the config into Stingray's config system.
    execute "/etc/stingray/stingray-wrapper.sh" do
        action :nothing
        notifies :reload, resources(:service => "zeus")
        # Not sure we need to do this.
    end

    # Delete the backend's config file.
    file ::File.join("/etc/stingray/#{node[:lb][:service][:provider]}.d", pool_name, backend_id) do
        action :delete
        backup false
        # Execute the wrapper script.
        notifies :run, resource(:execute => "/etc/stingray/stingray-wrapper.sh")
    end

end

action :attach_request do

    pool_name = new_resource.pool_name

    log "  Attach request for #{new_resource.backend_id} / #{new_resource.backend_ip} / #{pool}"

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

    pool_name = new_resource.pool

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

<<<<<<< Updated upstream
    execute "Restart Stingray" do
        cwd = node["stingray"]["path"]
        command "./restart-zeus"
=======
    service "zeus" do
        action: restart
>>>>>>> Stashed changes
    end

end

action :setup_monitoring do

end
